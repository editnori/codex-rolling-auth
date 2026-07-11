"""Resolve Codex auth paths from the environment.

Mirrors the derivation in ``bin/codex-auth`` exactly, including the path
override envs the shell honors (``CODEX_AUTH_STATE_FILE``,
``CODEX_AUTH_PROFILES_DIR``, and ``CODEX_AUTH_ACTIVE_PROFILE_FILE``). Every
path is derived from ``CODEX_HOME`` so a
test that points ``CODEX_HOME`` at a temp dir is fully isolated from the real
``~/.codex`` — the same guarantee the shell test suite relies on.
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


@dataclass(frozen=True)
class CodexPaths:
    """The auth-related paths under one ``CODEX_HOME``."""

    home: Path
    auth_file: Path
    profiles_dir: Path
    backup_dir: Path
    state_file: Path
    active_profile_file: Path

    @property
    def tmp_dir(self) -> Path:
        return self.home / ".tmp"

    @property
    def autoswitch_state_file(self) -> Path:
        """Engine cooldown/quarantine state, beside the usage state file."""
        return self.home / "autoswitch-state.json"

    @property
    def settings_file(self) -> Path:
        return self.home / "auth-settings.json"


def resolve_paths(env: dict[str, str] | None = None) -> CodexPaths:
    """Resolve paths from ``env`` (defaults to ``os.environ``)."""
    env = os.environ if env is None else env
    home = Path(env.get("CODEX_HOME") or (Path.home() / ".codex"))
    profiles = env.get("CODEX_AUTH_PROFILES_DIR") or str(home / "auth-profiles")
    state = env.get("CODEX_AUTH_STATE_FILE") or str(home / "auth-state.json")
    active_profile = env.get("CODEX_AUTH_ACTIVE_PROFILE_FILE") or str(
        home / "active-profile.json"
    )
    return CodexPaths(
        home=home,
        auth_file=home / "auth.json",
        profiles_dir=Path(profiles),
        backup_dir=home / "auth-backups",
        state_file=Path(state),
        active_profile_file=Path(active_profile),
    )
