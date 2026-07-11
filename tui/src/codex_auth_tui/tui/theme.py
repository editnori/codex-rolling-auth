"""The "codex-auth-dark" Textual theme and shared color constants."""

from __future__ import annotations

from textual.theme import Theme

ACCENT = "#d7875f"  # warm terracotta
FOREGROUND = "#e8e4de"
MUTED = "#8a8a8a"
BACKGROUND = "#141414"
SURFACE = "#1e1e1e"
PANEL = "#262626"

SEV_OK = "#87af87"  # plenty of headroom
SEV_WARN = "#d7af5f"  # climbing (>= 70%)
SEV_CRIT = "#d75f5f"  # near the limit (>= 90%)
TRACK = "#3a3a3a"  # unfilled bar track

WARN_PCT = 70.0
CRIT_PCT = 90.0


def severity_color(pct: float | None) -> str:
    if pct is None:
        return MUTED
    if pct >= CRIT_PCT:
        return SEV_CRIT
    if pct >= WARN_PCT:
        return SEV_WARN
    return SEV_OK


CODEX_AUTH_DARK = Theme(
    name="codex-auth-dark",
    primary=ACCENT,
    secondary=MUTED,
    accent=ACCENT,
    foreground=FOREGROUND,
    background=BACKGROUND,
    surface=SURFACE,
    panel=PANEL,
    success=SEV_OK,
    warning=SEV_WARN,
    error=SEV_CRIT,
    dark=True,
    variables={
        "footer-key-foreground": ACCENT,
        "block-cursor-background": PANEL,
        "block-cursor-foreground": FOREGROUND,
        "block-cursor-text-style": "none",
    },
)
