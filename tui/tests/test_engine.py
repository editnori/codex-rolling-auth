"""Pure policy and transaction tests for live watch mode."""

from __future__ import annotations

import dataclasses
import json
import os
import threading

import pytest

try:  # POSIX-only; the supported live watcher and tests run on POSIX.
    import fcntl
except ImportError:  # pragma: no cover - non-POSIX
    fcntl = None

from codex_auth_tui.backend import OperationResult
from codex_auth_tui.engine import (
    AutoSwitchEngine,
    decide,
    rank_candidates,
    record_switch_state,
)
from codex_auth_tui.models import (
    AccountSnapshot,
    AccountsSnapshot,
    AccountUsage,
    UsageWindow,
)
from codex_auth_tui.settings import AutoSettings, load_settings, save_settings

NOW = 1_000.0


def _account(
    name: str,
    pct: float | None,
    *,
    active: bool = False,
    age_s: float = 0.0,
    switchable: bool = True,
    kind: str = "chatgpt",
    reset_at: float = NOW + 3600.0,
) -> AccountSnapshot:
    if pct is None:
        usage = AccountUsage(age_s=age_s, fetched_at=NOW - age_s)
    elif kind == "api_key":
        usage = AccountUsage(sentinel="api key")
    else:
        usage = AccountUsage(
            windows=(UsageWindow("5h", pct, 300, reset_at),),
            age_s=age_s,
            fetched_at=NOW - age_s,
            fingerprint_match=True,
        )
    return AccountSnapshot(name, active, kind, switchable, usage)


def _snapshot(
    current_pct: float | None = 50.0,
    *candidates: AccountSnapshot,
    unmanaged: bool = False,
    current_kind: str = "chatgpt",
    current_switchable: bool = True,
    current_age: float = 0.0,
    current_reset: float = NOW + 3600.0,
) -> AccountsSnapshot:
    current = _account(
        "work",
        current_pct,
        active=not unmanaged,
        kind=current_kind,
        switchable=current_switchable,
        age_s=current_age,
        reset_at=current_reset,
    )
    return AccountsSnapshot(
        None if unmanaged else "work",
        (current, *candidates),
        NOW,
        active_unmanaged=unmanaged,
    )


def test_threshold_zero_uses_any_strictly_better_ready_candidate():
    snap = _snapshot(50, _account("worse", 60), _account("better", 20))

    decision = decide(snap, AutoSettings(threshold=0, hysteresis=99), {}, NOW)

    assert decision.action == "switch"
    assert decision.target == "better"
    assert decision.current_pct == 50
    assert decision.target_pct == 20


def test_threshold_zero_does_not_switch_to_equal_or_worse_account():
    snap = _snapshot(50, _account("equal", 50), _account("worse", 60))
    assert decide(snap, AutoSettings(threshold=0), {}, NOW).reason == "no_viable_target"


def test_positive_threshold_applies_threshold_and_hysteresis():
    snap = _snapshot(92, _account("marginal", 85), _account("clear", 70))
    settings = AutoSettings(threshold=90, hysteresis=10)

    decision = decide(snap, settings, {}, NOW)

    assert decision.target == "clear"
    below = _snapshot(89, _account("clear", 10))
    assert decide(below, settings, {}, NOW).reason == "below_threshold"


def test_cooldown_blocks_only_proactive_switch():
    state = {"last_switch_at": NOW - 30}
    settings = AutoSettings(threshold=0, cooldown_s=300)
    proactive = decide(_snapshot(50, _account("alt", 10)), settings, state, NOW)
    capped = decide(_snapshot(100, _account("alt", 99)), settings, state, NOW)

    assert proactive.reason == "cooldown"
    assert proactive.action == "hold"
    assert capped.action == "switch"
    assert capped.reason == "hard_cap"


def test_stale_or_unknown_active_never_drives_a_switch():
    stale = _snapshot(95, _account("alt", 10), current_age=301)
    unknown = _snapshot(None, _account("alt", 10))

    assert decide(stale, AutoSettings(), {}, NOW).reason == "active_usage_stale"
    assert decide(unknown, AutoSettings(), {}, NOW).reason == "active_usage_unknown"


def test_stale_candidate_is_never_ranked():
    snap = _snapshot(90, _account("stale", 1, age_s=301), _account("fresh", 20))
    assert [account.name for account in rank_candidates(snap, now=NOW)] == ["fresh"]


def test_candidate_missing_an_active_quota_window_is_not_ranked():
    active_usage = AccountUsage(
        windows=(
            UsageWindow("5h", 90, 300, NOW + 3600),
            UsageWindow("7d", 40, 10080, NOW + 86400),
        ),
        age_s=0,
        fetched_at=NOW,
    )
    active = AccountSnapshot("work", True, "chatgpt", True, active_usage)
    partial = _account("partial", 10)
    snap = AccountsSnapshot("work", (active, partial), NOW)

    assert rank_candidates(snap, now=NOW) == ()


def test_unmanaged_active_is_blocked_and_api_key_is_not_switchable():
    unmanaged = _snapshot(50, _account("alt", 10), unmanaged=True)
    api_active = _snapshot(
        None,
        _account("alt", 10),
        current_kind="api_key",
        current_switchable=False,
    )

    assert decide(unmanaged, AutoSettings(), {}, NOW).reason == "unmanaged_active"
    assert decide(api_active, AutoSettings(), {}, NOW).reason == "active_not_switchable"


def test_no_viable_target_is_explicitly_blocked():
    decision = decide(_snapshot(95, _account("full", 100)), AutoSettings(90), {}, NOW)
    assert decision.action == "blocked"
    assert decision.reason == "no_viable_target"


def test_elapsed_candidate_reset_requires_a_successful_refresh():
    candidate = _account("reset", 100, reset_at=NOW - 1)
    decision = decide(_snapshot(95, candidate), AutoSettings(threshold=0), {}, NOW)
    assert decision.action == "blocked"
    assert decision.reason == "no_viable_target"


def test_settings_round_trip_is_validated_and_private(codex_home):
    save_settings(
        codex_home,
        AutoSettings(
            threshold=-5,
            interval_s=0,
            cooldown_s=-1,
            hysteresis=500,
            refresh_timeout_s=0,
        ),
    )

    loaded = load_settings(codex_home)
    assert loaded == AutoSettings(
        threshold=0,
        interval_s=15,
        cooldown_s=0,
        hysteresis=100,
        refresh_timeout_s=1,
    )
    assert os.stat(codex_home.settings_file).st_mode & 0o777 == 0o600


class FakeBackend:
    def __init__(self, paths, snapshot, *, refresh_ok=True, switch_ok=True):
        self.paths = paths
        self._snapshot = snapshot
        self.refresh_ok = refresh_ok
        self.switch_ok = switch_ok
        self.calls: list[str] = []

    def refresh(self):
        self.calls.append("refresh")
        return OperationResult(self.refresh_ok, 0 if self.refresh_ok else 1, "refresh")

    def snapshot(self, now=None):
        self.calls.append("snapshot")
        return self._snapshot

    def switch(
        self, name, *, expected_current=None, expected_generation=None
    ):
        self.calls.append(
            f"switch:{name}:expected={expected_current}:generation={expected_generation}"
        )
        return OperationResult(self.switch_ok, 0 if self.switch_ok else 1, "switch")


def test_engine_is_dry_run_by_default(codex_home):
    # Safe-by-default: an engine built without opting into live mode must not
    # switch or write cooldown state.
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(backend, AutoSettings(threshold=0), clock=lambda: NOW)

    assert engine.dry_run is True
    decision = engine.tick()

    assert decision.action == "switch"
    assert "switch:alt" not in backend.calls
    assert not codex_home.autoswitch_state_file.exists()


def test_dry_run_waits_for_refresh_and_writes_no_auth_or_auto_state(codex_home):
    codex_home.auth_file.write_text("sentinel", encoding="utf-8")
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    events = []
    engine = AutoSwitchEngine(
        backend,
        AutoSettings(threshold=0),
        events.append,
        dry_run=True,
        clock=lambda: NOW,
    )

    decision = engine.tick()

    assert decision.action == "switch"
    assert backend.calls == ["refresh", "snapshot"]
    assert codex_home.auth_file.read_text(encoding="utf-8") == "sentinel"
    assert not codex_home.autoswitch_state_file.exists()
    assert [event.kind for event in events][:3] == [
        "refresh_started",
        "refresh_finished",
        "decision",
    ]
    assert events[-1].kind == "switch_dry_run"


def test_live_success_switches_then_records_cooldown_state(codex_home):
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(
        backend,
        AutoSettings(threshold=0),
        dry_run=False,
        clock=lambda: NOW,
    )

    decision = engine.tick()

    assert decision.action == "switch"
    assert backend.calls == [
        "refresh",
        "snapshot",
        "switch:alt:expected=work:generation=None",
    ]
    state = json.loads(codex_home.autoswitch_state_file.read_text(encoding="utf-8"))
    assert state["last_switch_at"] == NOW
    assert state["last_switch_to"] == "alt"


def test_failed_refresh_or_switch_does_not_write_cooldown_state(codex_home):
    snap = _snapshot(50, _account("alt", 10))
    refresh_failed = FakeBackend(codex_home, snap, refresh_ok=False)
    switch_failed = FakeBackend(codex_home, snap, switch_ok=False)

    first = AutoSwitchEngine(refresh_failed, AutoSettings(), dry_run=False).tick()
    second = AutoSwitchEngine(switch_failed, AutoSettings(), dry_run=False).tick()

    assert first.reason == "refresh_failed"
    assert refresh_failed.calls == ["refresh"]
    assert second.reason == "switch_failed"
    assert not codex_home.autoswitch_state_file.exists()


def test_stop_requested_before_loop_start_is_not_cleared(codex_home):
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(
        backend, AutoSettings(threshold=0), dry_run=False, clock=lambda: NOW
    )

    engine.stop()
    engine.run_loop()

    assert engine.wait_stopped(0)
    assert backend.calls == []


def test_stop_during_refresh_prevents_a_live_switch(codex_home):
    refresh_started = threading.Event()
    release_refresh = threading.Event()

    class BlockingBackend(FakeBackend):
        def refresh(self):
            self.calls.append("refresh")
            refresh_started.set()
            assert release_refresh.wait(2)
            return OperationResult(True)

    backend = BlockingBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(
        backend, AutoSettings(threshold=0), dry_run=False, clock=lambda: NOW
    )
    worker = threading.Thread(target=engine.run_loop)
    worker.start()
    assert refresh_started.wait(2)

    engine.stop()
    release_refresh.set()
    worker.join(2)

    assert not worker.is_alive()
    assert engine.wait_stopped(0)
    assert backend.calls == ["refresh"]
    assert not codex_home.autoswitch_state_file.exists()


def test_stop_from_switch_started_event_cancels_commit(codex_home):
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = None

    def on_event(event):
        if event.kind == "switch_started":
            engine.stop()

    engine = AutoSwitchEngine(
        backend,
        AutoSettings(threshold=0),
        on_event,
        dry_run=False,
        clock=lambda: NOW,
    )

    decision = engine.tick()

    assert decision.reason == "stopping"
    assert not any(call.startswith("switch:") for call in backend.calls)


def test_wait_stopped_includes_a_concurrent_explicit_tick(codex_home):
    refresh_started = threading.Event()
    release_refresh = threading.Event()

    class BlockingBackend(FakeBackend):
        def refresh(self):
            self.calls.append("refresh")
            refresh_started.set()
            assert release_refresh.wait(2)
            return OperationResult(True)

    backend = BlockingBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(backend, AutoSettings(), dry_run=False)
    explicit = threading.Thread(target=engine.tick)
    explicit.start()
    assert refresh_started.wait(2)
    loop = threading.Thread(target=engine.run_loop)
    loop.start()
    engine.stop()
    loop.join(2)

    assert not loop.is_alive()
    assert engine.wait_stopped(0.05) is False
    release_refresh.set()
    explicit.join(2)
    assert engine.wait_stopped(1) is True


def test_newer_switch_receipt_cannot_be_overwritten(codex_home):
    path = codex_home.autoswitch_state_file
    assert record_switch_state(
        path, 200.0, "new", reason="manual", previous="old"
    )
    assert not record_switch_state(
        path, 100.0, "stale", reason="better_candidate", previous="older"
    )

    state = json.loads(path.read_text(encoding="utf-8"))
    assert state["last_switch_at"] == 200.0
    assert state["last_switch_to"] == "new"


def test_missing_backend_result_fails_closed(codex_home):
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    backend.refresh = lambda: None

    decision = AutoSwitchEngine(backend, AutoSettings(), dry_run=False).tick()

    assert decision.reason == "refresh_failed"
    assert not any(call.startswith("switch:") for call in backend.calls)


def test_engine_requires_one_successful_refresh_generation_for_the_pool(codex_home):
    generation = "run-1"
    current = _account("work", 50, active=True)
    target = _account("alt", 10)
    current = AccountSnapshot(
        current.name,
        current.is_active,
        current.kind,
        current.switchable,
        dataclasses.replace(current.usage, refresh_generation=generation),
    )
    target = AccountSnapshot(
        target.name,
        target.is_active,
        target.kind,
        target.switchable,
        dataclasses.replace(target.usage, refresh_generation="older"),
    )
    backend = FakeBackend(codex_home, AccountsSnapshot("work", (current, target), NOW))
    backend.refresh = lambda: OperationResult(True, generation=generation)
    engine = AutoSwitchEngine(backend, AutoSettings(threshold=0), dry_run=False)

    decision = engine.tick()

    assert decision.reason == "refresh_incomplete"
    assert not any(call.startswith("switch:") for call in backend.calls)


def test_live_commit_binds_target_to_refresh_generation(codex_home):
    generation = "run-1"
    current = _account("work", 50, active=True)
    target = _account("alt", 10)
    current = dataclasses.replace(
        current,
        usage=dataclasses.replace(
            current.usage, refresh_generation=generation
        ),
    )
    target = dataclasses.replace(
        target,
        usage=dataclasses.replace(target.usage, refresh_generation=generation),
    )
    backend = FakeBackend(
        codex_home, AccountsSnapshot("work", (current, target), NOW)
    )

    def refresh():
        backend.calls.append("refresh")
        return OperationResult(True, generation=generation)

    backend.refresh = refresh
    decision = AutoSwitchEngine(
        backend, AutoSettings(threshold=0), dry_run=False, clock=lambda: NOW
    ).tick()

    assert decision.action == "switch"
    assert backend.calls[-1] == (
        "switch:alt:expected=work:generation=run-1"
    )


@pytest.mark.skipif(fcntl is None, reason="cross-process flock is POSIX-only")
def test_contended_flock_holds_the_whole_tick(codex_home):
    # A second holder of the engine's cross-process lock must make the tick a
    # benign hold: no refresh, no snapshot, no switch, no cooldown write. flock
    # is per open file description, so a separate fd on the same path contends
    # even within one process.
    backend = FakeBackend(codex_home, _snapshot(50, _account("alt", 10)))
    engine = AutoSwitchEngine(
        backend, AutoSettings(threshold=0), dry_run=False, clock=lambda: NOW
    )

    lock_path = codex_home.tmp_dir / "codex-auth-tui-auto.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    holder = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(holder, fcntl.LOCK_EX)
    try:
        decision = engine.tick()
    finally:
        fcntl.flock(holder, fcntl.LOCK_UN)
        os.close(holder)

    assert decision.action == "hold"
    assert decision.reason == "lock_busy"
    assert backend.calls == []
    assert not codex_home.autoswitch_state_file.exists()
