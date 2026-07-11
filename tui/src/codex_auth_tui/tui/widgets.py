"""Shared render widgets: usage bars, account cards, and the accounts panel.

Custom bar renderers (not Textual's ProgressBar) so the design can carry a
severity color ramp, an optional threshold tick (the auto-switch trigger line),
and stale-measurement dimming.
"""

from __future__ import annotations

import time
from typing import TYPE_CHECKING

from rich.text import Text
from textual.widgets import ListItem, Static

from codex_auth_tui.models import AccountSnapshot
from codex_auth_tui.tui import data
from codex_auth_tui.tui.theme import (
    ACCENT,
    FOREGROUND,
    MUTED,
    SEV_OK,
    SEV_WARN,
    TRACK,
    severity_color,
)

if TYPE_CHECKING:
    from codex_auth_tui.tui.app import CodexAuthApp

_BAR_FILLED = "━"
_BAR_HALF = "╸"
_BAR_EMPTY = "─"
_BAR_TICK = "┃"


def bar_cells(
    pct: float | None,
    width: int,
    *,
    stale: bool = False,
    threshold: float | None = None,
) -> Text:
    text = Text()
    if pct is None:
        text.append(_BAR_EMPTY * width, style=TRACK)
        return text
    frac = min(max(pct, 0.0), 100.0) / 100.0
    cells = frac * width
    full = int(cells)
    half = (cells - full) >= 0.5 and full < width
    tick_at: int | None = None
    if threshold is not None and threshold > 0:
        tick_at = min(width - 1, max(0, round(threshold / 100.0 * width)))
    color = severity_color(pct)
    fill_style = f"{color} dim" if stale else color
    for i in range(width):
        if tick_at is not None and i == tick_at:
            text.append(_BAR_TICK, style=SEV_WARN)
        elif i < full:
            text.append(_BAR_FILLED, style=fill_style)
        elif i == full and half:
            text.append(_BAR_HALF, style=fill_style)
        else:
            text.append(_BAR_EMPTY, style=TRACK)
    return text


def usage_bar(
    label: str,
    pct: float | None,
    suffix: str | None,
    width: int,
    *,
    stale: bool = False,
    threshold: float | None = None,
) -> Text:
    text = Text()
    text.append(f"{label} ", style=MUTED)
    text.append(bar_cells(pct, width, stale=stale, threshold=threshold))
    if pct is None:
        text.append("  usage unknown", style=MUTED)
    else:
        color = severity_color(pct)
        text.append(f" {pct:3.0f}%", style=f"{color} dim" if stale else color)
    if suffix:
        text.append(f"  {suffix}", style=MUTED)
    return text


def account_card_text(
    acc: AccountSnapshot,
    width: int,
    *,
    threshold: float | None = None,
    now: float | None = None,
) -> Text:
    now = now if now is not None else time.time()
    text = Text()
    text.append(f"{acc.name}", style=f"bold {FOREGROUND}")
    text.append(f"  [{acc.display_tag}]", style=MUTED)
    if acc.is_active:
        text.append("   ● active", style=f"bold {ACCENT}")
    if not acc.switchable:
        text.append("   not switchable", style=MUTED)
    reset_count = acc.usage.reset_credits_available
    if reset_count is not None:
        reset_label = "reset" if reset_count == 1 else "resets"
        reset_style = ACCENT if reset_count > 0 else MUTED
        text.append(f"   ↻ {reset_count} earned {reset_label}", style=reset_style)
    age = data.format_age(acc.usage.age_s)
    if age:
        text.append(f"   {age}", style=MUTED)
    if acc.usage.stale and acc.usage.windows:
        text.append("   stale", style=SEV_WARN)

    if acc.usage.sentinel is not None:
        text.append("\n    ")
        text.append(f"· {acc.usage.sentinel}", style=MUTED)
        return text

    if not acc.usage.windows:
        text.append("\n    ")
        text.append("usage unavailable", style=MUTED)
        if acc.usage.last_error:
            error = (
                "sign in again"
                if acc.usage.requires_login
                else acc.usage.last_error
            )
            text.append(f" · {error}", style=MUTED)
        return text

    stale = acc.usage.stale
    label_width = max(len(w.label) for w in acc.usage.windows)
    bar_width = max(12, min(30, width - 42 - label_width))
    for window in acc.usage.windows:
        suffix = data.reset_text(window, now) or ""
        text.append("\n    ")
        text.append(
            usage_bar(
                f"{window.label:<{label_width}}",
                window.pct,
                suffix or None,
                bar_width,
                stale=stale,
                threshold=threshold,
            )
        )
    return text


def mini_account_text(acc: AccountSnapshot, now: float) -> Text:
    text = Text(no_wrap=True, overflow="ellipsis")
    text.append(f"{acc.name}", style=f"bold {MUTED}")
    text.append(f"  [{acc.display_tag}]", style=MUTED)
    reset_count = acc.usage.reset_credits_available
    if reset_count is not None:
        reset_label = "reset" if reset_count == 1 else "resets"
        reset_style = ACCENT if reset_count > 0 else MUTED
        text.append(f"  ↻ {reset_count} {reset_label}", style=reset_style)
    text.append("   ")
    if acc.usage.sentinel is not None:
        text.append(acc.usage.sentinel, style=MUTED)
        return text
    if not acc.usage.windows:
        text.append("usage unknown", style=MUTED)
        return text
    stale = acc.usage.stale
    for i, window in enumerate(acc.usage.windows):
        if i:
            text.append(" · ", style=TRACK)
        color = severity_color(window.pct)
        text.append(f"{window.label} ", style=MUTED)
        text.append(f"{window.pct:.0f}%", style=f"{color} dim" if stale else color)
        if window.pct >= 100:
            reset = data.reset_text(window, now)
            if reset:
                text.append(f" ({reset})", style=MUTED)
    return text


class AccountsPanel(Static):
    """Always-visible monitor: active profile full-size, others as minis."""

    def __init__(self, *, show_minis: bool = True, id: str | None = None) -> None:
        super().__init__(id=id)
        self._show_minis = show_minis

    def on_mount(self) -> None:
        self.watch(self.app, "snapshot", lambda _snap: self.refresh(layout=True))

    def render(self) -> Text:
        app: "CodexAuthApp" = self.app  # type: ignore[assignment]
        snap = app.snapshot
        if snap is None:
            return Text("loading…", style=MUTED)
        if not snap.accounts:
            return Text(
                "No saved profiles yet.\n"
                "Press n to save the current Codex auth as a profile.",
                style=MUTED,
            )
        now = time.time()
        width = (self.size.width or 80) - 2
        blocks: list[Text] = []
        for acc in snap.accounts:
            if acc.is_active:
                blocks.append(
                    account_card_text(acc, width, threshold=app.threshold_pct, now=now)
                )
            elif self._show_minis:
                blocks.append(mini_account_text(acc, now))
        if not blocks:
            return Text("no active managed profile", style=MUTED)
        text = Text()
        previous_multiline = False
        for i, block in enumerate(blocks):
            multiline = "\n" in block.plain
            if i:
                text.append("\n\n" if (multiline or previous_multiline) else "\n")
            text.append(block)
            previous_multiline = multiline
        return text


class AccountCard(Static):
    """One account rendered full-size (used by the switch/watch list)."""

    def __init__(self, acc: AccountSnapshot, *, threshold: float | None = None) -> None:
        super().__init__()
        self._acc = acc
        self._threshold = threshold

    def set_account(self, acc: AccountSnapshot) -> None:
        self._acc = acc
        self.refresh(layout=True)

    def render(self) -> Text:
        threshold = self._threshold
        if threshold is None:
            threshold = getattr(self.app, "threshold_pct", None)
        return account_card_text(
            self._acc, self.size.width or 80, threshold=threshold
        )


class AccountItem(ListItem):
    """ListView row wrapping an :class:`AccountCard`; remembers its profile."""

    def __init__(self, acc: AccountSnapshot) -> None:
        super().__init__(AccountCard(acc))
        self.name_ = acc.name
        self.switchable = acc.switchable
        self.reset_credits_available = acc.usage.reset_credits_available

    def set_account(self, acc: AccountSnapshot) -> None:
        self.name_ = acc.name
        self.switchable = acc.switchable
        self.reset_credits_available = acc.usage.reset_credits_available
        self.query_one(AccountCard).set_account(acc)


class MenuItem(ListItem):
    def __init__(self, label: str, action_id: str, *, muted: bool = False) -> None:
        style = MUTED if muted else FOREGROUND
        super().__init__(Static(Text(label, style=style)))
        self.action_id = action_id


class RuntimeStatus(Static):
    """Makes the live-reload boundary visible without adding dashboard chrome."""

    def on_mount(self) -> None:
        self.watch(
            self.app,
            "patched_ready_state",
            lambda _ready: self.refresh(layout=True),
        )

    def render(self) -> Text:
        ready = getattr(self.app, "patched_ready_state", None)
        text = Text()
        if ready is None:
            text.append("○  patched Codex · checking", style=MUTED)
        elif ready:
            text.append("●  patched ready", style=f"bold {SEV_OK}")
            text.append(" · reloads this session", style=MUTED)
        else:
            text.append("●  patched stale", style=f"bold {SEV_WARN}")
            text.append(" · switches apply next session", style=MUTED)
        return text
