"""Shell backend tests; every path is rooted in a temporary CODEX_HOME."""

from __future__ import annotations

import hashlib
import json
import time

from codex_auth_tui.backend import (
    ShellBackend,
    _account_identity,
    _auth_revision,
    credential_fingerprint,
)
from codex_auth_tui.models import AccountUsage
from conftest import (
    api_key_profile,
    chatgpt_profile,
    rate_payload,
    seed_state,
    write_profile,
)


def test_fingerprints_match_shell_selector_with_trailing_newline(codex_home):
    chat = write_profile(codex_home, "chat", {"tokens": {"refresh_token": "RT"}})
    access = write_profile(codex_home, "access", {"tokens": {"access_token": "AT"}})
    key = write_profile(codex_home, "key", {"OPENAI_API_KEY": "sk-test"})

    assert credential_fingerprint(chat) == hashlib.sha256(b"chatgpt:RT\n").hexdigest()
    assert credential_fingerprint(access) == hashlib.sha256(
        b"chatgpt-access:AT\n"
    ).hexdigest()
    assert credential_fingerprint(key) == hashlib.sha256(b"api:sk-test\n").hexdigest()


def test_snapshot_reads_structured_state_and_identifies_active(codex_home):
    work = write_profile(codex_home, "work", chatgpt_profile("work"))
    alt = write_profile(codex_home, "alt", chatgpt_profile("alt"))
    write_profile(codex_home, "key", api_key_profile())
    write_profile(codex_home, "broken", {"tokens": {}})
    codex_home.auth_file.write_bytes(work.read_bytes())

    seed_state(
        codex_home,
        {
            "work": {
                "fingerprint": credential_fingerprint(work),
                "payload": rate_payload(41, 12, reset_credits=2),
            },
            "alt": {
                "fingerprint": credential_fingerprint(alt),
                "payload": rate_payload(20, 30),
            },
        },
    )

    auth_before = codex_home.auth_file.read_bytes()
    snap = ShellBackend(codex_home, cli="/does/not/run").snapshot()
    accounts = {account.name: account for account in snap.accounts}

    assert codex_home.auth_file.read_bytes() == auth_before
    assert snap.active_name == "work"
    assert snap.active_unmanaged is False
    assert accounts["work"].is_active is True
    assert accounts["work"].usage.binding_pct() == 41
    assert accounts["work"].usage.reset_credits_available == 2
    assert [window.window_mins for window in accounts["work"].usage.windows] == [
        300,
        10080,
    ]
    assert accounts["alt"].switchable is True
    assert accounts["key"].usage.sentinel == "api key"
    assert accounts["key"].switchable is False
    assert accounts["broken"].usage.sentinel == "invalid profile"
    assert accounts["broken"].switchable is False


def test_snapshot_rejects_state_for_a_different_credential(codex_home):
    work = write_profile(codex_home, "work", chatgpt_profile("work"))
    codex_home.auth_file.write_bytes(work.read_bytes())
    seed_state(
        codex_home,
        {
            "work": {
                "fingerprint": "not-the-current-credential",
                "payload": rate_payload(10, 20),
            }
        },
    )

    account = ShellBackend(codex_home).snapshot().accounts[0]
    assert account.usage.fingerprint_match is False
    assert account.usage.stale is True
    assert account.usage.decision_value() is None


def test_reset_credit_count_distinguishes_unknown_zero_and_positive():
    missing = rate_payload(10, 20)
    zero = rate_payload(10, 20, reset_credits=0)
    positive = rate_payload(10, 20, reset_credits=3)
    malformed = rate_payload(10, 20)
    malformed["rateLimitResetCredits"] = {"availableCount": -4}

    def usage(payload):
        return AccountUsage.from_payload(
            payload,
            age_s=0,
            fetched_at=time.time(),
        )

    assert usage(missing).reset_credits_available is None
    assert usage(zero).reset_credits_available == 0
    assert usage(positive).reset_credits_available == 3
    assert usage(malformed).reset_credits_available == 0


def test_snapshot_marks_old_or_future_cache_stale(codex_home):
    work = write_profile(codex_home, "work", chatgpt_profile("work"))
    codex_home.auth_file.write_bytes(work.read_bytes())
    seed_state(
        codex_home,
        {
            "work": {
                "fingerprint": credential_fingerprint(work),
                "payload": rate_payload(10, 20),
            }
        },
        now=1000.0,
    )

    backend = ShellBackend(codex_home)
    assert backend.snapshot(now=1401.0).accounts[0].usage.stale is True
    future = backend.snapshot(now=900.0).accounts[0].usage
    assert future.age_s is None
    assert future.stale is True


def test_snapshot_distinguishes_unmanaged_active_auth(codex_home):
    write_profile(codex_home, "work", chatgpt_profile("work"))
    codex_home.auth_file.write_text(
        json.dumps({"tokens": {"refresh_token": "outside-profile-set"}}),
        encoding="utf-8",
    )

    snap = ShellBackend(codex_home).snapshot()
    assert snap.active_name is None
    assert snap.active_unmanaged is True


def test_snapshot_uses_validated_marker_after_live_token_rotation(codex_home):
    saved_data = chatgpt_profile("work")
    live_data = chatgpt_profile("work", refresh_token="rt-work-rotated")
    work = write_profile(codex_home, "work", saved_data)
    codex_home.auth_file.write_text(json.dumps(live_data), encoding="utf-8")
    identity = _account_identity(live_data)
    codex_home.active_profile_file.write_text(
        json.dumps(
            {
                "version": 2,
                "profile": "work",
                "kind": "chatgpt",
                "account_identity": identity,
                "profile_fingerprint": credential_fingerprint(work),
                "profile_revision": _auth_revision(saved_data),
            }
        ),
        encoding="utf-8",
    )

    snap = ShellBackend(codex_home).snapshot()

    assert snap.active_name == "work"
    assert snap.active_unmanaged is False
    assert snap.accounts[0].is_active is True


def test_snapshot_rejects_tampered_or_cross_account_marker(codex_home):
    saved_data = chatgpt_profile("work")
    live_data = chatgpt_profile("other", refresh_token="rt-other-rotated")
    work = write_profile(codex_home, "work", saved_data)
    codex_home.auth_file.write_text(json.dumps(live_data), encoding="utf-8")
    codex_home.active_profile_file.write_text(
        json.dumps(
            {
                "version": 2,
                "profile": "work",
                "kind": "chatgpt",
                "account_identity": _account_identity(saved_data),
                "profile_fingerprint": credential_fingerprint(work),
                "profile_revision": _auth_revision(saved_data),
            }
        ),
        encoding="utf-8",
    )

    snap = ShellBackend(codex_home).snapshot()

    assert snap.active_name is None
    assert snap.active_unmanaged is True
    assert snap.accounts[0].is_active is False


def test_refresh_switch_and_patch_check_use_short_lived_fake_cli(
    codex_home, fake_codex_auth
):
    work = write_profile(codex_home, "work", chatgpt_profile("work"))
    write_profile(codex_home, "alt", chatgpt_profile("alt"))
    codex_home.auth_file.write_bytes(work.read_bytes())
    backend = ShellBackend(codex_home)

    refreshed = backend.refresh()
    saved = backend.save_current("captured")
    reset = backend.consume_reset("alt")
    switched = backend.switch(
        "alt", expected_current="work", expected_generation="generation-1"
    )

    assert refreshed.ok is True
    assert refreshed.generation
    assert saved.ok is True
    assert reset.ok is True
    assert (codex_home.profiles_dir / "captured.json").read_bytes() == work.read_bytes()
    assert switched.ok is True
    assert backend.snapshot().active_name == "alt"
    assert backend.patched_ready() is True
    log = fake_codex_auth.read_text(encoding="utf-8")
    assert "refresh --quiet --fast" in log
    assert "add captured --current" in log
    assert "reset alt --yes" in log
    assert "use-if-current work alt generation-1" in log
    assert "patch-codex --print-bin --quiet" in log


def test_backend_preserves_explicit_path_overrides(codex_home, tmp_path):
    profiles = tmp_path / "custom-profiles"
    state = tmp_path / "custom-state.json"
    profiles.mkdir()
    backend = ShellBackend(
        codex_home,
        cli=tmp_path / "missing-cli",
        env={
            "CODEX_AUTH_PROFILES_DIR": str(profiles),
            "CODEX_AUTH_STATE_FILE": str(state),
            "EXTRA_TEST_VALUE": "kept",
        },
    )

    # Explicit CodexPaths are authoritative, while unrelated injected env is
    # retained for the child process.
    assert backend.env["CODEX_HOME"] == str(codex_home.home)
    assert backend.env["CODEX_AUTH_PROFILES_DIR"] == str(codex_home.profiles_dir)
    assert backend.env["CODEX_AUTH_STATE_FILE"] == str(codex_home.state_file)
    assert backend.env["CODEX_AUTH_ACTIVE_PROFILE_FILE"] == str(
        codex_home.active_profile_file
    )
    assert backend.env["EXTRA_TEST_VALUE"] == "kept"


def test_timeout_kills_descendants_even_after_cli_leader_exits(
    codex_home, tmp_path
):
    cli = tmp_path / "forking-codex-auth"
    cli.write_text(
        "#!/usr/bin/env bash\n"
        "(sleep 30) &\n"
        "exit 0\n",
        encoding="utf-8",
    )
    cli.chmod(0o755)
    backend = ShellBackend(codex_home, cli=cli)

    started = time.monotonic()
    result = backend.refresh(timeout_s=0.1)
    elapsed = time.monotonic() - started

    assert result.ok is False
    assert result.returncode == 124
    assert elapsed < 3.0
