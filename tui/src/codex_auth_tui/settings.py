"""Validated auto-switch settings under one ``CODEX_HOME``."""

from __future__ import annotations

import json
import math
import os
import tempfile
from dataclasses import dataclass, replace
from pathlib import Path

from codex_auth_tui.paths import CodexPaths, resolve_paths

SETTINGS_SCHEMA_VERSION = 1


@dataclass(frozen=True)
class AutoSettings:
    """Small policy surface intentionally aligned with live watch mode."""

    threshold: float = 0.0
    interval_s: float = 60.0
    cooldown_s: float = 300.0
    hysteresis: float = 10.0
    refresh_timeout_s: float = 90.0

    def validated(self) -> "AutoSettings":
        defaults = AutoSettings()
        return replace(
            self,
            threshold=_bounded(self.threshold, defaults.threshold, 0.0, 99.9),
            interval_s=_bounded(self.interval_s, defaults.interval_s, 15.0, 3600.0),
            cooldown_s=_bounded(
                self.cooldown_s, defaults.cooldown_s, 0.0, 86400.0
            ),
            hysteresis=_bounded(self.hysteresis, defaults.hysteresis, 0.0, 100.0),
            refresh_timeout_s=_bounded(
                self.refresh_timeout_s, defaults.refresh_timeout_s, 1.0, 900.0
            ),
        )

    @classmethod
    def load(cls, paths: CodexPaths | Path | None = None) -> "AutoSettings":
        return load_settings(paths)

    def save(self, paths: CodexPaths | Path | None = None) -> None:
        save_settings(paths, self)

    # Compatibility names used by the first Textual pass.
    @property
    def interval_seconds(self) -> float:
        return self.interval_s

    @property
    def cooldown_seconds(self) -> float:
        return self.cooldown_s

    @property
    def hysteresis_pct(self) -> float:
        return self.hysteresis

    @property
    def include_api_key_accounts(self) -> bool:
        return False

    @property
    def unhealthy_ticks(self) -> int:
        return 1


# Import compatibility while the UI moves to the shorter stable name.
AutoSwitchSettings = AutoSettings

_KEYS = {
    "threshold": "threshold",
    "interval_s": "intervalSeconds",
    "cooldown_s": "cooldownSeconds",
    "hysteresis": "hysteresisPct",
    "refresh_timeout_s": "refreshTimeoutSeconds",
}


def _bounded(value: object, default: float, low: float, high: float) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        return default
    number = float(value)
    if not math.isfinite(number):
        return default
    return min(max(number, low), high)


def _path(target: CodexPaths | Path | None) -> Path:
    if target is None:
        return resolve_paths().settings_file
    if isinstance(target, CodexPaths):
        return target.settings_file
    candidate = getattr(target, "settings_file", None)
    return Path(candidate) if candidate is not None else Path(target)


def _read_raw(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (FileNotFoundError, OSError, UnicodeDecodeError, json.JSONDecodeError):
        return {}
    return value if isinstance(value, dict) else {}


def load_settings(target: CodexPaths | Path | None = None) -> AutoSettings:
    raw = _read_raw(_path(target))
    section = raw.get("autoswitch")
    if not isinstance(section, dict):
        return AutoSettings()
    values = {
        field: section[key]
        for field, key in _KEYS.items()
        if key in section
    }
    try:
        return AutoSettings(**values).validated()
    except TypeError:
        return AutoSettings()


def save_settings(
    target: CodexPaths | Path | None, settings: AutoSettings
) -> None:
    path = _path(target)
    normalized = settings.validated()
    raw = _read_raw(path)
    raw["schemaVersion"] = SETTINGS_SCHEMA_VERSION
    section = raw.get("autoswitch")
    if not isinstance(section, dict):
        section = {}
    for field, key in _KEYS.items():
        section[key] = getattr(normalized, field)
    # Old experimental settings must not accidentally re-enable API-key
    # switching after an upgrade.
    section["includeApiKeyAccounts"] = False
    raw["autoswitch"] = section
    atomic_write_json(path, raw)


def atomic_write_json(path: Path, data: dict) -> None:
    """Atomic JSON replace with private directory/file permissions."""

    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    try:
        os.chmod(path.parent, 0o700)
    except OSError:
        pass
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(data, stream, sort_keys=True, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, path)
        os.chmod(path, 0o600)
    except BaseException:
        try:
            os.unlink(temporary)
        except OSError:
            pass
        raise
