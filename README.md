# Codex Rolling Auth

Small shell wrapper for switching Codex to the best saved ChatGPT auth profile before a session starts.

It keeps `auth.json` pointed at the best available profile before a session starts. The optional `codex` shim only does a cached auth selection and then execs the real Codex binary, so normal Codex launches do not create nested runners, live log monitors, or extra MCP/app-server sidecars.

![Codex rolling auth selector](assets/usage-selector.png)

![Codex rolling auth selector scroll](assets/usage-selector.gif)

## Install

```bash
git clone https://github.com/editnori/codex-rolling-auth.git
cd codex-rolling-auth
./install.sh --wrap-codex
```

That installs:

- `codex-auth`, the profile manager and rolling runner
- `codex`, an optional shim that runs `codex-auth auto --quiet --no-background` and then starts the real Codex binary

If you only want the manager and not the `codex` shim:

```bash
./install.sh
```

## Usage

Save the current login as a profile:

```bash
codex-auth add Layth08 --current
```

Open the usage selector:

```bash
codex-auth usage --refresh --select
```

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

Terminate only the direct MCP sidecars under legacy `--yolo` Codex processes:

```bash
codex-auth doctor --kill-sidecars --yes
```

## Notes

- Profiles live under `$CODEX_HOME/auth-profiles` by default.
- The live auth file stays at `$CODEX_HOME/auth.json`.
- Set `CODEX_AUTH_CODEX_BIN=/path/to/codex` if the wrapper cannot find your real Codex binary.
- Set `CODEX_AUTH_AUTO=0` to bypass automatic profile selection for one command.
- `codex-auth run` is explicit opt-in. It can monitor a bounded session log to retry after usage-limit errors, but the normal `codex` shim does not use it.
- Set `CODEX_AUTH_ROLL_WATCH=1` to enable in-session periodic profile checks for `codex-auth run`; it is off by default to avoid background sidecar churn.
- Set `CODEX_AUTH_ROLL_LIVE_MONITOR=0` to disable live log monitoring for `codex-auth run`.
- Set `CODEX_AUTH_REFRESH_JOBS` to tune concurrent usage refreshes. The default is 2 and `CODEX_AUTH_REFRESH_JOBS_MAX` caps it at 4 unless you explicitly change the cap.
- `codex-auth doctor --kill-sidecars --yes` does not kill the Codex TUI processes; it only terminates direct MCP sidecars under legacy `--yolo` Codex roots.
- Set `CODEX_AUTH_USAGE_HEADER=1` or `CODEX_AUTH_USAGE_STATUS=1` if you want the full table header or status column back.
- Set `CODEX_AUTH_SELECTOR_CENTER=1` if you want the selector vertically centered in the terminal.
- Selector bars default to background-color lanes with thin horizontal row borders. Set `CODEX_AUTH_SELECTOR_BAR_STYLE=glyph` if your terminal does not render those cleanly.

## Test

```bash
tests/run.sh
```

## Regenerate Assets

```bash
node scripts/generate-assets.mjs
```
