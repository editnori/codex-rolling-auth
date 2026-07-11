"""Shared fixtures. Every test that touches auth state runs under a temp
CODEX_HOME so it can never read or write the real ~/.codex."""

from __future__ import annotations

import base64
import json
import os
import stat
import time
from pathlib import Path

import pytest

from codex_auth_tui.paths import CodexPaths, resolve_paths


@pytest.fixture
def codex_home(tmp_path, monkeypatch) -> CodexPaths:
    """Isolated CODEX_HOME with the profile/backup/tmp dirs created."""
    home = tmp_path / "codex-home"
    home.mkdir()
    monkeypatch.setenv("CODEX_HOME", str(home))
    monkeypatch.setenv("HOME", str(tmp_path / "safe-home"))
    monkeypatch.delenv("CODEX_AUTH_STATE_FILE", raising=False)
    monkeypatch.delenv("CODEX_AUTH_PROFILES_DIR", raising=False)
    paths = resolve_paths()
    paths.profiles_dir.mkdir(parents=True, exist_ok=True)
    paths.backup_dir.mkdir(parents=True, exist_ok=True)
    paths.tmp_dir.mkdir(parents=True, exist_ok=True)
    return paths


def write_profile(paths: CodexPaths, name: str, data: dict) -> Path:
    path = paths.profiles_dir / f"{name}.json"
    path.write_text(json.dumps(data), encoding="utf-8")
    return path


def chatgpt_profile(name: str, *, refresh_token: str | None = None) -> dict:
    claims = {
        "sub": f"user-{name}",
        "https://api.openai.com/auth": {
            "chatgpt_account_id": f"account-{name}",
            "chatgpt_user_id": f"user-{name}",
        },
    }
    header = base64.urlsafe_b64encode(b'{"alg":"none"}').decode().rstrip("=")
    payload = (
        base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip("=")
    )
    return {
        "tokens": {
            "refresh_token": refresh_token or f"rt-{name}",
            "access_token": f"at-{name}",
            "account_id": f"account-{name}",
            "id_token": f"{header}.{payload}.",
        }
    }


def api_key_profile() -> dict:
    return {"OPENAI_API_KEY": "sk-test-key"}


def seed_state(paths: CodexPaths, profiles: dict[str, dict], *, now: float | None = None) -> None:
    """Write auth-state.json entries. ``profiles`` maps name -> {fingerprint, payload, age}."""
    now = time.time() if now is None else now
    out = {"version": 1, "updated_at": now, "profiles": {}}
    for name, spec in profiles.items():
        out["profiles"][name] = {
            "updated_at": now - spec.get("age", 0.0),
            "fingerprint": spec["fingerprint"],
            "payload": spec["payload"],
        }
        if spec.get("generation") is not None:
            out["profiles"][name]["refresh_generation"] = spec["generation"]
    paths.state_file.write_text(json.dumps(out), encoding="utf-8")


def rate_payload(
    primary_pct: float,
    secondary_pct: float,
    *,
    reset_in: float = 3600.0,
    reset_credits: int | None = None,
) -> dict:
    reset = time.time() + reset_in
    payload = {
        "rateLimitsByLimitId": {
            "codex": {
                "planType": "pro",
                "primary": {
                    "usedPercent": primary_pct,
                    "windowDurationMins": 300,
                    "resetsAt": reset,
                },
                "secondary": {
                    "usedPercent": secondary_pct,
                    "windowDurationMins": 10080,
                    "resetsAt": reset,
                },
            }
        }
    }
    if reset_credits is not None:
        payload["rateLimitResetCredits"] = {
            "availableCount": reset_credits,
            "credits": None,
        }
    return payload


@pytest.fixture
def fake_codex_auth(codex_home: CodexPaths, tmp_path, monkeypatch) -> Path:
    """A fake ``codex-auth`` that logs args and performs save/switch copies."""
    log = tmp_path / "codex-auth.log"
    script = tmp_path / "codex-auth"
    script.write_text(
        "#!/usr/bin/env bash\n"
        'echo "$@" >> "%s"\n'
        'cmd="$1"; shift || true\n'
        'case "$cmd" in\n'
        "  use)\n"
        '    name="$1"\n'
        '    cp "$CODEX_HOME/auth-profiles/$name.json" "$CODEX_HOME/auth.json"\n'
        '    echo "active $name"\n'
        "    ;;\n"
        "  use-if-current)\n"
        '    expected="$1"; target="$2"\n'
        '    cmp -s "$CODEX_HOME/auth.json" "$CODEX_HOME/auth-profiles/$expected.json" || exit 75\n'
        '    cp "$CODEX_HOME/auth-profiles/$target.json" "$CODEX_HOME/auth.json"\n'
        '    echo "active $target"\n'
        "    ;;\n"
        "  add)\n"
        '    name="$1"; mode="$2"\n'
        '    [[ "$mode" == "--current" ]] || exit 64\n'
        '    cp "$CODEX_HOME/auth.json" "$CODEX_HOME/auth-profiles/$name.json" || exit 1\n'
        '    echo "saved $name"\n'
        "    ;;\n"
        "  reset)\n"
        '    name="$1"; yes="$2"\n'
        '    [[ "$yes" == "--yes" ]] || exit 64\n'
        '    echo "used reset $name"\n'
        "    ;;\n"
        "  refresh) : ;;\n"
        "esac\n" % log,
        encoding="utf-8",
    )
    script.chmod(script.stat().st_mode | stat.S_IEXEC | stat.S_IXGRP | stat.S_IXOTH)
    monkeypatch.setenv("CODEX_AUTH_BIN", str(script))
    return log
