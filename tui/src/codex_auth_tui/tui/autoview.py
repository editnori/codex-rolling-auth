"""Live auto-switch screen: the real engine, visualized.

Runs :class:`AutoSwitchEngine` in a thread worker and renders its typed events.
Opens in **dry-run** unless the CLI passed ``--live`` — opening the view must
never start switching on its own. The in-TUI toggle (``l``) always confirms
before going live. While this screen is up the app's snapshot poller is
store-only: the engine is the sole fetcher.
"""

from __future__ import annotations

from functools import partial
from typing import TYPE_CHECKING

from rich.text import Text
from textual.app import ComposeResult
from textual.binding import Binding
from textual.containers import Horizontal, Vertical
from textual.screen import Screen
from textual.widgets import Footer, RichLog, Static

from codex_auth_tui.engine import AutoEvent, AutoSwitchEngine, rank_candidates
from codex_auth_tui.models import AccountsSnapshot
from codex_auth_tui.tui import data
from codex_auth_tui.tui.modals import ConfirmModal
from codex_auth_tui.tui.theme import (
    ACCENT,
    FOREGROUND,
    MUTED,
    SEV_WARN,
    severity_color,
)
from codex_auth_tui.tui.widgets import AccountsPanel, RuntimeStatus

if TYPE_CHECKING:
    from codex_auth_tui.tui.app import CodexAuthApp

# Engine event kinds → log style. Switches stand out; failures warn; the
# routine refresh/decision chatter stays muted.
_EVENT_STYLES = {
    "switch_succeeded": ACCENT,
    "switch_dry_run": ACCENT,
    "switch_started": ACCENT,
    "refresh_failed": SEV_WARN,
    "switch_failed": SEV_WARN,
    "state_write_failed": SEV_WARN,
    "error": SEV_WARN,
}
_QUIET_KINDS = {
    "refresh_started",
    "refresh_finished",
    "decision",
    "lock_busy",
}


def event_text(event: AutoEvent) -> Text:
    style = _EVENT_STYLES.get(event.kind)
    if style is None:
        style = MUTED if event.kind in _QUIET_KINDS else FOREGROUND
    text = Text()
    text.append(f"{data.clock_stamp(event.ts)}  ", style=MUTED)
    message = event.human() if hasattr(event, "human") else str(event)
    text.append(message, style=style)
    return text


class AutoScreen(Screen):
    BINDINGS = [
        Binding("l", "toggle_live", "Go live / dry-run"),
        Binding("r", "refresh_now", "Refresh"),
        Binding("escape,q", "back", "Back"),
    ]

    app: "CodexAuthApp"

    def __init__(self, *, start_live: bool = False) -> None:
        super().__init__()
        self._engine: AutoSwitchEngine | None = None
        self._settings = None
        self._start_live = start_live
        self._transitioning = False
        self._back_after_stop = False

    def compose(self) -> ComposeResult:
        yield AccountsPanel(show_minis=False, id="auto-active-panel")
        yield RuntimeStatus(id="runtime-status")
        with Vertical(id="auto-top"):
            with Horizontal(id="auto-title-row"):
                yield Static(" DRY-RUN ", id="mode-badge", classes="dry")
                yield Static("", id="auto-summary")
            yield Static("", id="candidates")
        yield RichLog(id="event-log", highlight=False, markup=False, wrap=True)
        yield Footer()

    # -- lifecycle ----------------------------------------------------------

    def on_mount(self) -> None:
        self.app.set_store_only(True)
        self._settings = self.app.settings
        trigger = (
            "any better"
            if self._settings.threshold == 0
            else f"at {self._settings.threshold:g}%"
        )
        self.query_one("#auto-summary", Static).update(
            f"{trigger} · {self._settings.interval_seconds:.0f}s poll · "
            f"{self._settings.cooldown_seconds:.0f}s cooldown"
        )
        self.watch(self.app, "snapshot", self._on_snapshot)
        self._start_engine(dry_run=not self._start_live)

    def on_unmount(self) -> None:
        if self._engine is not None:
            self._engine.stop()
        if not getattr(self.app, "_shutting_down", False):
            self.app.set_store_only(False)

    def action_back(self) -> None:
        if self._transitioning:
            return
        if self._engine is None or self._engine.wait_stopped(0):
            self.app.pop_screen()
            return
        self._back_after_stop = True
        self._stop_engine_then(dry_run=True)

    # -- engine -------------------------------------------------------------

    def _start_engine(self, *, dry_run: bool) -> None:
        engine = AutoSwitchEngine(
            self.app.backend,
            self._settings,
            self._emit_from_thread,
            dry_run=dry_run,
            state_path=self.app.paths.autoswitch_state_file,
        )
        self._engine = engine
        self._transitioning = False
        self.run_worker(
            engine.run_loop,
            thread=True,
            group="engine",
            exit_on_error=False,
            name=f"auto-engine-{'dry' if dry_run else 'live'}",
        )
        self._update_badge()
        mode = "DRY-RUN (watching only)" if dry_run else "LIVE (will switch profiles)"
        self.query_one("#event-log", RichLog).write(
            Text(f"engine started · {mode}", style=MUTED)
        )

    def _emit_from_thread(self, event: AutoEvent) -> None:
        try:
            self.app.call_from_thread(self._on_engine_event, event)
        except Exception:
            pass  # app/screen tearing down mid-tick

    def _on_engine_event(self, event: AutoEvent) -> None:
        if not self.is_attached:
            return
        self.query_one("#event-log", RichLog).write(event_text(event))
        if event.kind in {"refresh_finished", "switch_succeeded"}:
            self.app.request_refresh()

    def action_refresh_now(self) -> None:
        """Ask the engine for one immediate, lock-guarded policy tick."""
        if self._engine is None or self._transitioning:
            return
        self.run_worker(
            self._engine.tick,
            thread=True,
            group="engine-refresh",
            exclusive=True,
            exit_on_error=False,
            name="auto-refresh-now",
        )
        self.app.notify("Checking usage…", timeout=2)

    def action_toggle_live(self) -> None:
        if self._engine is None or self._transitioning:
            return
        if self._engine.dry_run:
            self.app.push_screen(
                ConfirmModal(
                    "Go live? codex-auth will switch your active profile "
                    "automatically when the threshold is reached.\n\n"
                    "(Same policy as running the engine with --live.)",
                    title="Go live",
                    yes_label="Go live",
                ),
                self._on_live_confirm,
            )
        else:
            self._restart_engine(dry_run=True)

    def _on_live_confirm(self, confirmed: bool | None) -> None:
        if confirmed:
            self._restart_engine(dry_run=False)

    def _restart_engine(self, *, dry_run: bool) -> None:
        self._stop_engine_then(dry_run=dry_run)

    def _stop_engine_then(self, *, dry_run: bool) -> None:
        old = self._engine
        if old is None:
            if self._back_after_stop:
                self._back_after_stop = False
                self.app.pop_screen()
            else:
                self._start_engine(dry_run=dry_run)
            return
        self._transitioning = True
        old.stop()
        badge = self.query_one("#mode-badge", Static)
        badge.update(" STOPPING ")
        badge.set_classes("dry")
        self.run_worker(
            partial(self._wait_for_engine, old, dry_run),
            thread=True,
            group="engine-transition",
            exclusive=True,
            exit_on_error=False,
            name="auto-engine-transition",
        )

    def _wait_for_engine(self, engine: AutoSwitchEngine, dry_run: bool) -> None:
        timeout = float(self._settings.refresh_timeout_s) + 5.0
        stopped = engine.wait_stopped(timeout)
        self.app.call_from_thread(self._finish_transition, dry_run, stopped)

    def _finish_transition(self, dry_run: bool, stopped: bool) -> None:
        if not self.is_attached:
            return
        if not stopped:
            self._transitioning = False
            self.app.notify(
                "Live engine is still stopping; no new mode was started",
                severity="warning",
            )
            self._update_badge()
            return
        if self._back_after_stop:
            self._back_after_stop = False
            self._transitioning = False
            self.app.pop_screen()
            return
        self._start_engine(dry_run=dry_run)

    def _update_badge(self) -> None:
        badge = self.query_one("#mode-badge", Static)
        if self._engine is not None and not self._engine.dry_run:
            badge.update(" LIVE ")
            badge.set_classes("live")
        else:
            badge.update(" DRY-RUN ")
            badge.set_classes("dry")

    # -- candidates ---------------------------------------------------------

    def _on_snapshot(self, snap: AccountsSnapshot | None) -> None:
        if snap is None:
            return
        self.query_one("#candidates", Static).update(self._candidates_text(snap))

    def _candidates_text(self, snap: AccountsSnapshot) -> Text:
        text = Text()
        text.append("Next ready", style=MUTED)
        ranked = rank_candidates(snap, now=snap.taken_at)
        if not ranked:
            text.append("\n  no ready profile with trusted usage", style=MUTED)
            return text
        for account in ranked:
            pct = account.usage.effective_binding_pct(snap.taken_at)
            text.append("\n  ")
            text.append(account.name, style=FOREGROUND)
            if pct is not None:
                text.append(f"  {pct:3.0f}% used", style=severity_color(pct))
        return text
