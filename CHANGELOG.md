# Changelog

## 0.2.0 - 2026-07-11

- Added `claude-gpt`, an opt-in Claude Code harness backed by saved ChatGPT/Codex subscription auth.
- Kept refresh tokens under `codex-auth` ownership by giving each local proxy an ephemeral access-only lease pinned to one account identity.
- Kept proxy routing child-only, forwarded Claude Code arguments unchanged, and avoided switching the active Codex profile or rewriting cswap configuration.
- Mapped Claude Code's Opus, Sonnet, and Haiku tiers to the `gpt-5.6-sol`, `gpt-5.6-terra`, and `gpt-5.6-luna` lanes, each overridable by a launcher flag or `CLAUDE_GPT_*` variable.
- Added clear GPT labels and `effort,xhigh_effort,max_effort` capability declarations to every lane, including one custom `/model` option, `GPT-5.6 Sol Ultra Fast` (`gpt-5.6-sol-fast`); `claude-gpt --effort` sets only the starting level, `/effort` stays dynamic, and the launcher never pins `CCP_CODEX_EFFORT`.
- Added `claude-gpt --effort ultracode` and its `ultra` alias for Claude Code's xhigh-plus-dynamic-workflow mode, and documented the pinned proxy's current `max`-to-`xhigh` limitation separately from Ultra Fast service tier.

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
