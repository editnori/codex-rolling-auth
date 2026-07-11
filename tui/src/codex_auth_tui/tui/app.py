"""The codex-auth Textual application.

The screen redraws from the local state store every three seconds. Network
refreshes are a separate cadence, controlled by :class:`AutoSettings`, so an
open monitor never turns into a three-second app-server loop. All backend
calls run in thread workers and manual switches never overlap refreshes.
"""

from __future__ import annotations

from functools import partial
import time
from typing import Any

from textual.app import App, SuspendNotSupported
from textual.reactive import reactive
from textual.worker import WorkerCancelled, WorkerFailed, WorkerState

from codex_auth_tui.backend import OperationResult, ShellBackend
from codex_auth_tui.engine import (
    record_switch_state_locked,
    switch_receipt_transaction,
)
from codex_auth_tui.models import AccountsSnapshot
from codex_auth_tui.paths import CodexPaths, resolve_paths
from codex_auth_tui.settings import AutoSettings, load_settings
from codex_auth_tui.tui.autoview import AutoScreen
from codex_auth_tui.tui.dashboard import (
    DashboardScreen,
    ReauthScreen,
    ResetScreen,
    WatchScreen,
)
from codex_auth_tui.tui.modals import ConfirmModal, OutputModal, ProfileNameModal
from codex_auth_tui.tui.theme import CODEX_AUTH_DARK


class CodexAuthApp(App):
    """Full-screen profile monitor and auto-switch console."""

    TITLE = "codex-auth"
    CSS_PATH = "codex_auth_tui.tcss"
    ENABLE_COMMAND_PALETTE = False

    REDRAW_INTERVAL_S = 3.0
    PATCH_POLL_INTERVAL_S = 15.0
    MIN_NETWORK_INTERVAL_S = 15.0

    snapshot: reactive[AccountsSnapshot | None] = reactive(None)
    busy: reactive[bool] = reactive(False)
    patched_ready_state: reactive[bool | None] = reactive(None)

    def __init__(
        self,
        backend: ShellBackend | None = None,
        *,
        paths: CodexPaths | None = None,
        settings: AutoSettings | None = None,
        start: str = "watch",
        start_live: bool = False,
    ) -> None:
        super().__init__()
        self.paths = paths or getattr(backend, "paths", None) or resolve_paths()
        self.backend = backend or ShellBackend(self.paths)
        self.settings = (settings or load_settings(self.paths)).validated()
        self.threshold_pct: float | None = self.settings.threshold
        self._start = start
        self._start_live = start_live
        self._store_only = False
        self._refreshing = False
        self._last_refresh_error = ""
        self._pending_network = False
        self._pending_patch_check = False
        self._shutting_down = False

    def on_mount(self) -> None:
        self.register_theme(CODEX_AUTH_DARK)
        self.theme = "codex-auth-dark"
        self.push_screen(DashboardScreen())
        self.push_screen(WatchScreen())
        if self._start == "auto":
            self.push_screen(AutoScreen(start_live=self._start_live))

        self.set_interval(self.REDRAW_INTERVAL_S, self._tick)
        self.set_interval(self.PATCH_POLL_INTERVAL_S, self._patch_tick)
        network_interval = max(
            self.MIN_NETWORK_INTERVAL_S, float(self.settings.interval_s)
        )
        self.set_interval(network_interval, self._network_tick)

        # Publish the local cache first so cold/offline startup never sits on a
        # blank "loading" screen behind network and patch-check timeouts.  The
        # second request is queued behind that fast snapshot read.
        self._start_refresh(network=False)
        self._start_refresh(
            network=self._start != "auto",
            check_patch=True,
        )

    # -- snapshots and refresh cadence -------------------------------------

    def _tick(self) -> None:
        """Redraw from disk. This path never calls the network."""
        self._start_refresh(network=False)

    def _network_tick(self) -> None:
        """Refresh usage at the configured cadence while passively watching."""
        if not self._store_only:
            self._start_refresh(network=True)

    def _patch_tick(self) -> None:
        """Follow detached patch completion using the cheap local marker check."""
        self._start_refresh(network=False, check_patch=True)

    def request_refresh(
        self, *, full: bool = False, check_patch: bool = False
    ) -> None:
        """Request a store redraw or an explicit network refresh.

        ``full`` retains the first TUI pass's public spelling. In Auto view the
        engine owns network I/O, so even a full app refresh remains store-only.
        """
        self._start_refresh(
            network=bool(full and not self._store_only),
            check_patch=check_patch,
        )

    def _start_refresh(self, *, network: bool, check_patch: bool = False) -> None:
        if self._refreshing or self.busy:
            self._pending_network = self._pending_network or network
            self._pending_patch_check = self._pending_patch_check or check_patch
            return
        self._refreshing = True
        self.run_worker(
            partial(self._refresh_blocking, network, check_patch),
            thread=True,
            group="refresh",
            exit_on_error=False,
            name="network-refresh" if network else "snapshot-read",
        )

    def _refresh_blocking(self, network: bool, check_patch: bool) -> None:
        result = OperationResult(True)
        if network:
            raw = self.backend.refresh()
            result = _operation_result(raw)
        snap = self.backend.snapshot()
        patched: bool | None = None
        if check_patch:
            patched = _patched_ready(self.backend)
        self.call_from_thread(self._apply_refresh, snap, result, patched)

    def _apply_refresh(
        self,
        snap: AccountsSnapshot,
        result: OperationResult,
        patched: bool | None,
    ) -> None:
        self._refreshing = False
        self.snapshot = snap
        if patched is not None:
            self.patched_ready_state = patched
        if result.ok:
            self._last_refresh_error = ""
        else:
            message = _first_line(result.output) or "usage refresh failed"
            if message != self._last_refresh_error:
                self._last_refresh_error = message
                self.notify(message, severity="warning", timeout=6)
        self._drain_pending()

    def _drain_pending(self) -> None:
        if self._refreshing or self.busy:
            return
        network = self._pending_network and not self._store_only
        check_patch = self._pending_patch_check
        self._pending_network = False
        self._pending_patch_check = False
        if network or check_patch:
            self._start_refresh(network=network, check_patch=check_patch)

    def set_store_only(self, value: bool) -> None:
        self._store_only = value
        if value:
            self._pending_network = False
            self.request_refresh()
        else:
            # Leaving Auto view returns ownership of usage fetching to watch.
            self.request_refresh(full=True)

    def exit(self, *args, **kwargs) -> None:
        self._shutting_down = True
        super().exit(*args, **kwargs)

    # -- worker failures ----------------------------------------------------

    def on_worker_state_changed(self, event) -> None:
        if event.state is not WorkerState.ERROR:
            return
        if event.worker.group == "refresh":
            self._refreshing = False
            message = str(event.worker.error)
            if message != self._last_refresh_error:
                self._last_refresh_error = message
                self.notify(f"Refresh failed: {message}", severity="warning", timeout=6)
            self._drain_pending()
        elif event.worker.group == "action":
            self.busy = False
            self.notify(f"Switch failed: {event.worker.error}", severity="error")
            self._drain_pending()
        elif event.worker.group == "save":
            self.busy = False
            self.notify(f"Save failed: {event.worker.error}", severity="error")
            self._drain_pending()
        elif event.worker.group in {"reset-check", "reset"}:
            self.busy = False
            self.notify(f"Reset failed: {event.worker.error}", severity="error")
            self._drain_pending()
        elif event.worker.group in {"engine", "engine-refresh"}:
            self.notify(
                f"Auto-switch engine stopped: {event.worker.error}",
                severity="error",
            )

    # -- manual switching --------------------------------------------------

    def do_switch(self, name: str) -> None:
        account = next(
            (
                item
                for item in (self.snapshot.accounts if self.snapshot else ())
                if item.name == name
            ),
            None,
        )
        if account is not None and not account.switchable:
            self.notify(f"{name} is not switchable", severity="warning")
            return
        if self.busy or self._refreshing:
            self.notify("Usage refresh is still running", severity="warning")
            return
        self.busy = True
        before = self.snapshot.active_name if self.snapshot else None
        self.run_worker(
            partial(self._switch_blocking, name, before),
            thread=True,
            group="action",
            exit_on_error=False,
            name=f"switch-{name}",
        )

    def _switch_blocking(self, name: str, before: str | None) -> None:
        with switch_receipt_transaction(self.paths.autoswitch_state_file):
            raw_result = self.backend.switch(name, expected_current=before)
            result = _operation_result(raw_result)
            snap = self.backend.snapshot()
            if result.ok and snap.active_name == name and before != name:
                try:
                    record_switch_state_locked(
                        self.paths.autoswitch_state_file,
                        time.time(),
                        name,
                        reason="manual",
                        previous=before,
                    )
                except OSError:
                    # The credential transaction succeeded. A missing cooldown
                    # receipt is non-fatal and the next live tick remains safe.
                    pass
        self.call_from_thread(self._switch_done, name, before, result, snap)

    def _switch_done(
        self,
        name: str,
        before: str | None,
        result: OperationResult,
        snap: AccountsSnapshot,
    ) -> None:
        self.busy = False
        self.snapshot = snap
        if result.ok and snap.active_name == name:
            if before == name:
                self.notify(f"{name} already active", title="No switch")
            else:
                self.notify(f"Switched to {name}", title="Switch")
        else:
            message = _first_line(result.output) or "switch did not take effect"
            self.notify(message, severity="warning")
            if result.output.strip():
                self.push_screen(OutputModal("Switch: details", result.output))
        self._drain_pending()

    # -- saving the current auth ------------------------------------------

    def action_save_current(self) -> None:
        if self.busy:
            self.notify("Another auth change is still running", severity="warning")
            return
        if self.snapshot is None:
            self.notify("Current auth is still loading", severity="warning")
            return
        if self.snapshot.active_name is None and not self.snapshot.active_unmanaged:
            self.notify(
                "No current Codex auth found. Sign in first with codex login.",
                severity="warning",
            )
            return
        self.push_screen(ProfileNameModal(), self._save_current_named)

    def _save_current_named(self, name: str | None) -> None:
        if name is None:
            return
        existing = any(
            account.name == name
            for account in (self.snapshot.accounts if self.snapshot else ())
        )
        if existing:
            self.push_screen(
                ConfirmModal(
                    f"{name} already exists. Replace it with the current Codex auth?",
                    title="Replace saved profile?",
                    yes_label="Replace",
                ),
                partial(self._save_current_confirmed, name),
            )
            return
        self._start_save_current(name)

    def _save_current_confirmed(self, name: str, confirmed: bool) -> None:
        if confirmed:
            self._start_save_current(name)

    def _start_save_current(self, name: str) -> None:
        if self.busy:
            self.notify("Another auth change is still running", severity="warning")
            return
        self.busy = True
        self.notify(f"Saving current auth as {name}…", timeout=3)
        self.run_worker(
            partial(self._save_current_blocking, name),
            thread=True,
            group="save",
            exit_on_error=False,
            name=f"save-{name}",
        )

    def _save_current_blocking(self, name: str) -> None:
        result = _operation_result(self.backend.save_current(name))
        snap = self.backend.snapshot()
        self.call_from_thread(self._save_current_done, name, result, snap)

    def _save_current_done(
        self,
        name: str,
        result: OperationResult,
        snap: AccountsSnapshot,
    ) -> None:
        self.busy = False
        self.snapshot = snap
        saved = any(account.name == name for account in snap.accounts)
        if result.ok and saved:
            self.notify(f"Saved current auth as {name}", title="Profile saved")
        else:
            message = _first_line(result.output) or "profile was not saved"
            self.notify(message, severity="warning")
            if result.output.strip():
                self.push_screen(OutputModal("Save profile: details", result.output))
        self._drain_pending()

    # -- isolated browser sign-in -----------------------------------------

    def action_reauth(self, name: str) -> None:
        """Rich ``@click`` target for an account's "sign in again" link."""

        self.prepare_reauth(name)

    def prepare_reauth(self, name: str) -> None:
        if isinstance(self.screen, AutoScreen):
            self.notify(
                "Leave Auto view before signing in again",
                severity="warning",
            )
            return
        if self.busy or self._refreshing:
            self.notify("Another auth operation is still running", severity="warning")
            return
        snap = self.snapshot
        if snap is None:
            self.notify("Saved profiles are still loading", severity="warning")
            return
        account = next((item for item in snap.accounts if item.name == name), None)
        if account is None:
            self.notify(f"Saved profile {name} was not found", severity="warning")
            return
        if not account.switchable:
            self.notify(
                f"{name} is not a saved ChatGPT profile",
                severity="warning",
            )
            return

        active_before = snap.active_name
        if active_before is None:
            active_copy = (
                "No profile will be activated, and the live Codex auth stays as it is."
            )
        else:
            active_copy = (
                f"The current active profile ({active_before}) stays active. "
                "No profile switch is performed."
            )
            if name == active_before:
                active_copy += " Its live credential is refreshed in place."
        self.push_screen(
            ConfirmModal(
                f"Open browser sign-in for {name}?\n\n"
                f"Only the selected saved profile ({name}) is reauthenticated. "
                f"{active_copy}",
                title="Sign in again?",
                yes_label="Sign in",
                default_cancel=True,
            ),
            partial(self._reauth_confirmed, name, active_before),
        )

    async def _reauth_confirmed(
        self,
        name: str,
        active_before: str | None,
        confirmed: bool | None,
    ) -> None:
        if not confirmed:
            return
        if self.busy or self._refreshing:
            self.notify("Another auth operation is still running", severity="warning")
            return

        self.busy = True
        self.notify(f"Opening browser sign-in for {name}…", timeout=3)
        worker = None
        try:
            # Restore the caller's terminal while codex login owns stdin/stdout.
            with self.suspend():
                worker = self.run_worker(
                    partial(self._reauth_blocking, name),
                    thread=True,
                    group="reauth",
                    exit_on_error=False,
                    name=f"reauth-{name}",
                )
                result, refresh_result, snap = await worker.wait()
        except SuspendNotSupported:
            self.busy = False
            self.notify(
                "Interactive sign-in needs a local terminal",
                severity="warning",
            )
            self._drain_pending()
            return
        except (KeyboardInterrupt, WorkerCancelled):
            if worker is not None:
                worker.cancel()
            self.busy = False
            self.notify("Sign-in canceled", title="Saved profile unchanged")
            self._drain_pending()
            return
        except WorkerFailed as exc:
            self.busy = False
            self.notify(f"Sign-in failed: {exc.error}", severity="error")
            self._drain_pending()
            return

        self._reauth_done(
            name,
            active_before,
            result,
            refresh_result,
            snap,
        )

    def _reauth_blocking(
        self, name: str
    ) -> tuple[OperationResult, OperationResult, AccountsSnapshot]:
        result = _operation_result(self.backend.reauth(name))
        refresh_result = OperationResult(True)
        if result.ok:
            refresh_result = _operation_result(self.backend.refresh([name]))
        snap = self.backend.snapshot()
        if result.ok and refresh_result.ok:
            refreshed = next(
                (account for account in snap.accounts if account.name == name),
                None,
            )
            if (
                refreshed is None
                or refresh_result.generation is None
                or refreshed.usage.refresh_generation != refresh_result.generation
            ):
                refresh_result = OperationResult(
                    False,
                    75,
                    f"fresh usage was not confirmed for {name}",
                    refresh_result.generation,
                )
        return result, refresh_result, snap

    def _reauth_done(
        self,
        name: str,
        active_before: str | None,
        result: OperationResult,
        refresh_result: OperationResult,
        snap: AccountsSnapshot,
    ) -> None:
        self.busy = False
        self.snapshot = snap
        if result.ok:
            if snap.active_name == active_before:
                active_note = (
                    f" · {active_before} stayed active"
                    if active_before is not None
                    else " · active auth unchanged"
                )
                severity = "information"
            else:
                current = snap.active_name or "unmanaged auth"
                active_note = f" · active state is now {current}"
                severity = "warning"
            if refresh_result.ok:
                refresh_note = ""
            else:
                refresh_note = " · fresh usage not confirmed"
                severity = "warning"
            self.notify(
                f"Updated saved login for {name}{active_note}{refresh_note}",
                title="Sign-in complete",
                severity=severity,
            )
            if isinstance(self.screen, ReauthScreen):
                self.pop_screen()
        elif result.returncode == 130:
            self.notify("Sign-in canceled", title="Saved profile unchanged")
        else:
            message = _first_line(result.output) or "saved profile was not updated"
            self.notify(message, severity="warning")
            if result.output.strip():
                self.push_screen(OutputModal("Sign in again: details", result.output))
        self._drain_pending()

    # -- earned rate-limit resets -----------------------------------------

    def prepare_reset(self, name: str) -> None:
        if self.busy or self._refreshing:
            self.notify("Usage refresh is still running", severity="warning")
            return
        self.busy = True
        self.notify(f"Checking reset credits for {name}…", timeout=3)
        self.run_worker(
            partial(self._check_reset_blocking, name),
            thread=True,
            group="reset-check",
            exit_on_error=False,
            name=f"reset-check-{name}",
        )

    def _check_reset_blocking(self, name: str) -> None:
        result = _operation_result(self.backend.refresh([name]))
        snap = self.backend.snapshot()
        self.call_from_thread(self._reset_checked, name, result, snap)

    def _reset_checked(
        self,
        name: str,
        result: OperationResult,
        snap: AccountsSnapshot,
    ) -> None:
        self.busy = False
        self.snapshot = snap
        if not result.ok:
            message = _first_line(result.output) or "could not refresh reset credits"
            self.notify(message, severity="warning")
            if result.output.strip():
                self.push_screen(OutputModal("Reset check: details", result.output))
            self._drain_pending()
            return
        account = next((item for item in snap.accounts if item.name == name), None)
        count = account.usage.reset_credits_available if account is not None else None
        if count is None:
            self.notify(
                f"Codex did not report earned reset credits for {name}",
                severity="warning",
            )
            self._drain_pending()
            return
        if count <= 0:
            self.notify(
                f"No earned resets are available for {name}",
                severity="warning",
            )
            self._drain_pending()
            return
        if not isinstance(self.screen, ResetScreen):
            self._drain_pending()
            return
        noun = "reset" if count == 1 else "resets"
        remainder = count - 1
        remaining_copy = (
            "This is the last available reset."
            if remainder == 0
            else f"{remainder} will remain if it succeeds."
        )
        self.push_screen(
            ConfirmModal(
                f"Use 1 of {count} earned {noun} on {name}?\n\n"
                f"This resets an eligible Codex usage window. {remaining_copy}",
                title="Use earned reset?",
                yes_label="Use reset",
                default_cancel=True,
            ),
            partial(self._reset_confirmed, name),
        )
        self._drain_pending()

    def _reset_confirmed(self, name: str, confirmed: bool) -> None:
        if not confirmed:
            return
        if self.busy:
            self.notify("Another auth change is still running", severity="warning")
            return
        self.busy = True
        self.notify(f"Using one earned reset on {name}…", timeout=3)
        self.run_worker(
            partial(self._consume_reset_blocking, name),
            thread=True,
            group="reset",
            exit_on_error=False,
            name=f"reset-{name}",
        )

    def _consume_reset_blocking(self, name: str) -> None:
        result = _operation_result(self.backend.consume_reset(name))
        refresh_result = OperationResult(True)
        if result.ok:
            refresh_result = _operation_result(self.backend.refresh([name]))
        snap = self.backend.snapshot()
        self.call_from_thread(
            self._reset_done,
            name,
            result,
            refresh_result,
            snap,
        )

    def _reset_done(
        self,
        name: str,
        result: OperationResult,
        refresh_result: OperationResult,
        snap: AccountsSnapshot,
    ) -> None:
        self.busy = False
        self.snapshot = snap
        if result.ok:
            account = next((item for item in snap.accounts if item.name == name), None)
            remaining = (
                account.usage.reset_credits_available if account is not None else None
            )
            if not refresh_result.ok:
                suffix = " · usage refresh pending"
            else:
                suffix = (
                    f" · {remaining} remaining" if remaining is not None else ""
                )
            self.notify(f"Reset applied to {name}{suffix}", title="Earned reset")
            if isinstance(self.screen, ResetScreen):
                self.pop_screen()
        else:
            message = _first_line(result.output) or "reset was not applied"
            self.notify(message, severity="warning")
            if result.output.strip():
                self.push_screen(OutputModal("Use reset: details", result.output))
        self._drain_pending()

    # -- navigation --------------------------------------------------------

    def action_refresh_full(self) -> None:
        self.request_refresh(full=True, check_patch=True)
        label = "Reading engine state…" if self._store_only else "Refreshing usage…"
        self.notify(label, timeout=2)

    def action_open_auto(self) -> None:
        if not isinstance(self.screen, AutoScreen):
            self.push_screen(AutoScreen())

    def action_open_watch(self) -> None:
        if not isinstance(self.screen, WatchScreen):
            self.push_screen(WatchScreen())

    def action_open_resets(self) -> None:
        if not isinstance(self.screen, ResetScreen):
            self.push_screen(ResetScreen())

    def action_open_reauth(self) -> None:
        if isinstance(self.screen, AutoScreen):
            self.notify(
                "Leave Auto view before signing in again",
                severity="warning",
            )
            return
        if not isinstance(self.screen, ReauthScreen):
            self.push_screen(ReauthScreen())


def _operation_result(value: Any) -> OperationResult:
    if isinstance(value, OperationResult):
        return value
    if value is None:
        return OperationResult(True)
    ok = bool(getattr(value, "ok", getattr(value, "switched", False)))
    return OperationResult(
        ok=ok,
        returncode=int(getattr(value, "returncode", 0 if ok else 1)),
        output=str(getattr(value, "output", "")),
    )


def _patched_ready(backend: object) -> bool | None:
    value = getattr(backend, "patched_ready", None)
    if value is None:
        return None
    try:
        return bool(value() if callable(value) else value)
    except Exception:
        return False


def _first_line(text: str) -> str:
    return next((line.strip() for line in text.splitlines() if line.strip()), "")
