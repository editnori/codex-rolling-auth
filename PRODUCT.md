# Product

## Register

product

## Users

Codex CLI users who keep several saved ChatGPT auth profiles and need to see quota, choose an account, or leave automatic rotation running from a terminal. The primary user is already in an active coding workflow and needs the auth tool to stay understandable without becoming another process tree to babysit.

## Product Purpose

Codex Rolling Auth keeps the live Codex auth file on a usable saved profile. Success means one persistent screen shows current quota and freshness, manual switching is deliberate, and live automatic switching can run with an inspectable reason and no stale-cache guesswork.

## Brand Personality

Quiet, direct, trustworthy. The interaction reference is `claude-swap`: low chrome, dense readable usage rows, literal state labels, and keyboard behavior that disappears into the task.

## Anti-references

Do not recreate the one-shot `fzf` selector as a full-screen app. Avoid decorative terminal effects, nested panels, ambiguous color-only status, surprise credential changes, generic dashboard copy, and controls whose live or dry-run state is unclear.

## Design Principles

1. Show the actual state first: active profile, quota, automatic reset time, earned reset count, data age, and reload readiness.
2. Make safety visible: passive watch, dry-run auto, and live auto must look and behave differently.
3. Keep one source of truth: the TUI renders structured snapshots and typed engine decisions rather than duplicating policy.
4. Explain every switch: show the chosen profile, the comparison, and the reason in plain language.
5. Stay terminal-native: keyboard-first, compact, stable at narrow widths, and useful without animation.
6. Treat earned resets as scarce: refresh before offering one, default confirmation to Cancel, never combine redemption with a hidden profile switch, and preserve idempotency across retries.

## Accessibility & Inclusion

Every action is available from the keyboard. Selection, active state, errors, stale data, and live mode use text or symbols in addition to color. Focus is explicit only when selection is armed. Layout must remain readable in narrow terminals, and state changes must not depend on decorative motion.
