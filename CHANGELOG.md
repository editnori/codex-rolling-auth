# Changelog

## 0.1.1 - 2026-07-10

- Added `codex-auth reauth <name>` and a clickable, keyboard-accessible TUI sign-in flow.
- Kept the active profile unchanged while replacing only the selected saved login; active-target repairs retain the same profile name.
- Rejected wrong-account logins and concurrent profile edits, and stopped stale credential errors from showing another false sign-in prompt.
- Updated the synthetic screenshots, GIF, and video to show the Cancel-default sign-in confirmation.

## 0.1.0 - 2026-07-10

- Added the persistent Textual watch and autoswitch UI.
- Added safe capture of the current Codex login as a named profile.
- Added per-profile earned reset counts and confirmed reset redemption.
- Added generation-bound in-session auth reload support for patched Codex.
- Added automatic patch rebuilds after official curl-installed Codex updates.
- Added token-rotation lineage checks, atomic profile writes, and idempotent reset retries.
- Fixed auto mode treating an invalid or slow unrelated profile as a failed full-pool refresh.
- Added deterministic synthetic screenshots, GIF/video demos, and Linux CI.
