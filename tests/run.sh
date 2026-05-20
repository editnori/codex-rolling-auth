#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CODEX_AUTH_RUNNER CODEX_AUTH_CODEX_BIN

fail() {
  printf 'not ok - %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local file="$2"
  grep -Fq -- "$needle" "$file" || fail "missing '$needle' in $file"
}

assert_not_contains() {
  local needle="$1"
  local file="$2"
  if grep -Fq -- "$needle" "$file"; then
    fail "unexpected '$needle' in $file"
  fi
}

write_fake_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  printf "codex-cli 9.8.7\n"' \
    '  exit 0' \
    'fi' \
    'printf "real:%s\n" "$*" >> "$CODEX_TEST_LOG"' \
    'if [[ "${1:-}" == "app-server" ]]; then' \
    '  printf "app-server\n" >> "$CODEX_TEST_LOG"' \
    'fi' > "$path"
  chmod 0755 "$path"
}

write_fake_patched_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    '  printf "codex-cli 9.8.7+local\n"' \
    '  exit 0' \
    'fi' \
    'printf "patched:%s rolling=%s\n" "$*" "${CODEX_AUTH_ROLLING:-}" >> "$CODEX_TEST_LOG"' > "$path"
  chmod 0755 "$path"
}

write_fake_auth() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "auth:%s\n" "$*" >> "$CODEX_TEST_LOG"' \
    'if [[ "${1:-}" == "run" ]]; then' \
    '  exit 55' \
    'fi' > "$path"
  chmod 0755 "$path"
}

write_retry_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'count_file="$CODEX_TEST_COUNT"' \
    'count=0' \
    '[[ -f "$count_file" ]] && count="$(cat "$count_file")"' \
    'count=$((count + 1))' \
    'printf "%s" "$count" > "$count_file"' \
    'printf "real:%s\n" "$*" >> "$CODEX_TEST_LOG"' \
    'if (( count == 1 )); then' \
    '  printf "usage limit reached\n" >&2' \
    '  exit 42' \
    'fi' > "$path"
  chmod 0755 "$path"
}

test_shim_auto_execs_real_codex() {
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/bin/codex-auth"

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" resume abc

  assert_contains 'auth:auto --quiet --no-background' "$log"
  assert_not_contains 'auth:run' "$log"
  assert_not_contains 'auth:patch-codex --background --quiet' "$log"
  assert_contains 'real:--yolo resume abc' "$log"
}

test_shim_background_build_is_opt_in() {
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/bin/codex-auth"

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" CODEX_AUTH_PATCH_BUILD_AUTO=1 "$REPO_ROOT/bin/codex" resume abc

  assert_contains 'auth:patch-codex --background --quiet' "$log"
  assert_contains 'real:--yolo resume abc' "$log"
}

test_shim_bypasses_auto_for_app_server() {
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/bin/codex-auth"

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" app-server --listen stdio://

  assert_not_contains 'auth:auto' "$log"
  assert_contains 'real:app-server --listen stdio://' "$log"
  assert_contains 'app-server' "$log"
}

test_shim_honors_auto_bypass() {
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/bin/codex-auth"

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" resume abc

  assert_not_contains 'auth:auto' "$log"
  assert_contains 'real:--yolo resume abc' "$log"
}

test_shim_uses_matching_patched_codex() {
  local tmp home log key marker patched_bin
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  marker="$home/patched-codex/current.env"
  patched_bin="$home/patched-codex/bin/codex"
  write_fake_codex "$tmp/real-codex"
  write_fake_patched_codex "$patched_bin"
  mkdir -p "$(dirname "$marker")"

  key="$(CODEX_HOME="$home" CODEX_AUTH_STOCK_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  printf 'patch_version=1\nstock_key=%s\n' "$key" > "$marker"

  PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" resume abc

  assert_contains 'patched:--yolo resume abc rolling=1' "$log"
  assert_not_contains 'real:--yolo resume abc' "$log"
}

test_patch_codex_keys_forwarding_wrapper_to_target() {
  local tmp home target wrapper target_key wrapper_key
  tmp="$(mktemp -d)"
  home="$tmp/home"
  target="$tmp/target/codex"
  wrapper="$tmp/bin/codex-real"
  write_fake_codex "$target"
  mkdir -p "$(dirname "$wrapper")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    "exec \"$target\" \"\$@\"" > "$wrapper"
  chmod 0755 "$wrapper"

  target_key="$(CODEX_HOME="$home" CODEX_AUTH_STOCK_CODEX_BIN="$target" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  wrapper_key="$(CODEX_HOME="$home" CODEX_AUTH_STOCK_CODEX_BIN="$wrapper" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"

  [[ "$wrapper_key" == "$target_key" ]] || fail "forwarding wrapper produced a different patch key"
}

test_install_promotes_existing_codex_to_real() {
  local tmp prefix log
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  log="$tmp/calls.log"
  write_fake_codex "$prefix/bin/codex"

  PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not installed"

  CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 "$prefix/bin/codex" ping
  assert_contains 'real:--yolo ping' "$log"
}

test_install_recovers_real_from_old_backup() {
  local tmp prefix log
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  log="$tmp/calls.log"
  mkdir -p "$prefix/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'CODEX_AUTH_SHIM=1' \
    'exec codex-auth run -- "$@"' > "$prefix/bin/codex"
  chmod 0755 "$prefix/bin/codex"
  write_fake_codex "$prefix/bin/codex.backup.202605180001"

  PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not recovered from backup"

  CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 "$prefix/bin/codex" ping
  assert_contains 'real:--yolo ping' "$log"
  assert_not_contains 'codex-auth run' "$prefix/bin/codex-real"
}

test_install_recovers_real_from_path() {
  local tmp prefix realbin log
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  realbin="$tmp/realbin"
  log="$tmp/calls.log"
  mkdir -p "$prefix/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'CODEX_AUTH_SHIM=1' \
    'exec codex-auth run -- "$@"' > "$prefix/bin/codex"
  chmod 0755 "$prefix/bin/codex"
  write_fake_codex "$realbin/codex"

  HOME="$tmp/home" PATH="$realbin:/usr/bin:/bin" PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not recovered from PATH"

  CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 "$prefix/bin/codex" ping
  assert_contains 'real:--yolo ping' "$log"
}

test_install_recovers_real_from_home_bun() {
  local tmp prefix fake_home log
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  fake_home="$tmp/home"
  log="$tmp/calls.log"
  mkdir -p "$prefix/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'CODEX_AUTH_SHIM=1' \
    'exec codex-auth run -- "$@"' > "$prefix/bin/codex"
  chmod 0755 "$prefix/bin/codex"
  write_fake_codex "$fake_home/.bun/bin/codex-real"

  HOME="$fake_home" PATH="/usr/bin:/bin" PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not recovered from HOME bun"

  CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 "$prefix/bin/codex" ping
  assert_contains 'real:--yolo ping' "$log"
}

test_install_installs_codex_auth_libs() {
  local tmp prefix home output
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  home="$tmp/home"
  output="$tmp/paths.txt"

  PREFIX="$prefix" "$REPO_ROOT/install.sh" >/dev/null
  [[ -r "$prefix/lib/codex-auth/core.sh" ]] || fail "core lib was not installed"
  [[ -r "$prefix/lib/codex-auth/usage.sh" ]] || fail "usage lib was not installed"

  TERM=dumb CODEX_HOME="$home" "$prefix/bin/codex-auth" paths >"$output"
  assert_contains 'auth' "$output"
  assert_contains 'profiles' "$output"
}

test_run_uses_cached_auto_without_app_server_refresh() {
  local tmp home log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  mkdir -p "$home/auth-profiles"
  printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$home/auth-profiles/a.json"

  CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex-auth" run -- smoke >/dev/null

  assert_contains 'real:smoke' "$log"
  assert_not_contains 'app-server' "$log"
}

test_run_retries_usage_limit_without_leftover_logs() {
  local tmp home log count
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  count="$tmp/count"
  write_retry_codex "$tmp/retry-codex"

  CODEX_TEST_LOG="$log" CODEX_TEST_COUNT="$count" CODEX_HOME="$home" CODEX_AUTH_RUN_AUTO=0 CODEX_AUTH_CODEX_BIN="$tmp/retry-codex" "$REPO_ROOT/bin/codex-auth" run -- prompt >/dev/null 2>"$tmp/stderr"

  assert_contains 'real:prompt' "$log"
  assert_contains 'real:resume --last' "$log"
  assert_contains 'usage limit reached' "$tmp/stderr"
  if find "$home/.tmp" -type f -name 'codex-run.*.log' 2>/dev/null | grep -q .; then
    fail "leftover codex run logs after retry"
  fi
}

test_recover_does_not_force_yolo() {
  local tmp home log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"

  if ! command -v script >/dev/null 2>&1; then
    printf 'skip - test_recover_does_not_force_yolo\n'
    return 0
  fi

  CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" script -qec "$REPO_ROOT/bin/codex-auth recover session-123" /dev/null >/dev/null

  assert_contains 'real:resume session-123' "$log"
  assert_not_contains '--yolo' "$log"
}

test_dumb_selector_renders_without_fzf_prompt() {
  local tmp home output
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  mkdir -p "$home/auth-profiles"
  printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$home/auth-profiles/a.json"

  if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_dumb_selector_renders_without_fzf_prompt\n'
    return 0
  fi

  TERM=dumb CODEX_HOME="$home" timeout 2 script -qec "$REPO_ROOT/bin/codex-auth usage --cached --select" /dev/null >"$output"

  assert_contains 'Codex profiles' "$output"
  assert_not_contains 'filter' "$output"
}

test_selector_uses_fzf_by_default_when_available() {
  local tmp home output fzf_input fzf_args
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  fzf_input="$tmp/fzf-input.txt"
  fzf_args="$tmp/fzf-args.txt"
  mkdir -p "$home/auth-profiles" "$tmp/bin"
  printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$home/auth-profiles/a.json"
  cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_TEST_FZF_ARGS"
cat > "$CODEX_TEST_FZF_INPUT"
grep -m1 '^action' "$CODEX_TEST_FZF_INPUT"
EOF
  chmod 0755 "$tmp/bin/fzf"

  if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_selector_uses_fzf_by_default_when_available\n'
    return 0
  fi

  PATH="$tmp/bin:$PATH" CODEX_TEST_FZF_INPUT="$fzf_input" CODEX_TEST_FZF_ARGS="$fzf_args" TERM=xterm CODEX_HOME="$home" timeout 2 script -qec "$REPO_ROOT/bin/codex-auth usage --cached --select" /dev/null >"$output"

  assert_contains '--with-nth=4..' "$fzf_args"
  assert_contains '--height=~' "$fzf_args"
  assert_not_contains '--height=100%' "$fzf_args"
  assert_contains $'action\tswitch\ta' "$fzf_input"
  assert_not_contains '1. ' "$fzf_input"
  assert_contains 'active a' "$output"
}

test_refresh_select_uses_cached_selector_without_blocking() {
  local tmp home output fzf_input fzf_args log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  fzf_input="$tmp/fzf-input.txt"
  fzf_args="$tmp/fzf-args.txt"
  log="$tmp/calls.log"
  mkdir -p "$home/auth-profiles" "$tmp/bin"
  printf '%s\n' '{"OPENAI_API_KEY":"a"}' > "$home/auth-profiles/a.json"
  write_fake_codex "$tmp/real-codex"
  cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_TEST_FZF_ARGS"
cat > "$CODEX_TEST_FZF_INPUT"
grep -m1 '^action' "$CODEX_TEST_FZF_INPUT"
EOF
  chmod 0755 "$tmp/bin/fzf"

  if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_refresh_select_uses_cached_selector_without_blocking\n'
    return 0
  fi

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_TEST_FZF_INPUT="$fzf_input" CODEX_TEST_FZF_ARGS="$fzf_args" TERM=xterm CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" timeout 2 script -qec "$REPO_ROOT/bin/codex-auth usage --refresh --select" /dev/null >"$output"

  assert_contains '--height=~' "$fzf_args"
  assert_not_contains '--height=100%' "$fzf_args"
  assert_contains $'action\tswitch\ta' "$fzf_input"
  assert_contains 'active a' "$output"
}

test_rolling_hook_keeps_inline_auto_cached_by_default() {
  assert_contains 'CODEX_AUTH_ROLLING_TTL_ENV_VAR' "$REPO_ROOT/lib/codex-auth/patch.sh"
  assert_not_contains 'DEFAULT_ROLLING_AUTH_TTL_SECS' "$REPO_ROOT/lib/codex-auth/patch.sh"
}

test_doctor_reports_legacy_sidecars() {
  local tmp psfile output
  tmp="$(mktemp -d)"
  psfile="$tmp/ps.txt"
  output="$tmp/out.txt"
  cat > "$psfile" <<'EOF'
685 597 685 597 pts/0 Sl+ 01:00 node /home/test/.bun/bin/codex --yolo
692 685 685 597 pts/0 Sl+ 01:00 /home/test/.bun/install/global/node_modules/@openai/codex/node_modules/@openai/codex-linux-x64/vendor/x86_64-unknown-linux-musl/codex/codex --yolo
700 692 700 597 pts/0 Sl 00:59 node /home/test/plugins/gemini-ui-sidecar/scripts/gemini_ui_mcp.mjs
701 692 701 597 pts/0 Sl 00:59 bun /home/test/Desktop/webex-mcp/server.mjs --env-file x
999 1 999 999 ? Sl 00:01 node unrelated.js
EOF

  CODEX_AUTH_DOCTOR_PS_FILE="$psfile" "$REPO_ROOT/bin/codex-auth" doctor > "$output"

  assert_contains 'legacy codex processes: 2' "$output"
  assert_contains 'direct sidecars under legacy codex: 2' "$output"
  assert_contains 'run: codex-auth doctor --kill-sidecars --yes' "$output"
}

test_doctor_refuses_kill_without_yes() {
  local tmp psfile output
  tmp="$(mktemp -d)"
  psfile="$tmp/ps.txt"
  output="$tmp/out.txt"
  printf '%s\n' '1 0 1 1 ? S 00:01 node /home/test/.bun/bin/codex --yolo' > "$psfile"

  if CODEX_AUTH_DOCTOR_PS_FILE="$psfile" "$REPO_ROOT/bin/codex-auth" doctor --kill-sidecars > "$output" 2>&1; then
    fail "doctor allowed kill-sidecars without --yes"
  fi

  assert_contains 'refusing to kill sidecars without --yes' "$output"
}

main() {
  local test_name
  for test_name in \
    test_shim_auto_execs_real_codex \
    test_shim_background_build_is_opt_in \
    test_shim_bypasses_auto_for_app_server \
    test_shim_honors_auto_bypass \
    test_shim_uses_matching_patched_codex \
    test_patch_codex_keys_forwarding_wrapper_to_target \
    test_install_promotes_existing_codex_to_real \
    test_install_recovers_real_from_old_backup \
    test_install_recovers_real_from_path \
    test_install_recovers_real_from_home_bun \
    test_install_installs_codex_auth_libs \
    test_run_uses_cached_auto_without_app_server_refresh \
    test_run_retries_usage_limit_without_leftover_logs \
    test_recover_does_not_force_yolo \
    test_dumb_selector_renders_without_fzf_prompt \
    test_selector_uses_fzf_by_default_when_available \
    test_refresh_select_uses_cached_selector_without_blocking \
    test_rolling_hook_keeps_inline_auto_cached_by_default \
    test_doctor_reports_legacy_sidecars \
    test_doctor_refuses_kill_without_yes
  do
    "$test_name"
    printf 'ok - %s\n' "$test_name"
  done
}

main "$@"
