"""Display helpers for the TUI (duration/age formatting, reset countdowns)."""

from __future__ import annotations

import time

from codex_auth_tui.models import SERVE_TTL_S, AccountUsage, UsageWindow


def format_duration(seconds: float) -> str:
    """Compact duration: "45s", "12m", "2h 13m", "3d 4h"."""
    s = int(seconds)
    if s < 60:
        return f"{s}s"
    if s < 3600:
        return f"{s // 60}m"
    if s < 86400:
        h, m = divmod(s // 60, 60)
        return f"{h}h {m}m" if m else f"{h}h"
    d, h = divmod(s // 3600, 24)
    return f"{d}d {h}h" if h else f"{d}d"


def format_age(age_s: float | None) -> str | None:
    """Measurement age note ("· 2m ago"); None while comfortably fresh."""
    if age_s is None or age_s < SERVE_TTL_S:
        return None
    return f"· {format_duration(age_s)} ago"


def reset_text(window: UsageWindow, now: float) -> str | None:
    """Live countdown to a window's reset ("resets 2h 13m"), if known."""
    ts = window.reset_ts
    if ts is None:
        return None
    remaining = ts - now
    if remaining <= 0:
        return "resets now"
    return f"resets {format_duration(remaining)}"


def last_seen_note(usage: AccountUsage) -> str | None:
    """Age of the last good measurement behind a sentinel/error, if any."""
    if usage.fetched_at is None:
        return None
    return f"last seen {format_duration(usage.age_s or 0.0)} ago"


def clock_stamp(timestamp: float | None = None) -> str:
    """Local HH:MM:SS for an event timestamp (or now when omitted)."""
    return time.strftime(
        "%H:%M:%S",
        time.localtime(timestamp) if timestamp is not None else time.localtime(),
    )
