"""Pilot smoke tests for the structured Textual surface."""

from __future__ import annotations

import asyncio
from contextlib import nullcontext
import dataclasses
import threading
import time

import pytest
from textual.widgets import Button, ListView, RichLog, Static

from codex_auth_tui.backend import OperationResult
from codex_auth_tui.engine import AutoEvent, Decision
from codex_auth_tui.models import (
    AccountSnapshot,
    AccountsSnapshot,
    AccountUsage,
    UsageWindow,
)
from codex_auth_tui.settings import AutoSettings
from codex_auth_tui.tui.app import CodexAuthApp
from codex_auth_tui.tui.autoview import AutoScreen
from codex_auth_tui.tui.dashboard import ReauthScreen, ResetScreen, WatchScreen
from codex_auth_tui.tui.modals import ConfirmModal, ProfileNameModal
from codex_auth_tui.tui.widgets import (
    AccountCard,
    AccountItem,
    RuntimeStatus,
    account_card_text,
    bar_cells,
    mini_account_text,
)


def _usage(
    short: float,
    weekly: float,
    *,
    reset_credits: int | None = None,
) -> AccountUsage:
    now = time.time()
    return AccountUsage(
        windows=(
            UsageWindow("5h", short, 300, now + 3600),
            UsageWindow("7d", weekly, 10080, now + 86400),
        ),
        plan_type="pro",
        fetched_at=now,
        age_s=0,
        reset_credits_available=reset_credits,
    )


def _account(
    name: str,
    short: float,
    weekly: float,
    *,
    active=False,
    reset_credits: int | None = None,
):
    return AccountSnapshot(
        name=name,
        is_active=active,
        kind="chatgpt",
        switchable=True,
        usage=_usage(short, weekly, reset_credits=reset_credits),
    )


def _login_required_account(name: str, *, active: bool = False) -> AccountSnapshot:
    now = time.time()
    return AccountSnapshot(
        name=name,
        is_active=active,
        kind="chatgpt",
        switchable=True,
        usage=AccountUsage(
            fetched_at=now,
            age_s=0,
            last_error=(
                "Your access token could not be refreshed because you have since "
                "logged out or signed in to another account. Please sign in again."
            ),
        ),
    )


def _reauth_click_meta(rendered) -> tuple[str, tuple[str, ...]]:
    start = rendered.plain.index("sign in again")
    end = start + len("sign in again")
    for span in rendered.spans:
        if span.start == start and span.end == end and hasattr(span.style, "meta"):
            return span.style.meta["@click"]
    raise AssertionError("sign-in link has no @click metadata")


class FakeBackend:
    def __init__(self, paths) -> None:
        self.paths = paths
        self.active = "work"
        self.accounts = [
            _account("work", 78, 42, active=True),
            _account("personal", 22, 18),
        ]
        self.calls: list[str] = []

    def snapshot(self, now=None) -> AccountsSnapshot:
        self.calls.append("snapshot")
        accounts = tuple(
            dataclasses.replace(account, is_active=account.name == self.active)
            for account in self.accounts
        )
        return AccountsSnapshot(
            active_name=self.active,
            accounts=accounts,
            taken_at=time.time() if now is None else now,
        )

    def refresh(self, names=None) -> OperationResult:
        self.calls.append("refresh")
        generation = f"fake-generation-{len(self.calls)}"
        if names:
            self.calls.append(f"refresh:{','.join(names)}")
            selected = set(names)
            self.accounts = [
                dataclasses.replace(
                    account,
                    usage=dataclasses.replace(
                        account.usage,
                        refresh_generation=generation,
                    ),
                )
                if account.name in selected
                else account
                for account in self.accounts
            ]
        return OperationResult(True, generation=generation)

    def switch(
        self,
        name: str,
        *,
        expected_current: str | None = None,
        expected_generation: str | None = None,
    ) -> OperationResult:
        self.calls.append(f"switch:{name}")
        self.active = name
        return OperationResult(True)

    def save_current(self, name: str) -> OperationResult:
        self.calls.append(f"save:{name}")
        current = next(account for account in self.accounts if account.name == self.active)
        saved = dataclasses.replace(current, name=name, is_active=False)
        self.accounts = [account for account in self.accounts if account.name != name]
        self.accounts.append(saved)
        return OperationResult(True)

    def reauth(self, name: str) -> OperationResult:
        self.calls.append(f"reauth:{name}")
        self.accounts = [
            dataclasses.replace(account, usage=_usage(12, 8))
            if account.name == name
            else account
            for account in self.accounts
        ]
        return OperationResult(True)

    def consume_reset(self, name: str) -> OperationResult:
        self.calls.append(f"reset:{name}")
        updated = []
        for account in self.accounts:
            if account.name != name:
                updated.append(account)
                continue
            count = account.usage.reset_credits_available
            usage = dataclasses.replace(
                account.usage,
                reset_credits_available=max(0, (count or 0) - 1),
                windows=tuple(
                    dataclasses.replace(window, pct=0.0)
                    for window in account.usage.windows
                ),
            )
            updated.append(dataclasses.replace(account, usage=usage))
        self.accounts = updated
        return OperationResult(True)

    def patched_ready(self) -> bool:
        self.calls.append("patched_ready")
        return True


def make_app(backend: FakeBackend, *, start="watch", start_live=False):
    return CodexAuthApp(
        backend,
        settings=AutoSettings(
            threshold=90,
            interval_s=3600,
            cooldown_s=300,
            hysteresis=10,
        ),
        start=start,
        start_live=start_live,
    )


async def settle(pilot) -> None:
    pending = [
        worker
        for worker in pilot.app.workers
        if worker.group not in {"engine"}
    ]
    if pending:
        await pilot.app.workers.wait_for_complete(pending)
    await pilot.pause()
    await pilot.pause()


class FakeEngine:
    instances: list["FakeEngine"] = []

    def __init__(
        self,
        backend,
        settings,
        on_event=None,
        dry_run=True,
        **_kwargs,
    ) -> None:
        self.backend = backend
        self.settings = settings
        self.on_event = on_event
        self.dry_run = dry_run
        self.stopped = False
        self._stop = threading.Event()
        self.instances.append(self)

    def run_loop(self) -> None:
        if self.on_event:
            self.on_event(
                AutoEvent("decision", "hold: below_threshold", time.time())
            )
        self._stop.wait(30)

    def tick(self) -> Decision:
        if self.on_event:
            self.on_event(
                AutoEvent("refresh_finished", "usage refresh finished", time.time())
            )
        return Decision("hold", "below_threshold", current="work")

    def stop(self) -> None:
        self.stopped = True
        self._stop.set()

    def wait_stopped(self, timeout=None) -> bool:
        return self._stop.wait(timeout)


@pytest.fixture
def fake_engine(monkeypatch):
    FakeEngine.instances = []
    monkeypatch.setattr(
        "codex_auth_tui.tui.autoview.AutoSwitchEngine", FakeEngine
    )
    return FakeEngine


@pytest.mark.asyncio
async def test_mounts_passive_watch_with_full_cards_and_patch_boundary(codex_home):
    backend = FakeBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)

        assert isinstance(app.screen, WatchScreen)
        accounts = app.screen.query_one("#accounts", ListView)
        assert len(list(accounts.query(AccountItem))) == 2
        assert accounts.index is None
        status = app.screen.query_one(RuntimeStatus).render().plain
        assert "patched ready" in status
        assert backend.calls.count("refresh") == 1


@pytest.mark.asyncio
async def test_patch_poll_observes_detached_build_completion(codex_home):
    class TransitionBackend(FakeBackend):
        patch_ready = False

        def patched_ready(self) -> bool:
            self.calls.append("patched_ready")
            return self.patch_ready

    backend = TransitionBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        assert app.patched_ready_state is False

        backend.patch_ready = True
        app._patch_tick()
        await settle(pilot)

        assert app.patched_ready_state is True
        assert backend.calls.count("patched_ready") >= 2


@pytest.mark.asyncio
async def test_cached_snapshot_is_published_before_network_refresh(codex_home):
    refresh_started = threading.Event()
    release_refresh = threading.Event()

    class BlockingBackend(FakeBackend):
        def refresh(self) -> OperationResult:
            self.calls.append("refresh")
            refresh_started.set()
            assert release_refresh.wait(2)
            return OperationResult(True)

    backend = BlockingBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(70, 24)) as pilot:
        try:
            for _ in range(100):
                if app.snapshot is not None and refresh_started.is_set():
                    break
                await asyncio.sleep(0.01)
            assert app.snapshot is not None
            assert app.snapshot.active_name == "work"
            assert refresh_started.is_set()
        finally:
            release_refresh.set()
        await settle(pilot)


@pytest.mark.asyncio
async def test_passive_selection_switches_and_stays_watching(codex_home):
    backend = FakeBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        accounts = app.screen.query_one("#accounts", ListView)

        await pilot.press("s")
        await pilot.pause()
        assert accounts.index == 0

        await pilot.press("down", "enter")
        await settle(pilot)

        assert "switch:personal" in backend.calls
        assert backend.active == "personal"
        assert isinstance(app.screen, WatchScreen)
        assert app.screen.query_one("#accounts", ListView).index is None


@pytest.mark.asyncio
async def test_escape_disarms_before_leaving_watch(codex_home):
    app = make_app(FakeBackend(codex_home))

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("s", "escape")
        await pilot.pause()
        assert isinstance(app.screen, WatchScreen)
        assert app.screen.query_one("#accounts", ListView).index is None


@pytest.mark.asyncio
async def test_watch_saves_current_auth_as_a_named_profile(codex_home):
    backend = FakeBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("n")
        await pilot.pause()

        assert isinstance(app.screen, ProfileNameModal)
        await pilot.press(*tuple("captured"), "enter")
        await settle(pilot)

        assert "save:captured" in backend.calls
        assert app.snapshot is not None
        assert any(account.name == "captured" for account in app.snapshot.accounts)
        assert isinstance(app.screen, WatchScreen)


@pytest.mark.asyncio
async def test_save_current_validates_names_and_confirms_replacement(codex_home):
    backend = FakeBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("n")
        await pilot.pause()
        await pilot.press("b", "a", "d", "space", "n", "a", "m", "e", "enter")
        await pilot.pause()

        assert isinstance(app.screen, ProfileNameModal)
        error = app.screen.query_one("#profile-name-error", Static).render().plain
        assert "Use only" in error
        assert not any(call.startswith("save:") for call in backend.calls)

        await pilot.press("escape", "n")
        await pilot.pause()
        await pilot.press("w", "o", "r", "k", "enter")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)

        await pilot.press("y")
        await settle(pilot)
        assert "save:work" in backend.calls


def test_full_and_mini_login_errors_expose_safe_click_actions():
    name = "odd');app.quit()"
    account = _login_required_account(name)

    for rendered in (
        account_card_text(account, 90),
        mini_account_text(account, time.time()),
    ):
        assert "sign in again" in rendered.plain
        assert _reauth_click_meta(rendered) == ("app.reauth", (name,))

    mismatched = dataclasses.replace(
        account,
        usage=dataclasses.replace(account.usage, fingerprint_match=False),
    )
    assert mismatched.usage.requires_login is False
    assert "sign in again" not in account_card_text(mismatched, 90).plain
    assert "sign in again" not in mini_account_text(mismatched, time.time()).plain


@pytest.mark.asyncio
async def test_login_link_targets_the_selected_saved_profile(codex_home):
    backend = FakeBackend(codex_home)
    backend.accounts[1] = _login_required_account("personal")
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        account = next(item for item in app.snapshot.accounts if item.name == "personal")
        action_name, params = _reauth_click_meta(account_card_text(account, 90))
        namespace, action = action_name.split(".", 1)

        await app.run_action((namespace, action, params))
        await pilot.pause()

        assert isinstance(app.screen, ConfirmModal)
        body = app.screen.query_one(".modal-body", Static).render().plain
        assert "Only the selected saved profile (personal) is reauthenticated" in body
        assert "current active profile (work) stays active" in body
        assert not any(call.startswith("reauth:") for call in backend.calls)
        await pilot.press("n")
        await pilot.pause()

        app.prepare_reauth("work")
        await pilot.pause()
        active_body = app.screen.query_one(".modal-body", Static).render().plain
        assert "current active profile (work) stays active" in active_body
        assert "live credential is refreshed in place" in active_body
        await pilot.press("n")


@pytest.mark.asyncio
async def test_keyboard_reauth_cancels_safely_then_refreshes_only_selected_profile(
    codex_home, monkeypatch
):
    monkeypatch.setattr(CodexAuthApp, "suspend", lambda self: nullcontext())
    backend = FakeBackend(codex_home)
    backend.accounts[1] = _login_required_account("personal")
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("i")
        await pilot.pause()

        assert isinstance(app.screen, ReauthScreen)
        assert app.screen.query_one("#accounts", ListView).index == 1

        await pilot.press("enter")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)
        assert app.screen.query_one("#no", Button).has_focus

        await pilot.press("n")
        await pilot.pause()
        assert isinstance(app.screen, ReauthScreen)
        assert "reauth:personal" not in backend.calls
        assert backend.active == "work"

        await pilot.press("enter")
        await pilot.pause()
        await pilot.press("y")
        await settle(pilot)

        assert "reauth:personal" in backend.calls
        assert "refresh:personal" in backend.calls
        assert backend.calls.index("reauth:personal") < backend.calls.index(
            "refresh:personal"
        )
        assert backend.active == "work"
        assert app.snapshot is not None
        assert app.snapshot.active_name == "work"
        personal = next(
            item for item in app.snapshot.accounts if item.name == "personal"
        )
        assert personal.usage.requires_login is False
        assert personal.usage.refresh_generation is not None
        assert isinstance(app.screen, WatchScreen)


@pytest.mark.asyncio
async def test_reauth_worker_error_returns_to_the_tui(
    codex_home, monkeypatch
):
    monkeypatch.setattr(CodexAuthApp, "suspend", lambda self: nullcontext())

    class ErrorBackend(FakeBackend):
        def reauth(self, name: str) -> OperationResult:
            self.calls.append(f"reauth:{name}")
            raise RuntimeError("browser login worker failed")

    backend = ErrorBackend(codex_home)
    backend.accounts[1] = _login_required_account("personal")
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("i", "enter")
        await pilot.pause()
        await pilot.press("y")
        for _ in range(50):
            await pilot.pause()
            if not app.busy:
                break

        assert app.busy is False
        assert backend.active == "work"
        assert "reauth:personal" in backend.calls
        assert "refresh:personal" not in backend.calls
        assert isinstance(app.screen, ReauthScreen)


def test_reauth_does_not_call_cached_fallback_a_fresh_usage_result(codex_home):
    class CachedFallbackBackend(FakeBackend):
        def refresh(self, names=None) -> OperationResult:
            self.calls.append("refresh")
            if names:
                self.calls.append(f"refresh:{','.join(names)}")
            return OperationResult(True, generation="new-login-generation")

    backend = CachedFallbackBackend(codex_home)
    backend.accounts[1] = _login_required_account("personal")
    app = make_app(backend)

    result, refresh_result, snap = app._reauth_blocking("personal")

    personal = next(item for item in snap.accounts if item.name == "personal")
    assert result.ok is True
    assert refresh_result.ok is False
    assert refresh_result.generation == "new-login-generation"
    assert "fresh usage was not confirmed" in refresh_result.output
    assert personal.usage.refresh_generation is None


@pytest.mark.asyncio
async def test_watch_checks_and_uses_an_earned_reset_without_switching(codex_home):
    backend = FakeBackend(codex_home)
    backend.accounts[0] = _account(
        "work",
        100,
        100,
        active=True,
        reset_credits=2,
    )
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        card = app.screen.query_one(AccountCard).render()
        assert "2 earned resets" in card.plain

        await pilot.press("u")
        await pilot.pause()
        assert isinstance(app.screen, ResetScreen)

        await pilot.press("enter")
        await settle(pilot)
        assert "refresh:work" in backend.calls
        assert isinstance(app.screen, ConfirmModal)
        assert app.screen.query_one("#no", Button).has_focus

        await pilot.press("y")
        await settle(pilot)

        assert backend.calls.count("reset:work") == 1
        assert backend.active == "work"
        assert app.snapshot is not None
        account = next(item for item in app.snapshot.accounts if item.name == "work")
        assert account.usage.reset_credits_available == 1
        assert isinstance(app.screen, WatchScreen)


@pytest.mark.asyncio
async def test_reset_confirmation_defaults_to_cancel(codex_home):
    backend = FakeBackend(codex_home)
    backend.accounts[0] = _account(
        "work",
        100,
        100,
        active=True,
        reset_credits=1,
    )
    app = make_app(backend)

    async with app.run_test(size=(104, 34)) as pilot:
        await settle(pilot)
        await pilot.press("u", "enter")
        await settle(pilot)
        assert isinstance(app.screen, ConfirmModal)

        await pilot.press("enter")
        await pilot.pause()

        assert isinstance(app.screen, ResetScreen)
        assert "reset:work" not in backend.calls


@pytest.mark.asyncio
async def test_auto_opens_dry_then_confirms_live_and_cleans_up(
    codex_home, fake_engine
):
    backend = FakeBackend(codex_home)
    app = make_app(backend)

    async with app.run_test(size=(104, 38)) as pilot:
        await settle(pilot)
        await pilot.press("a")
        await pilot.pause()

        assert isinstance(app.screen, AutoScreen)
        assert len(fake_engine.instances) == 1
        assert fake_engine.instances[0].dry_run is True
        assert app._store_only is True
        await pilot.pause()
        assert app.screen.query_one("#event-log", RichLog).lines

        dry_engine = fake_engine.instances[0]
        await pilot.press("i")
        await pilot.pause()
        await app.run_action(("app", "reauth", ("personal",)))
        await pilot.pause()
        assert isinstance(app.screen, AutoScreen)
        assert fake_engine.instances == [dry_engine]
        assert dry_engine.stopped is False
        assert not any(call.startswith("reauth:") for call in backend.calls)

        await pilot.press("l")
        await pilot.pause()
        assert isinstance(app.screen, ConfirmModal)
        await pilot.press("y")
        await settle(pilot)

        assert fake_engine.instances[0].stopped is True
        assert fake_engine.instances[-1].dry_run is False

        await pilot.press("escape")
        await settle(pilot)
        assert isinstance(app.screen, WatchScreen)
        assert fake_engine.instances[-1].stopped is True
        assert app._store_only is False


def test_cli_watch_option_validation_and_live_implication(monkeypatch, codex_home):
    from codex_auth_tui import cli

    launched = {}

    class FakeApp:
        return_code = 0

        def __init__(self, **kwargs):
            launched.update(kwargs)

        def run(self):
            launched["ran"] = True

    monkeypatch.setattr("codex_auth_tui.tui.app.CodexAuthApp", FakeApp)
    code = cli.main(
        [
            "watch",
            "--live",
            "--threshold",
            "87.5",
            "--interval",
            "30",
            "--cooldown",
            "20",
            "--hysteresis",
            "5",
        ]
    )

    assert code == 0
    assert launched["start"] == "auto"
    assert launched["start_live"] is True
    assert launched["settings"].threshold == 87.5
    assert launched["settings"].interval_s == 30


def test_bare_help_is_watch_help(capsys):
    from codex_auth_tui import cli

    with pytest.raises(SystemExit) as stopped:
        cli.main(["--help"])

    assert stopped.value.code == 0
    output = capsys.readouterr().out
    assert "--auto" in output
    assert "--live" in output
    assert "--threshold" in output


def test_any_better_mode_does_not_draw_a_zero_percent_tick():
    assert "┃" not in bar_cells(40, 20, threshold=0).plain
    assert "┃" in bar_cells(40, 20, threshold=90).plain


@pytest.mark.parametrize(
    "args",
    [
        ["watch", "--threshold", "100"],
        ["watch", "--interval", "14"],
        ["watch", "--cooldown", "-1"],
        ["watch", "--hysteresis", "-1"],
    ],
)
def test_cli_rejects_unsafe_watch_values(args):
    from codex_auth_tui.cli import build_parser

    with pytest.raises(SystemExit):
        build_parser().parse_args(args)
