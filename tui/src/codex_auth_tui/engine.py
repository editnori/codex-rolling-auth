"""Pure auto-switch policy plus a short-lived, lock-scoped watch engine."""

from __future__ import annotations

import json
import math
import os
import threading
import time
from contextlib import contextmanager
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Callable, Iterator

from codex_auth_tui.backend import OperationResult, ShellBackend
from codex_auth_tui.models import AccountSnapshot, AccountsSnapshot
from codex_auth_tui.settings import AutoSettings, atomic_write_json

try:  # Linux/macOS.  Tests and the supported live watcher run on POSIX.
    import fcntl
except ImportError:  # pragma: no cover - Windows falls back to the thread guard
    fcntl = None  # type: ignore[assignment]

AUTO_STATE_VERSION = 1


@dataclass(frozen=True)
class AutoEvent:
    """One typed engine event; ``data`` is additive for UI consumers."""

    kind: str
    message: str
    ts: float
    data: dict = field(default_factory=dict)

    def human(self) -> str:
        return self.message

    def __getattr__(self, name: str):
        # Compatibility for the first TUI renderer, which read event-specific
        # attributes directly.  New consumers should use ``data``.
        data = object.__getattribute__(self, "data")
        if name in data:
            return data[name]
        raise AttributeError(name)


@dataclass(frozen=True)
class Decision:
    """The complete, serializable result of one pure policy evaluation."""

    action: str  # "switch" | "hold" | "blocked"
    reason: str
    current: str | None = None
    target: str | None = None
    current_pct: float | None = None
    target_pct: float | None = None


def _trusted_pct(account: AccountSnapshot, now: float) -> float | None:
    if not account.usage.known or account.usage.stale:
        return None
    value = account.usage.effective_binding_pct(now)
    if value is None or not math.isfinite(value):
        return None
    return max(0.0, float(value))


def rank_candidates(
    snapshot: AccountsSnapshot,
    current: str | None = None,
    now: float | None = None,
) -> tuple[AccountSnapshot, ...]:
    """Return ready candidates from most to least headroom.

    This is deliberately policy-light: threshold, hysteresis, and cooldown are
    applied by :func:`decide`.  It only enforces readiness and deterministic
    ranking.
    """

    moment = snapshot.taken_at if now is None else float(now)
    active = snapshot.active_name if current is None else current
    active_account = next(
        (account for account in snapshot.accounts if account.name == active), None
    )
    required_coverage = (
        active_account.usage.coverage if active_account is not None else frozenset()
    )
    ranked: list[tuple[float, str, AccountSnapshot]] = []
    for account in snapshot.accounts:
        if (
            account.name == active
            or account.is_active
            or not account.switchable
            or account.kind != "chatgpt"
            or not account.usage.coverage.issuperset(required_coverage)
        ):
            continue
        pct = _trusted_pct(account, moment)
        if pct is None or pct >= 100.0:
            continue
        ranked.append((pct, account.name, account))
    ranked.sort(key=lambda item: (item[0], item[1]))
    return tuple(item[2] for item in ranked)


def decide(
    snapshot: AccountsSnapshot,
    settings: AutoSettings,
    state: dict,
    now: float,
) -> Decision:
    """Choose an action without performing I/O or mutating its inputs."""

    settings = settings.validated()
    moment = float(now)
    if snapshot.active_unmanaged:
        return Decision("blocked", "unmanaged_active")
    if snapshot.active_name is None:
        return Decision("hold", "no_active_profile")

    current = next(
        (account for account in snapshot.accounts if account.name == snapshot.active_name),
        None,
    )
    if current is None:
        return Decision("blocked", "active_not_in_snapshot", snapshot.active_name)
    if current.kind != "chatgpt" or not current.switchable:
        return Decision("hold", "active_not_switchable", current.name)

    if not current.usage.known and current.usage.requires_login:
        candidates = rank_candidates(snapshot, current.name, moment)
        if not candidates:
            return Decision("blocked", "no_viable_target", current.name)
        target = candidates[0]
        return Decision(
            "switch",
            "active_login_required",
            current.name,
            target.name,
            target_pct=_trusted_pct(target, moment),
        )
    if not current.usage.known:
        return Decision("hold", "active_usage_unknown", current.name)
    if current.usage.stale:
        return Decision("hold", "active_usage_stale", current.name)
    current_pct = _trusted_pct(current, moment)
    if current_pct is None:
        reason = "active_usage_unknown"
        return Decision("hold", reason, current.name)

    hard_cap = current_pct >= 100.0
    if settings.threshold > 0.0 and current_pct < settings.threshold and not hard_cap:
        return Decision(
            "hold", "below_threshold", current.name, current_pct=current_pct
        )

    candidates = rank_candidates(snapshot, current.name, moment)
    target: AccountSnapshot | None = None
    target_pct: float | None = None
    for candidate in candidates:
        candidate_pct = _trusted_pct(candidate, moment)
        if candidate_pct is None:  # rank_candidates already excludes this
            continue
        if hard_cap:
            target, target_pct = candidate, candidate_pct
            break
        if settings.threshold == 0.0:
            # "Any better account" mode intentionally has no hysteresis floor.
            if candidate_pct < current_pct:
                target, target_pct = candidate, candidate_pct
                break
            continue
        improvement = current_pct - candidate_pct
        if (
            candidate_pct < settings.threshold
            and candidate_pct < current_pct
            and improvement >= settings.hysteresis
        ):
            target, target_pct = candidate, candidate_pct
            break

    if target is None:
        return Decision(
            "blocked",
            "no_viable_target",
            current.name,
            current_pct=current_pct,
        )

    if not hard_cap and _cooldown_active(state, settings, moment):
        return Decision(
            "hold",
            "cooldown",
            current.name,
            target.name,
            current_pct,
            target_pct,
        )

    return Decision(
        "switch",
        "hard_cap" if hard_cap else "better_candidate",
        current.name,
        target.name,
        current_pct,
        target_pct,
    )


def _cooldown_active(state: dict, settings: AutoSettings, now: float) -> bool:
    raw = state.get("last_switch_at", state.get("lastSwitchAt"))
    if isinstance(raw, bool) or not isinstance(raw, (int, float)):
        return False
    last = float(raw)
    if not math.isfinite(last):
        return False
    elapsed = now - last
    # A future timestamp is corrupt/clock-skewed state, not an indefinite ban.
    return 0.0 <= elapsed < settings.cooldown_s


class AutoSwitchEngine:
    """Refresh, snapshot, decide, and optionally switch as one locked tick."""

    def __init__(
        self,
        backend,
        settings: AutoSettings,
        on_event: Callable[[AutoEvent], None] | None = None,
        dry_run: bool = True,
        *,
        state_path: Path | None = None,
        clock: Callable[[], float] = time.time,
    ) -> None:
        self.backend = backend
        self.settings = settings.validated()
        self.on_event = on_event
        self.dry_run = dry_run
        self.clock = clock
        self.state_path = state_path or backend.paths.autoswitch_state_file
        self.lock_path = backend.paths.tmp_dir / "codex-auth-tui-auto.lock"
        self._stop = threading.Event()
        self._stopped = threading.Event()
        self._tick_guard = threading.Lock()
        self._commit_guard = threading.Lock()

    def tick(self) -> Decision:
        """Run exactly one transaction; failures become decisions/events."""

        if not self._tick_guard.acquire(blocking=False):
            decision = Decision("hold", "lock_busy")
            self._emit("lock_busy", "another auto tick is already running")
            return decision
        try:
            with _nonblocking_flock(self.lock_path) as acquired:
                if not acquired:
                    decision = Decision("hold", "lock_busy")
                    self._emit("lock_busy", "another auto watcher owns this tick")
                    return decision
                return self._tick_locked()
        except Exception as exc:
            decision = Decision("hold", "engine_error")
            self._emit("error", f"auto tick failed: {exc}", error=type(exc).__name__)
            return decision
        finally:
            self._tick_guard.release()

    def _tick_locked(self) -> Decision:
        if self._stop.is_set():
            return Decision("hold", "stopping")
        self._emit("refresh_started", "refreshing profile usage")
        if isinstance(self.backend, ShellBackend):
            refresh_result = self.backend.refresh(
                timeout_s=self.settings.refresh_timeout_s
            )
        else:
            refresh_result = self.backend.refresh()
        refresh_result = _operation_result(refresh_result)
        if not refresh_result.ok:
            self._emit(
                "refresh_failed",
                "usage refresh failed",
                returncode=refresh_result.returncode,
                output=_event_output(refresh_result.output),
            )
            return Decision("hold", "refresh_failed")
        if self._stop.is_set():
            self._emit("stopping", "live engine stopped before decision")
            return Decision("hold", "stopping")
        self._emit("refresh_finished", "usage refresh finished")

        now = self.clock()
        snapshot = self.backend.snapshot(now=now)
        if refresh_result.generation:
            snapshot, missing, active_missing = _scope_refresh_generation(
                snapshot, refresh_result.generation
            )
            if active_missing:
                self._emit(
                    "refresh_incomplete",
                    "active profile did not return current usage",
                    profiles=[snapshot.active_name],
                )
                return Decision("hold", "refresh_incomplete")
            if missing:
                self._emit(
                    "refresh_partial",
                    "some profiles did not return current usage; skipping them this tick",
                    profiles=missing,
                )
        # Manual and automatic switches share this transaction lock.  It keeps
        # the cooldown receipt ordered with the credential CAS and prevents an
        # older auto receipt from overwriting a newer manual one.
        with switch_receipt_transaction(self.state_path):
            if self._stop.is_set():
                return Decision("hold", "stopping")
            state = _read_state(self.state_path)
            decision = decide(snapshot, self.settings, state, now)
            self._emit(
                "decision",
                _decision_message(decision, self.settings),
                decision=asdict(decision),
            )
            if decision.action != "switch" or decision.target is None:
                return decision

            if self.dry_run or self._stop.is_set():
                if self._stop.is_set():
                    self._emit("stopping", "live engine stopped before switch")
                    return replace(decision, action="hold", reason="stopping")
                self._emit(
                    "switch_dry_run",
                    f"would switch {decision.current} -> {decision.target}",
                    dry_run=True,
                    current=decision.current,
                    target=decision.target,
                    reason=decision.reason,
                )
                return decision

            self._emit(
                "switch_started",
                f"switching {decision.current} -> {decision.target}",
                current=decision.current,
                target=decision.target,
            )
            # The event callback can synchronously request a stop.  Check once
            # more at the commit edge before launching the shell CAS.
            # Linearize switch commitment against stop().  Once this short
            # critical section completes, the CAS is in flight and
            # wait_stopped() remains the completion barrier.
            with self._commit_guard:
                if self._stop.is_set():
                    self._emit("stopping", "live engine stopped before switch")
                    return replace(decision, action="hold", reason="stopping")
            raw_result = self.backend.switch(
                decision.target,
                expected_current=decision.current,
                expected_generation=refresh_result.generation,
            )
            result = _operation_result(raw_result)
            if not result.ok:
                failed = replace(decision, action="blocked", reason="switch_failed")
                self._emit(
                    "switch_failed",
                    f"switch to {decision.target} failed",
                    returncode=result.returncode,
                    output=_event_output(result.output),
                    current=decision.current,
                    target=decision.target,
                )
                return failed

            switched_at = self.clock()
            try:
                record_switch_state_locked(
                    self.state_path,
                    switched_at,
                    decision.target,
                    reason=decision.reason,
                    previous=decision.current,
                )
            except OSError as exc:
                # The auth switch already succeeded.  Report the missing
                # cooldown receipt plainly, but never pretend the switch failed.
                self._emit(
                    "state_write_failed",
                    f"switched, but could not save cooldown state: {exc}",
                    target=decision.target,
                )
            self._emit(
                "switch_succeeded",
                f"switched {decision.current} -> {decision.target}",
                dry_run=False,
                current=decision.current,
                target=decision.target,
                output=_event_output(result.output),
            )
            return decision

    def run_loop(self) -> None:
        # An engine instance is single-use.  In particular, never clear a stop
        # request here: Textual may ask a just-scheduled worker to stop before
        # its thread has actually entered run_loop().
        try:
            while not self._stop.is_set():
                self.tick()
                self._stop.wait(self.settings.interval_s)
        finally:
            self._stopped.set()

    def stop(self) -> None:
        with self._commit_guard:
            self._stop.set()

    def wait_stopped(self, timeout: float | None = None) -> bool:
        deadline = None if timeout is None else time.monotonic() + timeout
        if not self._stopped.wait(timeout):
            return False
        remaining = None if deadline is None else max(0.0, deadline - time.monotonic())
        if remaining is None:
            acquired = self._tick_guard.acquire()
        else:
            acquired = self._tick_guard.acquire(timeout=remaining)
        if not acquired:
            return False
        self._tick_guard.release()
        return True

    def _emit(self, kind: str, message: str, **data: object) -> None:
        if self.on_event is None:
            return
        event = AutoEvent(kind, message, self.clock(), dict(data))
        try:
            self.on_event(event)
        except Exception:
            # A renderer being torn down must not terminate live watch mode.
            pass


def _operation_result(value: object) -> OperationResult:
    if isinstance(value, OperationResult):
        return value
    # Compatibility with simple fakes and the pre-refactor backend.
    if value is None:
        return OperationResult(False, 1, "backend returned no operation result")
    ok = bool(getattr(value, "ok", getattr(value, "switched", False)))
    return OperationResult(
        ok,
        int(getattr(value, "returncode", 0 if ok else 1)),
        str(getattr(value, "output", "")),
        getattr(value, "generation", None),
    )


def _read_state(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


@contextmanager
def _nonblocking_flock(path: Path) -> Iterator[bool]:
    if fcntl is None:  # pragma: no cover - shell runtime is POSIX/WSL only
        yield False
        return
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(path, os.O_RDWR | os.O_CREAT, 0o600)
    acquired = True
    try:
        os.fchmod(descriptor, 0o600)
        if fcntl is not None:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                acquired = False
        yield acquired
    finally:
        if acquired and fcntl is not None:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def _decision_message(decision: Decision, settings: AutoSettings) -> str:
    if decision.action == "switch":
        if decision.current_pct is not None and decision.target_pct is not None:
            return (
                f"switch {decision.current} → {decision.target}: "
                f"{decision.current_pct:g}% → {decision.target_pct:g}%"
            )
        return f"switch {decision.current} → {decision.target}"
    if decision.reason == "below_threshold":
        return (
            f"stay on {decision.current}: {decision.current_pct:g}% is below "
            f"the {settings.threshold:g}% trigger"
        )
    reasons = {
        "cooldown": "cooldown active",
        "no_viable_target": "no better ready profile",
        "active_usage_unknown": "active usage is unknown",
        "active_usage_stale": "active usage is stale",
        "active_not_switchable": "active profile is not switchable",
        "no_active_profile": "no active profile",
        "unmanaged_active": "active auth is not a saved profile",
        "refresh_incomplete": "refresh was incomplete",
        "stopping": "engine is stopping",
    }
    detail = reasons.get(decision.reason, decision.reason.replace("_", " "))
    prefix = f"stay on {decision.current}" if decision.current else "stay"
    return f"{prefix}: {detail}"


def _scope_refresh_generation(
    snapshot: AccountsSnapshot, generation: str
) -> tuple[AccountsSnapshot, list[str], bool]:
    """Exclude incomplete candidates while keeping the active CAS strict."""

    missing = [
        account.name
        for account in snapshot.accounts
        if account.kind == "chatgpt"
        and account.switchable
        and account.usage.refresh_generation != generation
    ]
    active_missing = snapshot.active_name in missing
    if active_missing or not missing:
        return snapshot, missing, active_missing
    scoped = replace(
        snapshot,
        accounts=tuple(
            account for account in snapshot.accounts if account.name not in missing
        ),
    )
    return scoped, missing, False


def _event_output(output: str, limit: int = 500) -> str:
    """Keep subprocess diagnostics bounded in long-lived UI event logs."""

    compact = " ".join(output.split())
    if len(compact) <= limit:
        return compact
    return compact[: limit - 1] + "…"


@contextmanager
def switch_receipt_transaction(path: Path) -> Iterator[None]:
    """Serialize decision/CAS/receipt work across auto and manual paths."""

    lock_path = path.with_name(f".{path.name}.lock")
    lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        os.fchmod(descriptor, 0o600)
        if fcntl is not None:
            fcntl.flock(descriptor, fcntl.LOCK_EX)
        yield
    finally:
        if fcntl is not None:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def record_switch_state_locked(
    path: Path,
    switched_at: float,
    target: str,
    *,
    reason: str,
    previous: str | None = None,
) -> bool:
    """Write one receipt while ``switch_receipt_transaction`` is held.

    A receipt with an older completion timestamp is ignored.  This is a final
    ordering guard for callers recovering from an interrupted transaction.
    """

    updated = dict(_read_state(path))
    existing = updated.get("last_switch_at", updated.get("lastSwitchAt"))
    if (
        not isinstance(existing, bool)
        and isinstance(existing, (int, float))
        and math.isfinite(float(existing))
        and float(existing) > switched_at
    ):
        return False
    updated.update(
        {
            "version": AUTO_STATE_VERSION,
            "last_switch_at": switched_at,
            "last_switch_from": previous,
            "last_switch_to": target,
            "last_switch_reason": reason,
        }
    )
    atomic_write_json(path, updated)
    return True


def record_switch_state(
    path: Path,
    switched_at: float,
    target: str,
    *,
    reason: str,
    previous: str | None = None,
) -> bool:
    with switch_receipt_transaction(path):
        return record_switch_state_locked(
            path,
            switched_at,
            target,
            reason=reason,
            previous=previous,
        )
