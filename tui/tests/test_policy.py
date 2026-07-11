"""Policy tests for the pure ``decide`` function.

``decide`` is I/O-free: it takes a snapshot, settings, cooldown state and a
clock, and returns a :class:`Decision`. That makes the whole policy surface —
threshold 0, threshold+hysteresis, cooldown, stale data, invalid/capped active,
and no-viable-target — directly assertable without any subprocess.
"""

from __future__ import annotations

from codex_auth_tui.engine import decide
from codex_auth_tui.models import (
    AccountSnapshot,
    AccountsSnapshot,
    AccountUsage,
    UsageWindow,
)
from codex_auth_tui.settings import AutoSettings

NOW = 1000.0


def usage(pct: float | None, *, stale: bool = False, reset_in: float = 3600.0) -> AccountUsage:
    if pct is None:
        return AccountUsage()  # unknown: no windows
    age = 400.0 if stale else 0.0  # 400s > STALE_OK_S (300s)
    return AccountUsage(
        windows=(UsageWindow("5h", pct, 300, NOW + reset_in),),
        age_s=age,
        fetched_at=NOW - age,
        fingerprint_match=True,
    )


def account(name, pct=None, *, active=False, kind="chatgpt", stale=False, usage_obj=None):
    return AccountSnapshot(
        name=name,
        is_active=active,
        kind=kind,
        switchable=(kind == "chatgpt"),
        usage=usage_obj if usage_obj is not None else usage(pct, stale=stale),
    )


def snap(accounts, *, active, unmanaged=False):
    return AccountsSnapshot(
        active_name=active,
        accounts=tuple(accounts),
        taken_at=NOW,
        active_unmanaged=unmanaged,
    )


# -- threshold 0 ("always prefer any genuinely better ready account") -------

def test_threshold_zero_switches_to_any_better_ready_account():
    s = snap(
        [account("work", 50, active=True), account("alt", 20)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=0), {}, NOW)
    assert d.action == "switch"
    assert d.target == "alt"
    assert d.reason == "better_candidate"


def test_threshold_zero_does_not_switch_to_a_worse_account():
    s = snap(
        [account("work", 50, active=True), account("alt", 60)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=0), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "no_viable_target"


def test_threshold_zero_ignores_equal_utilization():
    s = snap(
        [account("work", 50, active=True), account("alt", 50)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=0), {}, NOW)
    assert d.action == "blocked"


# -- threshold + hysteresis -------------------------------------------------

def test_threshold_hysteresis_picks_best_qualifying_candidate():
    s = snap(
        [
            account("work", 92, active=True),
            account("a", 85),  # improvement 7 < hysteresis 10
            account("b", 70),  # improvement 22, below threshold
        ],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "switch"
    assert d.target == "b"


def test_hysteresis_blocks_marginal_candidate():
    s = snap(
        [account("work", 92, active=True), account("a", 85)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "no_viable_target"


def test_below_threshold_holds():
    s = snap(
        [account("work", 50, active=True), account("alt", 20)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "hold"
    assert d.reason == "below_threshold"


# -- cooldown ---------------------------------------------------------------

def test_cooldown_holds_a_proactive_switch():
    s = snap(
        [account("work", 50, active=True), account("alt", 20)],
        active="work",
    )
    state = {"last_switch_at": NOW - 10}  # 10s ago, cooldown 300s
    d = decide(s, AutoSettings(threshold=0, cooldown_s=300), state, NOW)
    assert d.action == "hold"
    assert d.reason == "cooldown"


def test_cooldown_does_not_block_hard_cap():
    s = snap(
        [account("work", 100, active=True), account("alt", 20)],
        active="work",
    )
    state = {"last_switch_at": NOW - 10}
    d = decide(s, AutoSettings(threshold=90, cooldown_s=300), state, NOW)
    assert d.action == "switch"
    assert d.reason == "hard_cap"


# -- stale data -------------------------------------------------------------

def test_stale_active_usage_holds_rather_than_deciding():
    s = snap(
        [account("work", 95, active=True, stale=True), account("alt", 20)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90), {}, NOW)
    assert d.action == "hold"
    assert d.reason == "active_usage_stale"


def test_stale_candidate_is_not_a_target():
    s = snap(
        [account("work", 95, active=True), account("alt", 20, stale=True)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "no_viable_target"


def test_unknown_active_usage_holds():
    s = snap(
        [account("work", None, active=True), account("alt", 20)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90), {}, NOW)
    assert d.action == "hold"
    assert d.reason == "active_usage_unknown"


# -- invalid / capped active ------------------------------------------------

def test_no_active_profile_holds():
    s = snap([account("work", 20)], active=None)
    d = decide(s, AutoSettings(), {}, NOW)
    assert d.action == "hold"
    assert d.reason == "no_active_profile"


def test_unmanaged_active_is_blocked():
    s = snap([account("work", 20)], active=None, unmanaged=True)
    d = decide(s, AutoSettings(), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "unmanaged_active"


def test_active_not_in_snapshot_is_blocked():
    s = snap([account("work", 20)], active="ghost")
    d = decide(s, AutoSettings(), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "active_not_in_snapshot"


def test_capped_active_switches_ignoring_hysteresis():
    s = snap(
        [account("work", 100, active=True), account("alt", 95)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "switch"
    assert d.reason == "hard_cap"
    assert d.target == "alt"


def test_active_api_key_is_not_switchable():
    s = snap(
        [
            account("key", active=True, kind="api_key", usage_obj=AccountUsage(sentinel="api key")),
            account("alt", 20),
        ],
        active="key",
    )
    d = decide(s, AutoSettings(threshold=90), {}, NOW)
    assert d.action == "hold"
    assert d.reason == "active_not_switchable"


# -- no viable target -------------------------------------------------------

def test_all_candidates_exhausted_blocks():
    s = snap(
        [account("work", 95, active=True), account("alt", 100)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "no_viable_target"


def test_candidate_past_reset_stays_blocked_until_refresh_confirms_it():
    reset_passed = AccountUsage(
        windows=(UsageWindow("5h", 100.0, 300, NOW - 10),),
        age_s=0.0,
        fetched_at=NOW,
        fingerprint_match=True,
    )
    s = snap(
        [account("work", 95, active=True), account("alt", None, usage_obj=reset_passed)],
        active="work",
    )
    d = decide(s, AutoSettings(threshold=90, hysteresis=10), {}, NOW)
    assert d.action == "blocked"
    assert d.reason == "no_viable_target"
