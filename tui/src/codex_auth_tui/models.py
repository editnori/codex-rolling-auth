"""Immutable snapshot models — the coherent view the TUI and engine consume.

These are read models only: the shell CLI owns every write. ``AccountUsage`` is
built from one ``auth-state.json`` profile payload (the app-server
``rateLimitsByLimitId.codex`` object, or an ``error``) plus the age of that
measurement. Freshness is explicit: ``age_s`` and ``stale`` travel with the
data so display can show a last-known value while marking it old, and the engine
can refuse to decide on it.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import datetime, timezone
import math

# Freshness thresholds, mirrored from the reference usage store.
SERVE_TTL_S = 30.0  # fresher than this → no re-fetch needed
STALE_OK_S = 300.0  # trusted for switch decisions; older → mark stale


def parse_reset_ts(resets_at: object) -> float | None:
    """Epoch seconds for a Codex ``resetsAt`` (ISO-8601 or numeric epoch)."""
    if isinstance(resets_at, bool):
        return None
    if isinstance(resets_at, (int, float)):
        value = float(resets_at)
        return value if math.isfinite(value) else None
    if not isinstance(resets_at, str) or not resets_at.strip():
        return None
    text = resets_at.strip()
    try:
        value = float(text)
        return value if math.isfinite(value) else None
    except ValueError:
        pass
    try:
        return datetime.fromisoformat(text.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


@dataclass(frozen=True)
class UsageWindow:
    """One rate-limit window ("5h"/"7d") for an account."""

    label: str
    pct: float
    window_mins: int
    resets_at: object = None

    @property
    def reset_ts(self) -> float | None:
        return parse_reset_ts(self.resets_at)


# A short window is anything under a day; longer is the weekly/secondary limit.
_SHORT_WINDOW_MAX_MINS = 1440


def _window_label(window_mins: int) -> str:
    if window_mins <= 0:
        return "-"
    if window_mins < 60:
        return f"{window_mins}m"
    if window_mins < _SHORT_WINDOW_MAX_MINS:
        return f"{window_mins // 60}h"
    return f"{window_mins // _SHORT_WINDOW_MAX_MINS}d"


def _windows_from_rate_limits(rate: dict) -> tuple[UsageWindow, ...]:
    windows: list[UsageWindow] = []
    for key in ("primary", "secondary"):
        raw = rate.get(key)
        if not isinstance(raw, dict):
            continue
        pct = raw.get("usedPercent")
        mins = raw.get("windowDurationMins")
        if not isinstance(pct, (int, float)) or not isinstance(mins, (int, float)):
            continue
        mins = int(mins)
        if mins <= 0:
            continue
        windows.append(
            UsageWindow(
                label=_window_label(mins),
                pct=float(pct),
                window_mins=mins,
                resets_at=raw.get("resetsAt"),
            )
        )
    # Short window first, weekly last (sorted by duration) — the order the CLI
    # renders and the engine reasons about.
    windows.sort(key=lambda w: w.window_mins)
    return tuple(windows)


def _reset_credit_count(payload: dict) -> int | None:
    """Return the authoritative earned-reset count when the service provides it."""

    bank = payload.get("rateLimitResetCredits")
    if not isinstance(bank, dict):
        return None
    count = bank.get("availableCount")
    if isinstance(count, bool) or not isinstance(count, (int, float)):
        return None
    if not math.isfinite(float(count)):
        return None
    return max(0, int(count))


@dataclass(frozen=True)
class AccountUsage:
    """One account's usage read model at snapshot time."""

    windows: tuple[UsageWindow, ...] = ()
    plan_type: str | None = None
    fetched_at: float | None = None
    age_s: float | None = None
    last_error: str | None = None
    # Derived overlay states that replace the bars entirely ("api key", ...).
    sentinel: str | None = None
    # Whether the credential the cache was keyed to still matches the profile.
    fingerprint_match: bool = True
    # Set only by a successful profile probe from one coordinated refresh run.
    refresh_generation: str | None = None
    # Earned server-side reset bank. None means the service omitted the field.
    reset_credits_available: int | None = None

    @classmethod
    def from_payload(
        cls,
        payload: dict | None,
        *,
        age_s: float | None,
        fetched_at: float | None,
        sentinel: str | None = None,
        fingerprint_match: bool = True,
        refresh_generation: str | None = None,
    ) -> AccountUsage:
        if sentinel is not None:
            return cls(
                sentinel=sentinel,
                age_s=age_s,
                fetched_at=fetched_at,
                fingerprint_match=fingerprint_match,
                refresh_generation=refresh_generation,
            )
        if not isinstance(payload, dict):
            return cls(
                age_s=age_s,
                fetched_at=fetched_at,
                fingerprint_match=fingerprint_match,
                refresh_generation=refresh_generation,
            )
        reset_credits_available = _reset_credit_count(payload)
        error = payload.get("error")
        if error is not None:
            return cls(
                last_error=_error_label(error),
                age_s=age_s,
                fetched_at=fetched_at,
                fingerprint_match=fingerprint_match,
                refresh_generation=refresh_generation,
                reset_credits_available=reset_credits_available,
            )
        rate = payload.get("rateLimitsByLimitId")
        if isinstance(rate, dict):
            rate = rate.get("codex")
        if not isinstance(rate, dict):
            rate = payload.get("rateLimits")
        if not isinstance(rate, dict):
            return cls(
                age_s=age_s,
                fetched_at=fetched_at,
                fingerprint_match=fingerprint_match,
                refresh_generation=refresh_generation,
                reset_credits_available=reset_credits_available,
            )
        plan = rate.get("planType")
        return cls(
            windows=_windows_from_rate_limits(rate),
            plan_type=plan if isinstance(plan, str) else None,
            age_s=age_s,
            fetched_at=fetched_at,
            fingerprint_match=fingerprint_match,
            refresh_generation=refresh_generation,
            reset_credits_available=reset_credits_available,
        )

    @property
    def stale(self) -> bool:
        """Older than the decision-trust window (or keyed to a different cred)."""
        if not self.fingerprint_match:
            return True
        if self.age_s is None or not math.isfinite(self.age_s):
            return True
        return self.age_s < -5.0 or self.age_s > STALE_OK_S

    @property
    def known(self) -> bool:
        """Whether a real utilization measurement is present."""
        return self.sentinel is None and bool(self.windows)

    @property
    def requires_login(self) -> bool:
        """Whether a completed probe says this saved session is unusable."""

        if not self.last_error:
            return False
        error = self.last_error.lower()
        return any(
            phrase in error
            for phrase in (
                "token has been invalidated",
                "token_invalidated",
                "invalidated oauth token",
                "token_revoked",
                "access token could not be refreshed because you have since "
                "logged out or signed in to another account",
                "please sign in again",
            )
        )

    def binding_pct(self) -> float | None:
        """Utilization of the worst (binding) window, or None if unknown."""
        if self.sentinel is not None or not self.windows:
            return None
        return max(w.pct for w in self.windows)

    def headroom(self) -> float | None:
        """Remaining headroom on the binding window (100 - binding pct)."""
        pct = self.binding_pct()
        return None if pct is None else 100.0 - pct

    def decision_value(self) -> float | None:
        """Binding pct the engine decides on, only while trusted; else None."""
        if self.stale:
            return None
        return self.binding_pct()

    def effective_binding_pct(self, now: float) -> float | None:
        """Binding utilization for policy decisions.

        A reset timestamp in the past makes a refresh urgent; it does not prove
        the server has reopened the window. The engine only trusts a completed
        post-reset refresh generation, so this method deliberately returns the
        measured percentage unchanged.
        """

        return self.binding_pct()

    @property
    def coverage(self) -> frozenset[str]:
        """Quota-window classes present in this measurement."""

        return frozenset(
            "short" if window.window_mins < _SHORT_WINDOW_MAX_MINS else "long"
            for window in self.windows
        )

    def limiting_reset_ts(self) -> float | None:
        """Latest reset among the >=100% windows (when the account frees up)."""
        latest: float | None = None
        for w in self.windows:
            if w.pct < 100.0:
                continue
            ts = w.reset_ts
            if ts is not None and (latest is None or ts > latest):
                latest = ts
        return latest


def _error_label(error: object) -> str:
    if isinstance(error, dict):
        for key in ("message",):
            value = error.get(key)
            if isinstance(value, str) and value:
                return value
        data = error.get("data")
        if isinstance(data, dict):
            value = data.get("message")
            if isinstance(value, str) and value:
                return value
        return "error"
    return str(error) if error else "error"


@dataclass(frozen=True)
class AccountSnapshot:
    """One managed Codex profile as the UI/engine see it."""

    name: str
    is_active: bool
    kind: str  # "chatgpt" | "api_key" | "unknown"
    switchable: bool
    usage: AccountUsage

    @property
    def display_tag(self) -> str:
        if self.kind == "api_key":
            return "api key"
        if self.kind == "unknown":
            return "invalid"
        return self.usage.plan_type or "chatgpt"


@dataclass(frozen=True)
class AccountsSnapshot:
    """Coherent one-pass view of every managed profile."""

    active_name: str | None
    accounts: tuple[AccountSnapshot, ...]
    taken_at: float
    # Names whose usage this pass came from the network (vs. served from store).
    fetched: frozenset[str] = field(default_factory=frozenset)
    # ``auth.json`` existed but no valid saved profile shared its credential.
    # This is deliberately a boolean: fingerprints never leave the backend.
    active_unmanaged: bool = False
