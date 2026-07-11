"""Textual monitor and auto-switch view for codex-rolling-auth.

This package ports the *architecture* of claude-swap's TUI (paced snapshot
source, UI-agnostic threshold engine with typed events, passive watch screen,
confirm-to-go-live auto view) onto Codex's native profile/auth-state format. It
owns no credential logic: the shell CLI (`codex-auth`) keeps every sensitive
write, and this package reads structured state and shells out for refresh,
switching, profile capture, and confirmed earned-reset redemption.
"""

__version__ = "0.1.0"
