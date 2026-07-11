#!/usr/bin/env python3
"""Generate sanitized, deterministic media from the real Textual application.

The capture never reads a Codex auth file. It runs the production Textual app
against an in-memory backend, under a temporary HOME/CODEX_HOME, and renders
Rich's exported SVG through an isolated Chromium page with network access
blocked. All visible names, usage values, reset credits, and event times are
fixed demo data.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
from contextlib import ExitStack
from dataclasses import replace
from io import BytesIO
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
import time
from typing import Callable
from unittest.mock import patch

from PIL import Image
from playwright.async_api import Route, async_playwright
from textual.widgets import Button

from codex_auth_tui.backend import OperationResult
from codex_auth_tui.engine import AutoEvent, Decision
from codex_auth_tui.models import (
    AccountSnapshot,
    AccountsSnapshot,
    AccountUsage,
    UsageWindow,
)
from codex_auth_tui.paths import CodexPaths, resolve_paths
from codex_auth_tui.settings import AutoSettings
from codex_auth_tui.tui.app import CodexAuthApp
from codex_auth_tui.tui.autoview import AutoScreen
from codex_auth_tui.tui.dashboard import ResetScreen, WatchScreen
from codex_auth_tui.tui.modals import ConfirmModal


ROOT = Path(__file__).resolve().parents[1]
ASSETS_DIR = ROOT / "assets"
GRID_SIZE = (104, 20)
DEMO_NOW = 1_893_456_000.0
FPS = 5
FRAME_MS = 1_000 // FPS
BACKGROUND = "#292929"

OUTPUT_NAMES = (
    "codex-auth-watch.png",
    "codex-auth-auto.png",
    "codex-auth-reset.png",
    "codex-auth-demo.gif",
    "codex-auth-demo.mp4",
)

TIMELINE = (
    ("watch", 1_000),
    ("reset-picker", 600),
    ("reset-confirm", 1_400),
    ("watch-return", 600),
    ("switch-armed", 600),
    ("switch-target", 800),
    ("switched", 1_000),
    ("auto", 1_600),
)

FORBIDDEN_TEXT = (
    re.compile(r"sk-[A-Za-z0-9_-]{8,}"),
    re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    re.compile(r"(?:access|refresh)[_-]?token", re.IGNORECASE),
    re.compile(r"openai[_-]?api[_-]?key", re.IGNORECASE),
    re.compile(r"authorization\s*[:=]", re.IGNORECASE),
    re.compile(r"bearer\s+[A-Za-z0-9._-]+", re.IGNORECASE),
    re.compile(r"chatgpt_(?:account|user)_id", re.IGNORECASE),
    re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.IGNORECASE),
    re.compile(r"/(?:home|Users)/[^\s<]+"),
    re.compile(r"[A-Za-z]:\\Users\\[^\s<]+", re.IGNORECASE),
    re.compile(r"\b(?:Layth|Qassem|lqassem)\b", re.IGNORECASE),
)

FONT_FACE_BLOCK = re.compile(r"\s*@font-face\s*\{.*?\}\s*", re.DOTALL)
EXTERNAL_RESOURCE = re.compile(
    r"""(?:url\(\s*["']?|(?:href|src)=["'])https?://""",
    re.IGNORECASE,
)
VIEWBOX = re.compile(
    r'viewBox="0 0 (?P<width>[0-9]+(?:\.[0-9]+)?) '
    r'(?P<height>[0-9]+(?:\.[0-9]+)?)"'
)


def _usage(
    short: float,
    weekly: float,
    *,
    short_reset: float,
    weekly_reset: float,
    reset_credits: int,
) -> AccountUsage:
    return AccountUsage(
        windows=(
            UsageWindow("5h", short, 300, DEMO_NOW + short_reset),
            UsageWindow("7d", weekly, 10_080, DEMO_NOW + weekly_reset),
        ),
        plan_type="pro",
        fetched_at=DEMO_NOW,
        age_s=0,
        reset_credits_available=reset_credits,
    )


def _account(
    name: str,
    short: float,
    weekly: float,
    *,
    active: bool = False,
    reset_credits: int = 0,
    short_reset: float = 3_600,
    weekly_reset: float = 172_800,
) -> AccountSnapshot:
    return AccountSnapshot(
        name=name,
        is_active=active,
        kind="chatgpt",
        switchable=True,
        usage=_usage(
            short,
            weekly,
            short_reset=short_reset,
            weekly_reset=weekly_reset,
            reset_credits=reset_credits,
        ),
    )


class DemoBackend:
    """Credential-free backend implementing the app's stable shell boundary."""

    def __init__(self, paths: CodexPaths) -> None:
        self.paths = paths
        self.active = "primary"
        self.accounts = [
            _account(
                "primary",
                96,
                72,
                active=True,
                reset_credits=2,
                short_reset=2_100,
                weekly_reset=187_200,
            ),
            _account(
                "backup",
                34,
                28,
                reset_credits=1,
                short_reset=5_400,
                weekly_reset=432_000,
            ),
            _account(
                "research",
                61,
                48,
                reset_credits=0,
                short_reset=3_000,
                weekly_reset=345_600,
            ),
        ]

    def snapshot(self, now: float | None = None) -> AccountsSnapshot:
        accounts = tuple(
            replace(account, is_active=account.name == self.active)
            for account in self.accounts
        )
        return AccountsSnapshot(
            active_name=self.active,
            accounts=accounts,
            taken_at=DEMO_NOW if now is None else float(now),
        )

    def refresh(self, names=None) -> OperationResult:
        return OperationResult(True)

    def switch(
        self,
        name: str,
        *,
        expected_current: str | None = None,
        expected_generation: str | None = None,
    ) -> OperationResult:
        if expected_current is not None and expected_current != self.active:
            return OperationResult(False, 75, "active profile changed")
        if not any(account.name == name for account in self.accounts):
            return OperationResult(False, 64, "unknown demo profile")
        self.active = name
        return OperationResult(True)

    def save_current(self, name: str) -> OperationResult:
        return OperationResult(False, 64, "saving is disabled in demo capture")

    def consume_reset(self, name: str) -> OperationResult:
        # The recorded flow stops at the Cancel-default confirmation. This
        # implementation is defensive in case a future capture confirms it.
        updated: list[AccountSnapshot] = []
        for account in self.accounts:
            if account.name != name:
                updated.append(account)
                continue
            count = account.usage.reset_credits_available or 0
            usage = replace(
                account.usage,
                reset_credits_available=max(0, count - 1),
                windows=tuple(
                    replace(window, pct=0.0) for window in account.usage.windows
                ),
            )
            updated.append(replace(account, usage=usage))
        self.accounts = updated
        return OperationResult(True)

    def patched_ready(self) -> bool:
        return True


class DemoEngine:
    """Deterministic in-memory engine adapter for the real Auto screen."""

    def __init__(
        self,
        backend,
        settings,
        on_event: Callable[[AutoEvent], None] | None = None,
        dry_run: bool = True,
        **_kwargs,
    ) -> None:
        self.backend = backend
        self.settings = settings
        self.on_event = on_event
        self.dry_run = dry_run
        self._stop = threading.Event()

    def run_loop(self) -> None:
        if self.on_event is not None:
            self.on_event(
                AutoEvent(
                    "decision",
                    "hold: backup has the most available capacity",
                    DEMO_NOW,
                )
            )
        self._stop.wait()

    def tick(self) -> Decision:
        return Decision("hold", "best_available", current="backup")

    def stop(self) -> None:
        self._stop.set()

    def wait_stopped(self, timeout=None) -> bool:
        return self._stop.wait(timeout)


async def _settle(app: CodexAuthApp, pilot) -> None:
    pending = [worker for worker in app.workers if worker.group != "engine"]
    if pending:
        await app.workers.wait_for_complete(pending)
    await pilot.pause()
    await pilot.pause()


def _assert_sanitized(label: str, text: str, temporary_root: Path) -> None:
    candidates = [*FORBIDDEN_TEXT, re.compile(re.escape(str(temporary_root)))]
    for pattern in candidates:
        match = pattern.search(text)
        if match is not None:
            raise RuntimeError(
                f"{label} contains forbidden capture text matching {pattern.pattern!r}"
            )


def _clean_svg(svg: str, temporary_root: Path, label: str) -> str:
    _assert_sanitized(label, svg, temporary_root)
    cleaned = FONT_FACE_BLOCK.sub("\n", svg)
    if EXTERNAL_RESOURCE.search(cleaned):
        raise RuntimeError(
            f"{label} retained an external resource after font sanitization"
        )
    return cleaned


async def _capture_states(paths: CodexPaths, temporary_root: Path) -> dict[str, str]:
    import codex_auth_tui.tui.autoview as autoview

    backend = DemoBackend(paths)
    app = CodexAuthApp(
        backend,
        settings=AutoSettings(
            threshold=90,
            interval_s=3_600,
            cooldown_s=300,
            hysteresis=10,
        ),
    )
    app.REDRAW_INTERVAL_S = 3_600
    app.PATCH_POLL_INTERVAL_S = 3_600
    app.MIN_NETWORK_INTERVAL_S = 3_600
    states: dict[str, str] = {}

    with ExitStack() as stack:
        stack.enter_context(patch.object(autoview, "AutoSwitchEngine", DemoEngine))
        stack.enter_context(patch("time.time", return_value=DEMO_NOW))
        async with app.run_test(size=GRID_SIZE) as pilot:
            await _settle(app, pilot)

            def capture(name: str) -> None:
                svg = app.export_screenshot(title="Codex Rolling Auth", simplify=True)
                states[name] = _clean_svg(svg, temporary_root, name)

            capture("watch")

            await pilot.press("u")
            await _settle(app, pilot)
            if not isinstance(app.screen, ResetScreen):
                raise RuntimeError("reset picker did not open")
            capture("reset-picker")

            await pilot.press("enter")
            await _settle(app, pilot)
            if not isinstance(app.screen, ConfirmModal):
                raise RuntimeError("reset confirmation did not open")
            if not app.screen.query_one("#no", Button).has_focus:
                raise RuntimeError("reset confirmation did not default to Cancel")
            capture("reset-confirm")

            await pilot.press("escape")
            await pilot.pause()
            await pilot.press("escape")
            await _settle(app, pilot)
            if not isinstance(app.screen, WatchScreen):
                raise RuntimeError("capture did not return to Watch")
            capture("watch-return")

            await pilot.press("s")
            await pilot.pause()
            capture("switch-armed")

            await pilot.press("down")
            await pilot.pause()
            capture("switch-target")

            await pilot.press("enter")
            await _settle(app, pilot)
            if backend.active != "backup":
                raise RuntimeError("synthetic switch did not activate backup")
            capture("switched")

            await pilot.press("a")
            await _settle(app, pilot)
            if not isinstance(app.screen, AutoScreen):
                raise RuntimeError("Auto dry-run screen did not open")
            capture("auto")

    if set(states) != {name for name, _duration in TIMELINE}:
        raise RuntimeError("capture state set does not match the media timeline")
    return states


def _find_local_font() -> tuple[Path, str]:
    configured = os.environ.get("CODEX_AUTH_CAPTURE_FONT")
    if configured:
        font_path = Path(configured).expanduser().resolve()
    else:
        fc_match = shutil.which("fc-match")
        if fc_match is None:
            raise RuntimeError(
                "fc-match is required, or set CODEX_AUTH_CAPTURE_FONT to a local mono font"
            )
        result = subprocess.run(
            [fc_match, "-f", "%{file}\n", "DejaVu Sans Mono"],
            check=True,
            capture_output=True,
            text=True,
        )
        font_path = Path(result.stdout.splitlines()[0]).resolve()
    if not font_path.is_file():
        raise RuntimeError(f"capture font does not exist: {font_path}")
    suffix = font_path.suffix.lower()
    mime = {
        ".otf": "font/otf",
        ".ttf": "font/ttf",
        ".woff": "font/woff",
        ".woff2": "font/woff2",
    }.get(suffix)
    if mime is None:
        raise RuntimeError(f"unsupported capture font type: {suffix}")
    return font_path, mime


def _viewbox_size(svg: str) -> tuple[int, int]:
    match = VIEWBOX.search(svg)
    if match is None:
        raise RuntimeError("Textual screenshot SVG has no numeric viewBox")
    width = math.ceil(float(match.group("width")))
    height = math.ceil(float(match.group("height")))
    return width, height


def _even_canvas(image: Image.Image) -> Image.Image:
    source = image.convert("RGB")
    width = source.width + source.width % 2
    height = source.height + source.height % 2
    if source.size == (width, height):
        return source
    canvas = Image.new("RGB", (width, height), BACKGROUND)
    canvas.paste(source, (0, 0))
    return canvas


async def _render_states(states: dict[str, str]) -> dict[str, Image.Image]:
    font_path, font_mime = _find_local_font()
    font_data = base64.b64encode(font_path.read_bytes()).decode("ascii")
    rendered: dict[str, Image.Image] = {}
    attempted_requests: list[str] = []

    async with async_playwright() as playwright:
        browser = await playwright.chromium.launch(
            headless=True,
            args=["--disable-lcd-text", "--font-render-hinting=none"],
        )
        try:
            for name, svg in states.items():
                width, height = _viewbox_size(svg)
                context = await browser.new_context(
                    viewport={"width": width, "height": height},
                    device_scale_factor=1,
                    color_scheme="dark",
                    locale="en-US",
                    timezone_id="UTC",
                    reduced_motion="reduce",
                )
                page = await context.new_page()

                async def block_network(route: Route) -> None:
                    attempted_requests.append(route.request.url)
                    await route.abort()

                await page.route("**/*", block_network)
                html = f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
@font-face {{
  font-family: "Codex Capture Mono";
  src: url(data:{font_mime};base64,{font_data});
  font-style: normal;
  font-weight: 100 900;
}}
html, body {{ margin: 0; width: {width}px; height: {height}px; overflow: hidden; background: {BACKGROUND}; }}
#capture {{ width: {width}px; height: {height}px; background: {BACKGROUND}; }}
#capture > svg {{ display: block; width: {width}px; height: {height}px; }}
#capture svg text, #capture svg .rich-terminal {{ font-family: "Codex Capture Mono", monospace !important; }}
</style></head><body><div id="capture">{svg}</div></body></html>"""
                await page.set_content(html, wait_until="load")
                await page.evaluate("document.fonts.ready")
                png = await page.locator("#capture").screenshot(
                    type="png",
                    animations="disabled",
                    caret="hide",
                    scale="css",
                )
                with Image.open(BytesIO(png)) as decoded:
                    rendered[name] = _even_canvas(decoded.copy())
                await context.close()
        finally:
            await browser.close()

    if attempted_requests:
        attempted = ", ".join(sorted(set(attempted_requests)))
        raise RuntimeError(f"capture attempted a blocked external request: {attempted}")
    sizes = {image.size for image in rendered.values()}
    if len(sizes) != 1:
        raise RuntimeError(f"capture frames have inconsistent sizes: {sorted(sizes)}")
    return rendered


def _save_png(image: Image.Image, target: Path) -> None:
    image.save(target, format="PNG", optimize=True, compress_level=9)


def _save_gif(images: dict[str, Image.Image], target: Path) -> None:
    ordered = [images[name] for name, _duration in TIMELINE]
    durations = [duration for _name, duration in TIMELINE]
    width, height = ordered[0].size
    atlas = Image.new("RGB", (width, height * len(ordered)), BACKGROUND)
    for index, image in enumerate(ordered):
        atlas.paste(image, (0, index * height))
    palette = atlas.quantize(
        colors=128,
        method=Image.Quantize.MEDIANCUT,
        dither=Image.Dither.NONE,
    )
    frames = [
        image.quantize(palette=palette, dither=Image.Dither.NONE) for image in ordered
    ]
    frames[0].save(
        target,
        format="GIF",
        save_all=True,
        append_images=frames[1:],
        duration=durations,
        loop=0,
        disposal=2,
        optimize=False,
    )


def _expanded_timeline(images: dict[str, Image.Image]) -> list[Image.Image]:
    frames: list[Image.Image] = []
    for name, duration in TIMELINE:
        if duration % FRAME_MS:
            raise RuntimeError(
                f"timeline duration is not aligned to {FPS} fps: {duration}"
            )
        frames.extend([images[name]] * (duration // FRAME_MS))
    return frames


def _save_mp4(images: dict[str, Image.Image], target: Path) -> None:
    ffmpeg = shutil.which("ffmpeg")
    if ffmpeg is None:
        raise RuntimeError("ffmpeg is required to generate codex-auth-demo.mp4")
    frames = _expanded_timeline(images)
    width, height = frames[0].size
    command = [
        ffmpeg,
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-f",
        "rawvideo",
        "-pix_fmt",
        "rgb24",
        "-video_size",
        f"{width}x{height}",
        "-framerate",
        str(FPS),
        "-i",
        "pipe:0",
        "-an",
        "-c:v",
        "libx264",
        "-preset",
        "medium",
        "-tune",
        "stillimage",
        "-crf",
        "18",
        "-pix_fmt",
        "yuv420p",
        "-threads",
        "1",
        "-map_metadata",
        "-1",
        "-movflags",
        "+faststart",
        "-f",
        "mp4",
        str(target),
    ]
    process = subprocess.Popen(
        command,
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )
    assert process.stdin is not None
    assert process.stderr is not None
    try:
        for frame in frames:
            process.stdin.write(frame.tobytes())
        process.stdin.close()
        error = process.stderr.read().decode("utf-8", errors="replace")
        status = process.wait()
    except BaseException:
        process.kill()
        process.wait()
        raise
    if status != 0:
        raise RuntimeError(f"ffmpeg failed with status {status}: {error.strip()}")


def _ffprobe(path: Path) -> dict:
    ffprobe = shutil.which("ffprobe")
    if ffprobe is None:
        raise RuntimeError("ffprobe is required to verify codex-auth-demo.mp4")
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "stream=codec_type,codec_name,width,height,pix_fmt,nb_frames",
            "-show_entries",
            "format=duration",
            "-of",
            "json",
            str(path),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def _verify_outputs(directory: Path, expected_size: tuple[int, int]) -> dict[str, str]:
    details: dict[str, str] = {}
    for name in ("codex-auth-watch.png", "codex-auth-auto.png", "codex-auth-reset.png"):
        path = directory / name
        with Image.open(path) as image:
            if image.format != "PNG" or image.size != expected_size:
                raise RuntimeError(
                    f"invalid PNG artifact {name}: {image.format} {image.size}"
                )
        if path.stat().st_size > 500_000:
            raise RuntimeError(f"PNG artifact is unexpectedly large: {name}")
        details[name] = f"{expected_size[0]}x{expected_size[1]}"

    gif_path = directory / "codex-auth-demo.gif"
    with Image.open(gif_path) as gif:
        frame_count = getattr(gif, "n_frames", 1)
        durations = []
        for index in range(frame_count):
            gif.seek(index)
            durations.append(int(gif.info.get("duration", 0)))
        if gif.size != expected_size or frame_count != len(TIMELINE):
            raise RuntimeError(
                f"invalid GIF artifact: size={gif.size} frames={frame_count}"
            )
        if durations != [duration for _name, duration in TIMELINE]:
            raise RuntimeError(f"GIF timing changed: {durations}")
        if gif.info.get("loop") != 0:
            raise RuntimeError("GIF is not configured to loop")
    if gif_path.stat().st_size > 5_000_000:
        raise RuntimeError("GIF artifact exceeds 5 MB")
    details[gif_path.name] = f"{frame_count} frames, {sum(durations) / 1000:.1f}s"

    mp4_path = directory / "codex-auth-demo.mp4"
    probe = _ffprobe(mp4_path)
    streams = probe.get("streams", [])
    video = [stream for stream in streams if stream.get("codec_type") == "video"]
    audio = [stream for stream in streams if stream.get("codec_type") == "audio"]
    if len(video) != 1 or audio:
        raise RuntimeError("MP4 must contain exactly one video stream and no audio")
    stream = video[0]
    expected_frames = len(
        _expanded_timeline(
            {name: Image.new("RGB", expected_size) for name, _ in TIMELINE}
        )
    )
    if (
        stream.get("codec_name") != "h264"
        or stream.get("pix_fmt") != "yuv420p"
        or (int(stream.get("width", 0)), int(stream.get("height", 0))) != expected_size
        or int(stream.get("nb_frames", 0)) != expected_frames
    ):
        raise RuntimeError(f"invalid MP4 video stream: {stream}")
    if mp4_path.stat().st_size > 10_000_000:
        raise RuntimeError("MP4 artifact exceeds 10 MB")
    duration = float(probe.get("format", {}).get("duration", 0.0))
    expected_duration = expected_frames / FPS
    if abs(duration - expected_duration) > 0.05:
        raise RuntimeError(f"MP4 duration changed: {duration}")
    details[mp4_path.name] = (
        f"{expected_frames} frames, {duration:.1f}s, H.264/yuv420p, no audio"
    )
    return details


async def _build(directory: Path) -> dict[str, str]:
    with tempfile.TemporaryDirectory(prefix="codex-auth-capture-home-") as raw_home:
        temporary_root = Path(raw_home).resolve()
        safe_home = temporary_root / "home"
        codex_home = temporary_root / "codex-home"
        safe_home.mkdir(mode=0o700)
        codex_home.mkdir(mode=0o700)

        old_home = os.environ.get("HOME")
        old_codex_home = os.environ.get("CODEX_HOME")
        old_tz = os.environ.get("TZ")
        try:
            os.environ["HOME"] = str(safe_home)
            os.environ["CODEX_HOME"] = str(codex_home)
            os.environ["TZ"] = "UTC"
            if hasattr(time, "tzset"):
                time.tzset()
            paths = resolve_paths()
            if temporary_root not in paths.home.parents:
                raise RuntimeError("capture CODEX_HOME escaped the temporary root")
            paths.tmp_dir.mkdir(parents=True, mode=0o700)
            states = await _capture_states(paths, temporary_root)
        finally:
            if old_home is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = old_home
            if old_codex_home is None:
                os.environ.pop("CODEX_HOME", None)
            else:
                os.environ["CODEX_HOME"] = old_codex_home
            if old_tz is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old_tz
            if hasattr(time, "tzset"):
                time.tzset()

    images = await _render_states(states)
    expected_size = images["watch"].size
    directory.mkdir(parents=True, exist_ok=True)
    _save_png(images["watch"], directory / "codex-auth-watch.png")
    _save_png(images["auto"], directory / "codex-auth-auto.png")
    _save_png(images["reset-confirm"], directory / "codex-auth-reset.png")
    _save_gif(images, directory / "codex-auth-demo.gif")
    _save_mp4(images, directory / "codex-auth-demo.mp4")
    return _verify_outputs(directory, expected_size)


def _publish(build_dir: Path, *, check: bool) -> None:
    mismatches = []
    for name in OUTPUT_NAMES:
        generated = build_dir / name
        published = ASSETS_DIR / name
        if check:
            if (
                not published.is_file()
                or generated.read_bytes() != published.read_bytes()
            ):
                mismatches.append(name)
            continue
        temporary = ASSETS_DIR / f".{name}.tmp"
        shutil.copyfile(generated, temporary)
        os.replace(temporary, published)
    if mismatches:
        raise RuntimeError("generated media differs: " + ", ".join(mismatches))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="regenerate in a temporary directory and compare with assets/",
    )
    args = parser.parse_args()

    with tempfile.TemporaryDirectory(prefix="codex-auth-media-build-") as raw_build:
        build_dir = Path(raw_build)
        details = asyncio.run(_build(build_dir))
        _publish(build_dir, check=args.check)

    action = "verified" if args.check else "generated"
    for name in OUTPUT_NAMES:
        print(f"{action} {name}: {details[name]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
