# codex-auth-tui

Textual front end for [codex-rolling-auth](../README.md). It renders structured
snapshots read from `CODEX_HOME/auth-state.json` (plus profile fingerprints) and
typed auto-switch engine events; it never parses the shell CLI's rendered
table/fzf output. All sensitive writes stay in the shell CLI — this package only
*reads* state and *calls* `codex-auth refresh`, the guarded shell switch
transaction, `codex-auth add <name> --current`, or the confirmed earned-reset
command as short-lived subprocesses, so the mutation/refresh locks stay scoped
to each call.

Usually launched through the shell entrypoint:

```bash
codex-auth watch              # passive full-screen account monitor
codex-auth watch --auto       # open the auto-switch view (dry-run)
codex-auth watch --auto --live  # start the auto-switch engine live
```

In the watcher, press `n` to capture the current `auth.json` as a named profile.
The shell command still owns validation, locking, and the atomic credential copy.

Press `u` to select a ChatGPT profile, fresh-check its earned reset count, and
open a Cancel-default confirmation. A confirmed redemption uses Codex app-server
without switching the active profile, then publishes the refreshed count and
usage bars.

Run the tests with `uv run --project tui pytest`.
