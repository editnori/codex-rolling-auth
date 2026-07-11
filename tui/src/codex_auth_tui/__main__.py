"""Allow ``python -m codex_auth_tui`` to launch the TUI."""

from codex_auth_tui.cli import main

if __name__ == "__main__":
    raise SystemExit(main())
