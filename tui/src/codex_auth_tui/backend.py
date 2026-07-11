"""Read-only snapshots plus short-lived calls into the existing shell CLI.

The shell implementation remains the only credential writer.  This module
reads profile/cache JSON for the TUI and invokes the existing shell commands
as bounded subprocesses.  It never copies or rewrites an ``auth.json`` itself.
"""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import math
import os
import signal
import shutil
import subprocess
import threading
import time
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Mapping

from codex_auth_tui.models import AccountSnapshot, AccountsSnapshot, AccountUsage
from codex_auth_tui.paths import CodexPaths, resolve_paths

REFRESH_TIMEOUT_S = 90.0
SWITCH_TIMEOUT_S = 30.0
SAVE_TIMEOUT_S = 45.0
RESET_TIMEOUT_S = 60.0
PATCH_CHECK_TIMEOUT_S = 15.0

_EMPTY_SHA256 = hashlib.sha256(b"").hexdigest()


@dataclass(frozen=True)
class OperationResult:
    """Result of one shell operation."""

    ok: bool
    returncode: int = 0
    output: str = ""
    generation: str | None = None


def _load_json_object(path: Path) -> tuple[dict | None, bool]:
    """Return one parsed object and whether the file itself existed.

    Each call performs at most one content read.  The existence bit lets a
    snapshot distinguish "no active auth" from an unrecognised/unmanaged auth.
    """

    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return None, False
    except (OSError, UnicodeDecodeError):
        return None, path.exists()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError:
        return None, True
    return (value if isinstance(value, dict) else None), True


def _credential_line(data: dict | None) -> str | None:
    if not isinstance(data, dict):
        return None
    api_key = data.get("OPENAI_API_KEY")
    if isinstance(api_key, str) and api_key:
        return f"api:{api_key}"
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    refresh = tokens.get("refresh_token")
    if isinstance(refresh, str) and refresh:
        return f"chatgpt:{refresh}"
    access = tokens.get("access_token")
    if isinstance(access, str) and access:
        return f"chatgpt-access:{access}"
    return None


def _fingerprint(data: dict | None) -> str | None:
    """Match the shell's ``jq -r ... | sha256sum`` byte-for-byte."""

    line = _credential_line(data)
    if line is None:
        return None
    return hashlib.sha256((line + "\n").encode("utf-8")).hexdigest()


def _auth_revision(data: dict | None) -> str | None:
    """Hash the complete canonical auth object for compare-and-swap checks."""

    if not isinstance(data, dict):
        return None
    canonical = json.dumps(
        data,
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )
    return hashlib.sha256((canonical + "\n").encode("utf-8")).hexdigest()


def credential_fingerprint(path: Path) -> str | None:
    """Public test/helper form of :func:`_fingerprint` for one auth file."""

    data, exists = _load_json_object(path)
    if not exists:
        return None
    line = _credential_line(data)
    if line is None:
        # This mirrors the shell helper's empty jq output, while snapshot
        # matching still refuses to treat an invalid profile as switchable.
        return _EMPTY_SHA256
    return hashlib.sha256((line + "\n").encode("utf-8")).hexdigest()


def _account_identity(data: dict | None) -> str | None:
    """Hash the stable user + account claims without exposing either value."""

    if not isinstance(data, dict):
        return None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    encoded = tokens.get("id_token") or tokens.get("access_token")
    if not isinstance(encoded, str):
        return None
    parts = encoded.split(".")
    if len(parts) < 2:
        return None
    try:
        payload = parts[1] + "=" * (-len(parts[1]) % 4)
        claims = json.loads(base64.urlsafe_b64decode(payload).decode("utf-8"))
    except (ValueError, UnicodeDecodeError, json.JSONDecodeError, binascii.Error):
        return None
    if not isinstance(claims, dict):
        return None
    auth_claims = claims.get("https://api.openai.com/auth")
    if not isinstance(auth_claims, dict):
        auth_claims = {}
    account_id = auth_claims.get("chatgpt_account_id") or tokens.get("account_id")
    user_id = (
        auth_claims.get("chatgpt_user_id")
        or auth_claims.get("user_id")
        or claims.get("sub")
    )
    if not isinstance(account_id, str) or not isinstance(user_id, str):
        return None
    account_id = "".join(account_id.split())
    user_id = "".join(user_id.split())
    if not account_id or not user_id:
        return None
    return hashlib.sha256(f"{account_id}\x1f{user_id}\n".encode()).hexdigest()


def _profile_kind(data: dict | None) -> str:
    if not isinstance(data, dict):
        return "unknown"
    api_key = data.get("OPENAI_API_KEY")
    if isinstance(api_key, str) and api_key:
        return "api_key"
    tokens = data.get("tokens")
    if isinstance(tokens, dict) and (
        (isinstance(tokens.get("refresh_token"), str) and tokens["refresh_token"])
        or (isinstance(tokens.get("access_token"), str) and tokens["access_token"])
    ):
        return "chatgpt"
    return "unknown"


def _numeric_timestamp(value: object) -> float | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        number = float(value)
    elif isinstance(value, str):
        try:
            number = float(value)
        except ValueError:
            return None
    else:
        return None
    return number if math.isfinite(number) else None


class ShellBackend:
    """Coherent snapshot reader and serialized shell-command adapter."""

    def __init__(
        self,
        paths: CodexPaths | None = None,
        cli: str | os.PathLike[str] | None = None,
        env: Mapping[str, str] | None = None,
        **legacy: object,
    ) -> None:
        # ``codex_auth_bin`` was the name used by the first TUI spike.  Keep it
        # as a harmless adapter while the public constructor stays ``cli=``.
        if cli is None and legacy.get("codex_auth_bin") is not None:
            cli = str(legacy["codex_auth_bin"])

        process_env = os.environ.copy()
        if env is not None:
            process_env.update({str(k): str(v) for k, v in env.items()})
        self.paths = paths or resolve_paths(process_env)

        # Force the child to use the exact paths this reader uses.  This keeps
        # explicit test/custom overrides intact instead of silently falling
        # back to the caller's real ~/.codex.
        process_env["CODEX_HOME"] = str(self.paths.home)
        process_env["CODEX_AUTH_PROFILES_DIR"] = str(self.paths.profiles_dir)
        process_env["CODEX_AUTH_STATE_FILE"] = str(self.paths.state_file)
        process_env["CODEX_AUTH_ACTIVE_PROFILE_FILE"] = str(
            self.paths.active_profile_file
        )
        self.env = process_env

        configured = (
            cli
            or process_env.get("CODEX_AUTH_BIN")
            or process_env.get("CODEX_AUTH_CLI")
        )
        self.cli = (
            str(configured)
            if configured
            else shutil.which("codex-auth", path=process_env.get("PATH"))
        )
        self.refresh_timeout_s = REFRESH_TIMEOUT_S
        self._subprocess_lock = threading.Lock()

    @property
    def backup_dir(self) -> Path:
        return self.paths.backup_dir

    def _run(
        self,
        args: list[str],
        *,
        timeout_s: float,
        env_overrides: Mapping[str, str] | None = None,
    ) -> OperationResult:
        if not self.cli:
            return OperationResult(False, 127, "codex-auth executable not found")
        with self._subprocess_lock:
            child_env = self.env.copy()
            if env_overrides:
                child_env.update(env_overrides)
            try:
                proc = subprocess.Popen(
                    [self.cli, *args],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    text=True,
                    env=child_env,
                    start_new_session=os.name == "posix",
                )
            except subprocess.TimeoutExpired as exc:
                # Popen itself does not wait, so this branch is defensive for
                # alternate subprocess implementations used by embedders.
                return OperationResult(False, 124, str(exc))
            except OSError as exc:
                return OperationResult(False, 127, f"could not run codex-auth: {exc}")

            try:
                stdout, stderr = proc.communicate(timeout=timeout_s)
            except subprocess.TimeoutExpired as initial_timeout:
                stdout, stderr = initial_timeout.output, initial_timeout.stderr
                _terminate_process_tree(proc)
                try:
                    stdout, stderr = proc.communicate(timeout=2.0)
                except subprocess.TimeoutExpired as terminate_timeout:
                    stdout, stderr = terminate_timeout.output, terminate_timeout.stderr
                    _kill_process_tree(proc)
                    try:
                        stdout, stderr = proc.communicate(timeout=2.0)
                    except subprocess.TimeoutExpired as kill_timeout:
                        # A daemon that escaped the process group can still
                        # retain an inherited pipe.  Never turn a bounded
                        # backend call into an unbounded UI worker.
                        stdout, stderr = kill_timeout.output, kill_timeout.stderr
                        for pipe in (proc.stdout, proc.stderr):
                            if pipe is not None:
                                try:
                                    pipe.close()
                                except OSError:
                                    pass
                label = args[0] if args else "command"
                output = _combine_output(stdout, stderr)
                return OperationResult(
                    False,
                    124,
                    _join_output(output, f"codex-auth {label} timed out"),
                )
        return OperationResult(
            proc.returncode == 0,
            proc.returncode,
            _combine_output(stdout, stderr),
        )

    # -- stable shell interface -------------------------------------------

    def refresh(
        self,
        names: list[str] | tuple[str, ...] | None = None,
        *,
        timeout_s: float | None = None,
        timeout: float | None = None,
    ) -> OperationResult:
        """Complete one shell refresh before returning.

        ``names`` is retained only for the paced dashboard adapter.  The stable
        engine API calls this with no arguments and refreshes every profile.
        """

        selected = list(names or ())
        limit = timeout_s if timeout_s is not None else timeout
        if limit is None:
            limit = self.refresh_timeout_s
        generation = uuid.uuid4().hex
        result = self._run(
            ["refresh", "--quiet", "--fast", *selected],
            timeout_s=float(limit),
            env_overrides={"CODEX_AUTH_REFRESH_GENERATION": generation},
        )
        return OperationResult(
            result.ok,
            result.returncode,
            result.output,
            generation,
        )

    def switch(
        self,
        name: str,
        *,
        expected_current: str | None = None,
        expected_generation: str | None = None,
    ) -> OperationResult:
        """Activate ``name`` with optional current and refreshed-target guards."""

        if expected_generation is not None and expected_current is None:
            return OperationResult(
                False, 64, "target generation requires an expected current profile"
            )
        if expected_current is not None:
            args = ["use-if-current", expected_current, name]
            if expected_generation is not None:
                args.append(expected_generation)
        else:
            args = ["use", name]
        return self._run(args, timeout_s=SWITCH_TIMEOUT_S)

    def save_current(self, name: str) -> OperationResult:
        """Save the live Codex auth as ``name`` through the guarded shell path."""

        return self._run(
            ["add", name, "--current"],
            # The shell mutation lock may itself wait for up to 30 seconds.
            # Leave time for validation and the atomic profile publication.
            timeout_s=SAVE_TIMEOUT_S,
        )

    def reauth(self, name: str) -> OperationResult:
        """Interactively replace one saved login without capturing its terminal.

        The Textual app suspends before calling this method, so the shell command
        must inherit the real terminal. The same backend lock used by refresh and
        switch calls keeps another shell operation from interleaving with login.
        """

        if not self.cli:
            return OperationResult(False, 127, "codex-auth executable not found")
        with self._subprocess_lock:
            try:
                completed = subprocess.run(
                    [self.cli, "reauth", name],
                    stdin=None,
                    stdout=None,
                    stderr=None,
                    env=self.env.copy(),
                    check=False,
                )
            except KeyboardInterrupt:
                return OperationResult(False, 130, "sign-in canceled")
            except OSError as exc:
                return OperationResult(False, 127, f"could not run codex-auth: {exc}")
        if completed.returncode == 0:
            return OperationResult(True)
        if completed.returncode in {130, -signal.SIGINT}:
            return OperationResult(False, 130, "sign-in canceled")
        return OperationResult(
            False,
            completed.returncode,
            f"codex-auth reauth exited with status {completed.returncode}",
        )

    def consume_reset(self, name: str) -> OperationResult:
        """Use one earned rate-limit reset for ``name`` through the shell CLI."""

        return self._run(
            ["reset", name, "--yes"],
            timeout_s=RESET_TIMEOUT_S,
        )

    def patched_ready(self) -> bool:
        """Whether the shell reports a current patched Codex binary."""

        result = self._run(
            ["patch-codex", "--print-bin", "--quiet"],
            timeout_s=PATCH_CHECK_TIMEOUT_S,
        )
        return result.ok

    # -- stable read interface --------------------------------------------

    def snapshot(self, now: float | None = None) -> AccountsSnapshot:
        """Read every source once and return one credential-safe snapshot."""

        taken_at = time.time() if now is None else float(now)
        try:
            profile_paths = sorted(
                (
                    path
                    for path in self.paths.profiles_dir.iterdir()
                    if path.suffix == ".json" and path.is_file()
                ),
                key=lambda path: path.name,
            )
        except OSError:
            profile_paths = []

        profiles: list[
            tuple[str, str, str | None, str | None, str | None]
        ] = []
        for path in profile_paths:
            data, _ = _load_json_object(path)
            kind = _profile_kind(data)
            # Invalid profiles never participate in identity matching.  Their
            # shell-compatible empty hash is not a credential identity.
            fingerprint = _fingerprint(data) if kind != "unknown" else None
            profiles.append(
                (
                    path.stem,
                    kind,
                    fingerprint,
                    _account_identity(data),
                    _auth_revision(data),
                )
            )

        active_data, active_exists = _load_json_object(self.paths.auth_file)
        active_fp = _fingerprint(active_data)
        active_identity = _account_identity(active_data)
        matched_names = {
            name
            for name, kind, fingerprint, _identity, _revision in profiles
            if kind != "unknown"
            and active_fp is not None
            and fingerprint == active_fp
        }
        if not matched_names and active_identity is not None:
            marker, _ = _load_json_object(self.paths.active_profile_file)
            marker_name = marker.get("profile") if isinstance(marker, dict) else None
            marker_identity = (
                marker.get("account_identity") if isinstance(marker, dict) else None
            )
            marker_fingerprint = (
                marker.get("profile_fingerprint") if isinstance(marker, dict) else None
            )
            marker_revision = (
                marker.get("profile_revision") if isinstance(marker, dict) else None
            )
            marker_version = marker.get("version") if isinstance(marker, dict) else None
            for name, kind, fingerprint, identity, revision in profiles:
                if (
                    marker_version == 2
                    and isinstance(marker_name, str)
                    and name == marker_name
                    and kind == "chatgpt"
                    and identity == active_identity
                    and marker_identity == active_identity
                    and fingerprint is not None
                    and marker_fingerprint == fingerprint
                    and revision is not None
                    and marker_revision == revision
                ):
                    matched_names.add(name)
                    break
        active_name = next(
            (
                name
                for name, _kind, _fingerprint, _identity, _revision in profiles
                if name in matched_names
            ),
            None,
        )

        state_data, _ = _load_json_object(self.paths.state_file)
        state_profiles = (
            state_data.get("profiles") if isinstance(state_data, dict) else None
        )
        if not isinstance(state_profiles, dict):
            state_profiles = {}

        accounts: list[AccountSnapshot] = []
        for name, kind, fingerprint, _identity, _revision in profiles:
            usage = _usage_from_state(
                state_profiles.get(name),
                fingerprint=fingerprint,
                kind=kind,
                now=taken_at,
            )
            accounts.append(
                AccountSnapshot(
                    name=name,
                    is_active=name in matched_names,
                    kind=kind,
                    # API-key profiles remain visible but are outside the
                    # quota-driven auto-switch policy by default.
                    switchable=kind == "chatgpt" and fingerprint is not None,
                    usage=usage,
                )
            )

        return AccountsSnapshot(
            active_name=active_name,
            accounts=tuple(accounts),
            taken_at=taken_at,
            fetched=frozenset(),
            active_unmanaged=active_exists and active_name is None,
        )

def _usage_from_state(
    entry: object,
    *,
    fingerprint: str | None,
    kind: str,
    now: float,
) -> AccountUsage:
    sentinel = "api key" if kind == "api_key" else None
    if kind == "unknown":
        return AccountUsage(
            sentinel="invalid profile", fingerprint_match=False
        )
    if not isinstance(entry, dict):
        return AccountUsage.from_payload(
            None,
            age_s=None,
            fetched_at=None,
            sentinel=sentinel,
            fingerprint_match=False,
        )

    fetched_at = _numeric_timestamp(entry.get("updated_at"))
    age_s = now - fetched_at if fetched_at is not None else None
    # Small clock skew is harmless. A materially future timestamp is not proof
    # that a measurement is fresh.
    if age_s is not None:
        age_s = max(0.0, age_s) if age_s >= -5.0 else None
    stored_fp = entry.get("fingerprint")
    fingerprint_match = (
        fingerprint is not None
        and isinstance(stored_fp, str)
        and stored_fp == fingerprint
    )
    payload = entry.get("payload")
    # A definitive auth error belongs to the credential that was probed. Once
    # reauth replaces that credential, retaining the old error would falsely
    # offer another sign-in against a session that has never been checked.
    if (
        not fingerprint_match
        and isinstance(payload, dict)
        and payload.get("error") is not None
    ):
        payload = None
    generation = entry.get("refresh_generation")
    return AccountUsage.from_payload(
        payload if isinstance(payload, dict) else None,
        age_s=age_s,
        fetched_at=fetched_at,
        sentinel=sentinel,
        fingerprint_match=fingerprint_match,
        refresh_generation=generation if isinstance(generation, str) else None,
    )


def _combine_output(stdout: object, stderr: object) -> str:
    def text(value: object) -> str:
        if isinstance(value, bytes):
            return value.decode("utf-8", errors="replace")
        return value if isinstance(value, str) else ""

    return _join_output(text(stdout), text(stderr))


def _join_output(first: str, second: str) -> str:
    if not first:
        return second
    if not second:
        return first
    return first + ("" if first.endswith("\n") else "\n") + second


def _terminate_process_tree(proc: subprocess.Popen[str]) -> None:
    try:
        if os.name == "posix":
            # The group can outlive its leader while retaining our pipes.
            os.killpg(proc.pid, signal.SIGTERM)
        elif proc.poll() is None:  # pragma: no cover - POSIX runtime
            proc.terminate()
    except ProcessLookupError:
        pass


def _kill_process_tree(proc: subprocess.Popen[str]) -> None:
    try:
        if os.name == "posix":
            # The group can outlive its leader while retaining our pipes.
            os.killpg(proc.pid, signal.SIGKILL)
        elif proc.poll() is None:  # pragma: no cover
            proc.kill()
    except ProcessLookupError:
        pass
