"""Command-line entry for the codex-auth Textual monitor.

Usually launched through the shell dispatch (``codex-auth watch``), which sets
``CODEX_AUTH_BIN`` so the backend can call back into the shell CLI. Directly:

    codex-auth-tui watch                       # passive monitor
    codex-auth-tui --auto                       # auto-switch view (dry-run)
    codex-auth-tui --live                       # implies --auto, engine live
    codex-auth-tui watch --auto --threshold 85 --interval 30

The passive monitor never switches. ``--auto`` opens the auto-switch view in
dry-run; ``--live`` is the only way the CLI starts the engine switching, and it
implies ``--auto``. The four policy knobs override the on-disk settings for this
session only — they are not written back.
"""

from __future__ import annotations

import argparse
from dataclasses import replace
import math
import sys

from codex_auth_tui.paths import resolve_paths
from codex_auth_tui.settings import load_settings


def _number(raw: str) -> float:
    try:
        value = float(raw)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise argparse.ArgumentTypeError("value must be finite")
    return value


def _threshold(raw: str) -> float:
    # Utilization trigger line; 100 would never fire, so the ceiling is 99.9.
    value = _number(raw)
    if not 0.0 <= value <= 99.9:
        raise argparse.ArgumentTypeError("threshold must be between 0 and 99.9")
    return value


def _interval(raw: str) -> float:
    # Floor of 15s keeps the network refresh off the usage endpoint's throttle.
    value = _number(raw)
    if value < 15.0:
        raise argparse.ArgumentTypeError("interval must be at least 15 seconds")
    return value


def _nonnegative(raw: str) -> float:
    value = _number(raw)
    if value < 0.0:
        raise argparse.ArgumentTypeError("value must be zero or greater")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="codex-auth-tui",
        description="Live account monitor and auto-switch console for codex-rolling-auth",
    )
    sub = parser.add_subparsers(dest="command")
    watch = sub.add_parser("watch", help="open the full-screen account monitor")
    watch.add_argument(
        "--auto",
        action="store_true",
        help="open the auto-switch view in dry-run instead of the passive monitor",
    )
    watch.add_argument(
        "--live",
        action="store_true",
        help="start the engine live (switches profiles); implies --auto",
    )
    watch.add_argument(
        "--threshold",
        type=_threshold,
        metavar="PCT",
        help="binding-window utilization trigger, 0 through 99.9",
    )
    watch.add_argument(
        "--interval",
        type=_interval,
        metavar="SECONDS",
        help="network refresh interval, at least 15",
    )
    watch.add_argument(
        "--cooldown",
        type=_nonnegative,
        metavar="SECONDS",
        help="minimum seconds between proactive switches, >= 0",
    )
    watch.add_argument(
        "--hysteresis",
        type=_nonnegative,
        metavar="PCT",
        help="headroom a candidate must beat the active profile by, >= 0",
    )
    return parser


def settings_overrides(args: argparse.Namespace) -> dict:
    """CLI knobs → AutoSettings field names (only the ones supplied)."""
    mapping = {
        "threshold": "threshold",
        "interval": "interval_s",
        "cooldown": "cooldown_s",
        "hysteresis": "hysteresis",
    }
    overrides: dict = {}
    for arg_name, field in mapping.items():
        value = getattr(args, arg_name, None)
        if value is not None:
            overrides[field] = value
    return overrides


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    # The shell dispatch (`codex-auth watch …`) may strip the leading "watch"
    # token, so treat "watch" as the default command: `codex-auth-tui --auto`,
    # `codex-auth-tui watch --auto`, and a bare `codex-auth-tui` all open the
    # monitor.
    if not argv or argv[0] != "watch":
        argv = ["watch", *argv]
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command != "watch":
        parser.print_help()
        return 2

    # --live implies --auto: passing it is an explicit request to run live.
    live = bool(getattr(args, "live", False))
    auto = bool(getattr(args, "auto", False)) or live
    overrides = settings_overrides(args)

    # Import Textual lazily so `--help` works even without the dependency.
    try:
        from codex_auth_tui.tui.app import CodexAuthApp
    except ModuleNotFoundError as exc:  # pragma: no cover - environment guard
        print(
            f"codex-auth-tui: missing dependency ({exc}). Run 'uv sync' in tui/.",
            file=sys.stderr,
        )
        return 1

    paths = resolve_paths()
    settings = replace(load_settings(paths), **overrides).validated()
    app = CodexAuthApp(
        paths=paths,
        settings=settings,
        start="auto" if auto else "watch",
        start_live=live,
    )
    app.run()
    return app.return_code or 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())
