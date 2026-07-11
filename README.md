# Codex Rolling Auth

Small shell wrapper for switching Codex to the best saved ChatGPT auth profile before or during a session.

It keeps `auth.json` pointed at the best available profile before a session starts. The optional `codex` shim only does a cached auth selection and then execs the real Codex binary, so normal Codex launches do not create nested runners, live log monitors, or extra MCP/app-server sidecars.

[![CI](https://github.com/editnori/codex-rolling-auth/actions/workflows/ci.yml/badge.svg)](https://github.com/editnori/codex-rolling-auth/actions/workflows/ci.yml)

![Codex Auth watch screen with synthetic work and backup profiles](assets/codex-auth-watch.png)

_Synthetic demo data. No live credentials or account identifiers._

<details>
<summary>Watch the keyboard flow</summary>

![Codex Auth TUI demo showing profile switching and earned reset confirmation](assets/codex-auth-demo.gif)

</details>

| Dry-run autoswitch | Earned reset confirmation |
| --- | --- |
| ![Dry-run autoswitch screen](assets/codex-auth-auto.png) | ![Earned reset confirmation](assets/codex-auth-reset.png) |

All captures use the real Textual app with an in-memory synthetic backend.

## Requirements

- Linux or WSL with Bash, `jq`, `flock`, Git, and the official Codex CLI.
- [`uv`](https://docs.astral.sh/uv/) for the isolated Textual environment.
- `crontab` is optional; without it, run `codex-auth maintain` after a direct curl update.
- Building the patched Codex generation also needs a Rust/Cargo toolchain and normal native build dependencies.

## Install

If Codex came from the official curl installer, install or update Codex first. That installer owns the visible `~/.local/bin/codex` link. `./install.sh --wrap-codex` installs a one-minute maintenance job that restores the rolling-auth shim after a later curl update and queues the matching patch build.

```bash
curl -fsSL https://chatgpt.com/codex/install.sh | sh
```

```bash
git clone https://github.com/editnori/codex-rolling-auth.git
cd codex-rolling-auth
./install.sh --wrap-codex
```

The wrapper resolves the native binary through `$CODEX_HOME/packages/standalone/current/bin/codex` (and the legacy `current/codex` layout), so it follows the curl installer's current release instead of falling back to an older Bun/npm copy.

That installs:

- `codex-auth`, the profile manager and rolling runner
- `codex-auth-tui`, the full-screen watcher in a private project `.venv`
- `codex`, an optional shim that runs `codex-auth auto --quiet --no-background` and then starts the real Codex binary
- patched-Codex selection: when a matching generation exists, the shim uses it with in-process rolling auth enabled; when Codex updates, the shim immediately runs stock Codex and starts one detached patch build
- a marked, idempotent cron entry that runs `codex-auth maintain --quiet` once per minute without replacing existing cron jobs

The installer uses `uv` with the platform's native TLS store to create the TUI environment under `PREFIX/lib/codex-auth/tui/.venv`. It does not install Python packages globally. Packaging and isolated tests can copy the project without resolving dependencies by setting `CODEX_AUTH_TUI_SKIP_BOOTSTRAP=1`; normal installs should leave bootstrap enabled.

If you only want the manager and not the `codex` shim:

```bash
./install.sh
```

## Usage

Open the persistent account monitor without changing auth:

```bash
codex-auth watch
```

Run the autoswitch policy in dry-run mode. It refreshes and shows decisions but does not switch accounts:

```bash
codex-auth watch --auto
```

Allow the watcher to apply decisions through a generation-bound compare-and-switch transaction:

```bash
codex-auth watch --auto --live
```

`codex-auth tui` is an alias for `codex-auth watch`. `--threshold 0` means proactively prefer any strictly better ready account. In that mode cooldown is the anti-flap guard; hysteresis applies when the threshold is above zero.

Watcher keys:

- `s` arms or disarms manual selection.
- `n` saves the current Codex auth as a named profile.
- `u` checks and uses an earned rate-limit reset for a selected profile.
- Arrow keys or `j`/`k` move between accounts.
- `Enter` confirms an armed switch and keeps the watcher open.
- `Esc` disarms first, then goes back or quits.
- `a` opens the autoswitch view.
- `l` toggles LIVE; entering live asks for confirmation, while returning to dry-run is immediate.
- `r` forces a refresh.
- `q` goes back or quits.

Live mode changes `auth.json`, so new Codex processes use the selected account immediately. A stock Codex process that is already running does not hot-reload that file. In-session switching requires a patched Codex build that matches the installed native binary:

```bash
codex-auth patch-codex
codex-auth patch-codex --status
```

The automatic builder requires the exact `rust-v<installed-version>` source tag. It never stamps `origin/main` as a release match. The patch reloads a deliberate account change before Codex can refresh the old account's token, including the unauthorized-recovery path that normally reports that you logged out or signed in to another account. If the installed Codex release changes or a build fails, the shim stays on stock Codex until that exact generation is ready.

Save the current login as a profile:

```bash
codex-auth add work --current
```

From `codex-auth tui`, press `n`, enter the profile name, and press `Enter`.
Replacing an existing profile requires confirmation.

### Earned resets

When Codex reports an earned reset bank, each profile card shows its authoritative remaining count separately from the automatic `5h` and weekly reset countdowns. Press `u`, select a ChatGPT profile, and confirm. The TUI refreshes that profile before confirmation, uses one reset through Codex app-server, then refreshes the usage bars and remaining count. It does **not** switch the active profile.

The equivalent explicit CLI command requires confirmation:

```bash
codex-auth reset work --yes
```

Ambiguous transport retries reuse the same idempotency key, so retrying cannot spend a second reset. `alreadyRedeemed` is treated as success; `nothingToReset` and `noCredit` do not pretend a reset happened. See the official [Codex app-server earned reset contract](https://learn.chatgpt.com/docs/app-server#8-earned-rate-limit-resets-chatgpt).

Open the usage selector:

```bash
codex-auth usage --refresh --select
```

![Inline usage selector with synthetic profiles](assets/usage-selector.png)

Run a rolling Codex session explicitly:

```bash
codex-auth run -- resume --last
```

Resume a specific session with rolling auth:

```bash
codex-auth run -- resume 019e1af9-d95b-7f11-b1f0-aae08a7c4f1d
```

If you installed the shim with `--wrap-codex`, normal Codex commands auto-select a cached best profile first:

```bash
codex resume 019e1af9-d95b-7f11-b1f0-aae08a7c4f1d
```

Check for old nested Codex launch trees and MCP sidecars:

```bash
codex-auth doctor
```

Check patched Codex status:

```bash
codex-auth patch-codex --status
```

Build the patched Codex binary in the foreground:

```bash
codex-auth patch-codex
```

Reconcile the curl-installed command and queue a missing generation manually:

```bash
codex-auth maintain
```

Terminate only the direct MCP sidecars under legacy `--yolo` Codex processes:

```bash
codex-auth doctor --kill-sidecars --yes
```

## Notes

- Profiles live under `$CODEX_HOME/auth-profiles` by default.
- The live auth file stays at `$CODEX_HOME/auth.json`.
- Saved profiles contain live credentials. Files are written with restrictive permissions, but they must never be committed, uploaded, pasted into issues, or included in captures.
- `$CODEX_HOME/active-profile.json` records the selected profile using hashed account identity and a credential fingerprint. When Codex rotates that account's refresh token, the wrapper compare-and-swaps the newer auth back into the same saved profile; a real account change or concurrent edit is never overwritten.
- Usage probes run in temporary Codex homes. If a probe rotates a refresh token, the rotated auth is persisted before the temporary home is removed and is attached to usage state only after the profile lineage check succeeds.
- `bin/codex-auth` is a thin entrypoint. Shell runtime code lives in `lib/codex-auth/*.sh`; the persistent watcher lives in the isolated project under `lib/codex-auth/tui` after installation.
- Set `CODEX_AUTH_CODEX_BIN=/path/to/codex` if the wrapper cannot find your real Codex binary.
- Set `CODEX_AUTH_AUTO=0` to bypass automatic profile selection for one command.
- `codex-auth run` is explicit opt-in. It can monitor a bounded session log to retry after usage-limit errors, but the normal `codex` shim does not use it.
- Set `CODEX_AUTH_ROLL_WATCH=1` to enable in-session periodic profile checks for `codex-auth run`; it is off by default to avoid background sidecar churn.
- Set `CODEX_AUTH_ROLL_LIVE_MONITOR=0` to disable live log monitoring for `codex-auth run`.
- Set `CODEX_AUTH_PATCH_AUTO=0` to stop the `codex` shim from using or building patched Codex.
- Background rebuilds are on by default. Set `CODEX_AUTH_PATCH_BUILD_AUTO=0` to use an existing matching patch without building a missing one.
- Patched binaries live under `$CODEX_HOME/patched-codex/generations/<stock-key>/codex`. Each marker and binary are published together as one immutable directory, and the shim never selects a stale generation.
- The builder hashes a stock binary once in the detached worker, reuses a shared Cargo target, strips release debug data, and retains two patched/source generations by default. Set `CODEX_AUTH_PATCH_KEEP_GENERATIONS` to change retention.
- Build failures back off for 15 minutes by default while stock Codex remains usable. Set `CODEX_AUTH_PATCH_RETRY_SECS` to change the retry window.
- The maintenance cron waits for the official standalone installer lock, restores the shim only when the curl installer owns the visible command, and queues the new generation. Set `CODEX_AUTH_INSTALL_MAINTAIN_CRON=0` during installation to opt out.
- Patched builds are stamped as the installed Codex version plus `+local`, so they do not appear older to Codex's update check.
- Set `CODEX_AUTH_REFRESH_JOBS` to tune concurrent usage refreshes. The default is 4 and `CODEX_AUTH_REFRESH_JOBS_MAX` caps it at 4 unless you explicitly change the cap; `usage --sync` temporarily raises the default up to the profile count, capped at 12.
- `codex-auth doctor --kill-sidecars --yes` does not kill the Codex TUI processes; it only terminates direct MCP sidecars under legacy `--yolo` Codex roots.
- Set `CODEX_AUTH_USAGE_HEADER=1` or `CODEX_AUTH_USAGE_STATUS=1` if you want the full table header or status column back.
- The selector defaults to the inline fzf scrolling TUI when fzf is available. It uses adaptive height instead of taking over the whole terminal. Set `CODEX_AUTH_NO_FZF=1` or `CODEX_AUTH_SELECTOR=numbered` for the plain numbered fallback.
- `codex-auth usage --sync` refreshes usage first, then opens the TUI. `codex-auth usage --refresh --select` opens the TUI from cache right away and refreshes in the background.
- Set `CODEX_AUTH_SELECTOR_CENTER=1` if you want the fallback selector vertically centered in the terminal.
- Selector bars default to background-color lanes with thin horizontal row borders. Set `CODEX_AUTH_SELECTOR_BAR_STYLE=glyph` if your terminal does not render those cleanly.

## Remove the wrapper

Remove the marked maintenance block first so it cannot restore the shim, reinstall stock Codex, then remove the manager files:

```bash
crontab -l 2>/dev/null \
  | awk '$0 == "# BEGIN codex-auth maintain" {skip=1; next} $0 == "# END codex-auth maintain" {skip=0; next} !skip' \
  | crontab -
curl -fsSL https://chatgpt.com/codex/install.sh | sh
rm -f ~/.local/bin/codex-auth ~/.local/bin/codex-auth-tui ~/.local/bin/codex-real
rm -rf ~/.local/lib/codex-auth
```

This intentionally leaves `$CODEX_HOME/auth-profiles` and other account state in place.

## Test

```bash
tests/run.sh
```

## Regenerate Assets

Media generation is development-only and uses synthetic in-memory profiles. It requires Fontconfig, FFmpeg, ImageMagick, and the locked Playwright/Pillow dependencies:

```bash
uv sync --project tui --dev --locked
uv run --project tui playwright install chromium
uv run --project tui python scripts/capture_tui.py
uv run --project tui python scripts/capture_tui.py --check
node scripts/generate-assets.mjs
```
