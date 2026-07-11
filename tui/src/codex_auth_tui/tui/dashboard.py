"""Dashboard + watch/switch screens.

The accounts panel is the monitor; arrow keys drive the *menu*, not the
accounts. Account-targeted work opens its own context:

- ``s`` / "Switch profile" → :class:`SwitchScreen` — every profile full-size,
  Enter switches, pops back.
- ``w`` / "Watch profiles" / ``codex-auth watch`` → :class:`WatchScreen` — the
  same cards read-only: a live monitor. ``s`` arms selection (a cursor appears),
  Enter switches and *stays watching*, Esc disarms. No accidental switch cursor
  while passively watching.
"""

from __future__ import annotations

from functools import partial
from typing import TYPE_CHECKING, Callable

from textual.app import ComposeResult
from textual.binding import Binding
from textual.screen import Screen
from textual.widgets import Footer, ListView, Static

from codex_auth_tui.models import AccountsSnapshot
from codex_auth_tui.tui.widgets import (
    AccountItem,
    AccountsPanel,
    MenuItem,
    RuntimeStatus,
)

if TYPE_CHECKING:
    from codex_auth_tui.tui.app import CodexAuthApp

FLASH_S = 1.5

MenuEntries = list[tuple[str, str]]


class DashboardScreen(Screen):
    BINDINGS = [
        Binding("s", "open_switch", "Switch"),
        Binding("n", "app.save_current", "Save"),
        Binding("u", "app.open_resets", "Use reset"),
        Binding("w", "app.open_watch", "Watch"),
        Binding("a", "app.open_auto", "Auto"),
        Binding("r", "app.refresh_full", "Refresh"),
        Binding("q", "app.quit", "Quit"),
        Binding("j", "cursor_down", show=False),
        Binding("k", "cursor_up", show=False),
    ]

    app: "CodexAuthApp"

    def compose(self) -> ComposeResult:
        yield AccountsPanel(id="accounts-panel")
        yield RuntimeStatus(id="runtime-status")
        yield Static("", id="menu-title")
        yield ListView(id="menu")
        yield Footer()

    async def on_mount(self) -> None:
        self.query_one("#menu-title", Static).update("codex-auth")
        menu = self.query_one("#menu", ListView)
        await menu.extend(
            MenuItem(label, action_id)
            for label, action_id in (
                ("Watch profiles", "watch"),
                ("Switch profile…", "switch"),
                ("Save current auth…", "save-current"),
                ("Use earned reset…", "reset"),
                ("Auto-switch view", "auto"),
                ("Quit", "quit"),
            )
        )
        menu.index = 0
        menu.focus()

    async def on_list_view_selected(self, event: ListView.Selected) -> None:
        item = event.item
        if isinstance(item, MenuItem):
            self._dispatch(item.action_id)

    def _dispatch(self, action_id: str) -> None:
        app = self.app
        actions: dict[str, Callable[[], None]] = {
            "watch": app.action_open_watch,
            "switch": self.action_open_switch,
            "save-current": app.action_save_current,
            "reset": app.action_open_resets,
            "auto": app.action_open_auto,
            "quit": app.exit,
        }
        actions[action_id]()

    def action_open_switch(self) -> None:
        if not isinstance(self.app.screen, SwitchScreen):
            self.app.push_screen(SwitchScreen())

    def action_cursor_down(self) -> None:
        self.query_one("#menu", ListView).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#menu", ListView).action_cursor_up()


class AccountListScreen(Screen):
    """Shared machinery: a live ListView of full account cards."""

    app: "CodexAuthApp"

    def __init__(self) -> None:
        super().__init__()
        self._names: list[str] = []
        self._stamps: dict[str, float | None] = {}

    def compose(self) -> ComposeResult:
        yield Static("", id="list-title")
        yield RuntimeStatus(id="runtime-status")
        yield ListView(id="accounts")
        yield Footer()

    def on_mount(self) -> None:
        self.watch(self.app, "snapshot", self._on_snapshot)

    async def _on_snapshot(self, snap: AccountsSnapshot | None) -> None:
        if snap is None:
            return
        listview = self.query_one("#accounts", ListView)
        names = [acc.name for acc in snap.accounts]
        if names != self._names:
            first_build = not self._names
            previous = listview.index
            await listview.clear()
            await listview.extend(AccountItem(acc) for acc in snap.accounts)
            self._names = names
            listview.index = (
                self._index_after_build(snap, first_build, previous) if names else None
            )
        else:
            for item, acc in zip(listview.query(AccountItem), snap.accounts):
                item.set_account(acc)
        self._flash_updated(snap, listview)

    def _index_after_build(self, snap, first_build, previous) -> int | None:
        if first_build:
            return self._active_index(snap)
        return min(previous or 0, len(snap.accounts) - 1)

    def _active_index(self, snap: AccountsSnapshot) -> int:
        return next(
            (i for i, acc in enumerate(snap.accounts) if acc.name == snap.active_name),
            0,
        )

    def _flash_updated(self, snap: AccountsSnapshot, listview: ListView) -> None:
        new_stamps = {acc.name: acc.usage.fetched_at for acc in snap.accounts}
        if self._stamps:
            changed = {
                name
                for name, ts in new_stamps.items()
                if ts is not None and ts != self._stamps.get(name)
            }
            for item in listview.query(AccountItem):
                if item.name_ in changed and not item.has_class("flash"):
                    item.add_class("flash")
                    self.set_timer(FLASH_S, partial(item.remove_class, "flash"))
        self._stamps = new_stamps

    def action_cursor_down(self) -> None:
        self.query_one("#accounts", ListView).action_cursor_down()

    def action_cursor_up(self) -> None:
        self.query_one("#accounts", ListView).action_cursor_up()


class SwitchScreen(AccountListScreen):
    """All profiles, full-size: arrows pick, Enter switches, pops back."""

    BINDINGS = [
        Binding("enter", "select_highlighted", "Switch", priority=True),
        Binding("escape,q,s", "back", "Back"),
        Binding("j", "cursor_down", show=False),
        Binding("k", "cursor_up", show=False),
    ]

    def on_mount(self) -> None:
        self.query_one("#list-title", Static).update("switch to which profile?")
        self.query_one("#accounts", ListView).focus()
        super().on_mount()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item = event.item
        if isinstance(item, AccountItem):
            if not item.switchable:
                self.app.notify(
                    f"{item.name_} is not switchable", severity="warning"
                )
                return
            self.app.do_switch(item.name_)
            self.app.pop_screen()

    def action_select_highlighted(self) -> None:
        listview = self.query_one("#accounts", ListView)
        if listview.display:
            listview.action_select_cursor()

    def action_back(self) -> None:
        self.app.pop_screen()


class ResetScreen(AccountListScreen):
    """Pick a ChatGPT profile, fresh-check its bank, then confirm redemption."""

    BINDINGS = [
        Binding("enter", "select_highlighted", "Check", priority=True),
        Binding("escape,q,u", "back", "Back"),
        Binding("j", "cursor_down", show=False),
        Binding("k", "cursor_up", show=False),
    ]

    def on_mount(self) -> None:
        self.query_one("#list-title", Static).update(
            "use an earned reset · select a profile to check"
        )
        self.query_one("#accounts", ListView).focus()
        super().on_mount()

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        item = event.item
        if isinstance(item, AccountItem):
            if not item.switchable:
                self.app.notify(
                    f"{item.name_} is not a ChatGPT profile",
                    severity="warning",
                )
                return
            self.app.prepare_reset(item.name_)

    def action_select_highlighted(self) -> None:
        self.query_one("#accounts", ListView).action_select_cursor()

    def action_back(self) -> None:
        self.app.pop_screen()


class WatchScreen(AccountListScreen):
    """Live monitor of every profile, hands-off by default.

    ``s`` arms selection (a cursor appears on the active profile); Enter then
    switches and stays here. Esc disarms selection first, then leaves.
    """

    _WATCH_TITLE = "watching all profiles"
    _SELECT_TITLE = "switch to which profile? · enter confirm · esc cancel"

    BINDINGS = [
        Binding("s", "toggle_select", "Switch"),
        Binding("enter", "select_highlighted", "Confirm", priority=True),
        Binding("n", "app.save_current", "Save"),
        Binding("u", "app.open_resets", "Use reset"),
        Binding("a", "app.open_auto", "Auto"),
        Binding("r", "app.refresh_full", "Refresh"),
        Binding("escape,q", "back", "Back"),
        Binding("down,j", "nav_down", show=False),
        Binding("up,k", "nav_up", show=False),
    ]

    def __init__(self) -> None:
        super().__init__()
        self._selecting = False

    def on_mount(self) -> None:
        self.query_one("#list-title", Static).update(self._WATCH_TITLE)
        super().on_mount()

    def check_action(self, action: str, parameters: tuple) -> bool | None:
        if action == "select_highlighted" and not self._selecting:
            return False  # hidden and inert until selection is armed
        return True

    def _index_after_build(self, snap, first_build, previous) -> int | None:
        if not self._selecting:
            return None  # monitor mode: no cursor at all
        return super()._index_after_build(snap, first_build, previous)

    def _set_selecting(self, on: bool) -> None:
        self._selecting = on
        listview = self.query_one("#accounts", ListView)
        title = self.query_one("#list-title", Static)
        if on:
            snap = self.app.snapshot
            if snap is not None and snap.accounts:
                listview.index = self._active_index(snap)
            listview.focus()
            title.update(self._SELECT_TITLE)
        else:
            listview.index = None
            self.set_focus(None)
            title.update(self._WATCH_TITLE)
        self.refresh_bindings()

    def action_toggle_select(self) -> None:
        self._set_selecting(not self._selecting)

    def on_list_view_selected(self, event: ListView.Selected) -> None:
        if not self._selecting:
            return
        item = event.item
        if isinstance(item, AccountItem):
            if not item.switchable:
                self.app.notify(
                    f"{item.name_} is not switchable", severity="warning"
                )
                return
            self.app.do_switch(item.name_)
            self._set_selecting(False)  # stay here, keep watching

    def action_select_highlighted(self) -> None:
        if self._selecting:
            self.query_one("#accounts", ListView).action_select_cursor()

    def action_back(self) -> None:
        if self._selecting:
            self._set_selecting(False)
        else:
            self.app.pop_screen()

    def action_nav_down(self) -> None:
        listview = self.query_one("#accounts", ListView)
        if self._selecting:
            listview.action_cursor_down()
        else:
            listview.scroll_down(animate=False)

    def action_nav_up(self) -> None:
        listview = self.query_one("#accounts", ListView)
        if self._selecting:
            listview.action_cursor_up()
        else:
            listview.scroll_up(animate=False)
