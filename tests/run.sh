#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
unset CODEX_AUTH_RUNNER CODEX_AUTH_CODEX_BIN
export CODEX_AUTH_TUI_SKIP_BOOTSTRAP=1
export CODEX_AUTH_INSTALL_MAINTAIN_CRON=0

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

write_named_fake_codex() {
  local path="$1"
  local name="$2"
  local version="$3"
  mkdir -p "$(dirname "$path")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "${1:-}" == "--version" ]]; then' \
    "  printf '%s\\n' 'codex-cli $version'" \
    '  exit 0' \
    'fi' \
    "printf '%s:%s\\n' '$name' \"\$*\" >> \"\$CODEX_TEST_LOG\"" > "$path"
  chmod 0755 "$path"
}

write_rate_limit_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf "codex-cli 9.8.7\n"
  exit 0
fi
printf "real:%s\n" "$*" >> "$CODEX_TEST_LOG"
if [[ "${1:-}" == "app-server" ]]; then
  primary_used="${CODEX_TEST_PRIMARY_USED:-31}"
  secondary_used="${CODEX_TEST_SECONDARY_USED:-22}"
  reset_credits="${CODEX_TEST_RESET_CREDITS:-2}"
  reset_credits_after="${CODEX_TEST_RESET_CREDITS_AFTER:-1}"
  reset_outcome="${CODEX_TEST_RESET_OUTCOME:-reset}"
  rate_error="${CODEX_TEST_RATE_ERROR:-}"
  rate_sleep="${CODEX_TEST_RATE_SLEEP:-0}"
  now="$(date +%s)"
  primary_reset=$((now + 604800))
  secondary_reset=$((now + 18000))
  while IFS= read -r line; do
    printf 'rpc:%s\n' "$line" >> "$CODEX_TEST_LOG"
    if [[ "$line" == *'"id":1'* ]]; then
      printf '%s\n' '{"id":1,"result":{}}'
    elif [[ "$line" == *'"method":"account/rateLimitResetCredit/consume"'* ]]; then
      if [[ "${CODEX_TEST_RESET_NO_RESPONSE:-0}" == "1" ]]; then
        sleep "${CODEX_TEST_RESET_NO_RESPONSE_SLEEP:-2}"
        exit 0
      fi
      printf '{"id":2,"result":{"outcome":"%s"}}\n' "$reset_outcome"
    elif [[ "$line" == *'"method":"account/rateLimits/read"'* ]]; then
      [[ "$rate_sleep" == "0" ]] || sleep "$rate_sleep"
      response_id="$(jq -r '.id' <<<"$line")"
      if [[ -n "$rate_error" ]]; then
        jq -cn --argjson id "$response_id" --arg message "$rate_error" \
          '{id:$id,error:{code:-32000,message:$message}}'
        sleep "${CODEX_TEST_RESPONSE_HOLD:-0.05}"
        [[ "$response_id" == "2" ]] && exit 0
        continue
      fi
      response_credits="$reset_credits"
      [[ "$response_id" == "3" ]] && response_credits="$reset_credits_after"
      printf '{"id":%s,"result":{"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":%s,"windowDurationMins":10080,"resetsAt":%s},"secondary":{"usedPercent":%s,"windowDurationMins":300,"resetsAt":%s}}},"rateLimitResetCredits":{"availableCount":%s,"credits":null}}}\n' \
        "$response_id" "$primary_used" "$primary_reset" "$secondary_used" "$secondary_reset" "$response_credits"
      # Keep the coprocess pipes alive long enough for the parent reader to
      # consume the response before Bash reaps and unsets the managed FDs.
      sleep "${CODEX_TEST_RESPONSE_HOLD:-0.05}"
      [[ "$response_id" == "2" ]] && exit 0
    fi
  done
  exit 0
fi
EOF
  chmod 0755 "$path"
}

write_chatgpt_auth() {
  local path="$1"
  local refresh_token="$2"
  local access_token="$3"
  local account_id="${4:-acct-test}"
  local last_refresh="${5:-2026-07-10T00:00:00Z}"
  local id_payload id_token

  mkdir -p "$(dirname "$path")"
  id_payload="$(jq -cn --arg account "$account_id" --arg user "user-$account_id" \
    '{sub:$user,"https://api.openai.com/auth":{chatgpt_account_id:$account,chatgpt_user_id:$user}}' \
    | base64 -w0 | tr '+/' '-_' | tr -d '=')"
  id_token="eyJhbGciOiJub25lIn0.$id_payload."
  jq -cn \
    --arg refresh "$refresh_token" \
    --arg access "$access_token" \
    --arg account "$account_id" \
    --arg id_token "$id_token" \
    --arg last_refresh "$last_refresh" \
    '{auth_mode:"chatgpt",tokens:{refresh_token:$refresh,access_token:$access,account_id:$account,id_token:$id_token},last_refresh:$last_refresh}' \
    > "$path"
  chmod 0600 "$path"
}

write_rotating_rate_limit_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf "codex-cli 9.8.7\n"
  exit 0
fi
printf "real:%s\n" "$*" >> "$CODEX_TEST_LOG"
if [[ "${1:-}" == "app-server" ]]; then
  replace_auth() {
    local source="$1"
    local target="$2"
    local target_dir target_base tmp
    target_dir="$(dirname "$target")"
    target_base="$(basename "$target")"
    mkdir -p "$target_dir"
    tmp="$(mktemp "$target_dir/.${target_base}.test.XXXXXX")"
    cp "$source" "$tmp"
    chmod 0600 "$tmp"
    mv -f "$tmp" "$target"
  }

  now="$(date +%s)"
  primary_reset=$((now + 604800))
  secondary_reset=$((now + 18000))
  while IFS= read -r line; do
    if [[ "$line" == *'"id":1'* ]]; then
      printf '%s\n' '{"id":1,"result":{}}'
    elif [[ "$line" == *'"id":2'* ]]; then
      replace_auth "$CODEX_TEST_ROTATED_AUTH_FILE" "$CODEX_HOME/auth.json"
      if [[ -n "${CODEX_TEST_CONCURRENT_PROFILE_SOURCE:-}" && -n "${CODEX_TEST_CONCURRENT_PROFILE_TARGET:-}" ]]; then
        replace_auth "$CODEX_TEST_CONCURRENT_PROFILE_SOURCE" "$CODEX_TEST_CONCURRENT_PROFILE_TARGET"
      fi
      if [[ -n "${CODEX_TEST_CONCURRENT_LIVE_SOURCE:-}" && -n "${CODEX_TEST_CONCURRENT_LIVE_TARGET:-}" ]]; then
        replace_auth "$CODEX_TEST_CONCURRENT_LIVE_SOURCE" "$CODEX_TEST_CONCURRENT_LIVE_TARGET"
      fi
      if [[ "${CODEX_TEST_PROBE_FAIL:-0}" == "1" ]]; then
        exit 42
      fi
      printf '{"id":2,"result":{"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":%s},"secondary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":%s}}}}}\n' \
        "$primary_reset" "$secondary_reset"
      sleep "${CODEX_TEST_RESPONSE_HOLD:-0.05}"
      exit 0
    fi
  done
  exit 0
fi
EOF
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

write_updating_fake_codex() {
  local path="$1"
  mkdir -p "$(dirname "$path")"
  cat > "$path" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--version" ]]; then
  printf "codex-cli 9.8.7\n"
  exit 0
fi
printf "real:%s\n" "$*" >> "$CODEX_TEST_LOG"
if [[ "${1:-}" == "update" ]]; then
  printf '%s\n' '#!/usr/bin/env bash' 'printf "official replacement\n"' > "$CODEX_TEST_SHIM_PATH"
  chmod 0755 "$CODEX_TEST_SHIM_PATH"
fi
EOF
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
  assert_contains 'auth:patch-codex --print-bin --background --quiet' "$log"
  assert_contains 'real:--yolo resume abc' "$log"
}

test_shim_background_build_can_be_disabled() {
  local tmp log
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/bin/codex-auth"

  PATH="$tmp/bin:$PATH" CODEX_TEST_LOG="$log" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" CODEX_AUTH_PATCH_BUILD_AUTO=0 "$REPO_ROOT/bin/codex" resume abc

  assert_contains 'auth:patch-codex --print-bin --quiet' "$log"
  assert_not_contains 'auth:patch-codex --print-bin --background --quiet' "$log"
  assert_contains 'real:--yolo resume abc' "$log"
}

test_shim_update_restores_wrapper_and_starts_rebuild() {
  local tmp log shim
  tmp="$(mktemp -d)"
  log="$tmp/calls.log"
  shim="$tmp/bin/codex"
  mkdir -p "$tmp/bin"
  cp "$REPO_ROOT/bin/codex" "$shim"
  chmod 0755 "$shim"
  write_updating_fake_codex "$tmp/real-codex"
  write_fake_auth "$tmp/auth-bin/codex-auth"

  PATH="$tmp/auth-bin:$PATH" \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_SHIM_PATH="$shim" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$shim" update

  assert_contains 'real:update' "$log"
  assert_contains 'auth:patch-codex --print-bin --background --quiet' "$log"
  assert_contains 'CODEX_AUTH_SHIM=1' "$shim"
  assert_not_contains 'official replacement' "$shim"
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
  printf 'patch_version=2\nstock_key=%s\n' "$key" > "$marker"

  PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" resume abc
  PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex"
  PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" --yolo
  PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex" resume def --yolo

  assert_contains 'patched:--yolo resume abc rolling=1' "$log"
  assert_contains 'patched:--yolo rolling=1' "$log"
  assert_contains 'patched:resume def --yolo rolling=1' "$log"
  assert_not_contains 'patched:--yolo resume def --yolo' "$log"
  assert_not_contains 'real:--yolo resume abc' "$log"
}

test_patch_background_build_is_single_flight() {
  local tmp home log harness clone_count i
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/git.log"
  harness="$tmp/codex-auth-harness"
  write_fake_codex "$tmp/real-codex"
  mkdir -p "$tmp/bin"
  cat > "$tmp/bin/git" <<'EOF'
#!/usr/bin/env bash
printf 'git:%s\n' "$*" >> "$CODEX_TEST_GIT_LOG"
if [[ "${1:-}" == "clone" ]]; then
  sleep 1
fi
exit 42
EOF
  cat > "$tmp/bin/cargo" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat > "$harness" <<EOF
#!/usr/bin/env bash
set -euo pipefail
CODEX_HOME="\${CODEX_HOME:?}"
PROFILE_DIR="\$CODEX_HOME/auth-profiles"
BACKUP_DIR="\$CODEX_HOME/auth-backups"
CODEX_BIN="\${CODEX_AUTH_CODEX_BIN:-}"
CODEX_AUTH_SELF="\${BASH_SOURCE[0]}"
CODEX_AUTH_LIB_DIR="$REPO_ROOT/lib/codex-auth"
source "\$CODEX_AUTH_LIB_DIR/core.sh"
source "\$CODEX_AUTH_LIB_DIR/patch.sh"
[[ "\${1:-}" == "patch-codex" ]] && shift
cmd_patch_codex "\$@"
EOF
  chmod 0755 "$tmp/bin/git" "$tmp/bin/cargo" "$harness"

  PATH="$tmp/bin:$PATH" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" CODEX_TEST_GIT_LOG="$log" \
    "$harness" patch-codex --print-bin --background --quiet
  PATH="$tmp/bin:$PATH" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" CODEX_TEST_GIT_LOG="$log" \
    "$harness" patch-codex --print-bin --background --quiet

  for (( i=0; i<100; i++ )); do
    [[ -f "$log" ]] && break
    sleep 0.02
  done
  sleep 0.1
  clone_count="$(grep -Fc 'git:clone ' "$log" 2>/dev/null || true)"
  [[ "$clone_count" == "1" ]] || fail "expected one detached patch build, got $clone_count"
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

test_patch_codex_keys_native_binary_without_script_scan() {
  local tmp home fast_key full_key native_bin
  tmp="$(mktemp -d)"
  home="$tmp/home"
  native_bin="/bin/echo"
  [[ -x "$native_bin" ]] || native_bin="/usr/bin/echo"
  if ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_patch_codex_keys_native_binary_without_script_scan\n'
    return 0
  fi

  fast_key="$(timeout 3 env HOME="$home" CODEX_HOME="$home" CODEX_AUTH_STOCK_CODEX_BIN="$native_bin" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  full_key="$(timeout 3 env HOME="$home" CODEX_HOME="$home" CODEX_AUTH_FAST_PATCH=0 CODEX_AUTH_STOCK_CODEX_BIN="$native_bin" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"

  [[ -n "$fast_key" ]] || fail "native Codex fast patch key was empty"
  [[ "$fast_key" == "$full_key" ]] || fail "native Codex fast and full patch keys differed"
}

test_shim_prefers_standalone_current_and_tracks_repoint() {
  local tmp home codex_home release_one release_two log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/custom-codex-home"
  release_one="$codex_home/packages/standalone/releases/1.0.0-test"
  release_two="$codex_home/packages/standalone/releases/2.0.0-test"
  log="$tmp/calls.log"
  write_named_fake_codex "$release_one/bin/codex" standalone-one 1.0.0
  write_named_fake_codex "$release_two/bin/codex" standalone-two 2.0.0
  write_named_fake_codex "$home/.bun/bin/codex-real" stale-bun 0.1.0
  mkdir -p "$codex_home/packages/standalone"
  ln -s "$release_one" "$codex_home/packages/standalone/current"

  HOME="$home" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$REPO_ROOT/bin/codex" ping
  assert_contains 'standalone-one:--yolo ping' "$log"
  assert_not_contains 'stale-bun:' "$log"

  rm -f "$codex_home/packages/standalone/current"
  ln -s "$release_two" "$codex_home/packages/standalone/current"
  HOME="$home" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$REPO_ROOT/bin/codex" pong
  assert_contains 'standalone-two:--yolo pong' "$log"
  assert_not_contains 'stale-bun:' "$log"
}

test_shim_supports_legacy_standalone_current_layout() {
  local tmp home codex_home release log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/.codex"
  release="$codex_home/packages/standalone/releases/legacy-test"
  log="$tmp/calls.log"
  write_named_fake_codex "$release/codex" standalone-legacy 0.99.0
  mkdir -p "$codex_home/packages/standalone"
  ln -s "$release" "$codex_home/packages/standalone/current"

  HOME="$home" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$REPO_ROOT/bin/codex" legacy

  assert_contains 'standalone-legacy:--yolo legacy' "$log"
}

test_shim_skips_other_codex_auth_shim() {
  local tmp home bad good log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  bad="$tmp/bad/codex"
  good="$tmp/good/codex"
  log="$tmp/calls.log"
  mkdir -p "$(dirname "$bad")"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'CODEX_AUTH_SHIM=1' \
    'exit 91' > "$bad"
  chmod 0755 "$bad"
  write_named_fake_codex "$good" fallback-real 3.0.0

  HOME="$home" PATH="$tmp/good:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_CODEX_BIN="$bad" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$REPO_ROOT/bin/codex" recurse-check

  assert_contains 'fallback-real:--yolo recurse-check' "$log"
}

test_shim_uses_matching_patched_standalone_codex() {
  local tmp home codex_home release log key marker patched_bin
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/.codex"
  release="$codex_home/packages/standalone/releases/9.8.7-test"
  log="$tmp/calls.log"
  marker="$codex_home/patched-codex/current.env"
  patched_bin="$codex_home/patched-codex/bin/codex"
  write_fake_codex "$release/bin/codex"
  write_fake_patched_codex "$patched_bin"
  mkdir -p "$codex_home/packages/standalone" "$(dirname "$marker")"
  ln -s "$release" "$codex_home/packages/standalone/current"
  key="$(CODEX_HOME="$codex_home" CODEX_AUTH_STOCK_CODEX_BIN="$release/bin/codex" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  printf 'patch_version=2\nstock_key=%s\n' "$key" > "$marker"

  HOME="$home" CODEX_HOME="$codex_home" PATH="$REPO_ROOT/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 "$REPO_ROOT/bin/codex" resume standalone

  assert_contains 'patched:--yolo resume standalone rolling=1' "$log"
  assert_not_contains 'real:--yolo resume standalone' "$log"
}

test_patch_codex_discovers_standalone_current() {
  local tmp home codex_home release implicit_fast implicit_full explicit
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/.codex"
  release="$codex_home/packages/standalone/releases/9.8.7-test"
  write_fake_codex "$release/bin/codex"
  write_named_fake_codex "$home/.bun/bin/codex-real" stale-bun 0.1.0
  mkdir -p "$codex_home/packages/standalone"
  ln -s "$release" "$codex_home/packages/standalone/current"

  explicit="$(HOME="$home" CODEX_HOME="$codex_home" CODEX_AUTH_STOCK_CODEX_BIN="$release/bin/codex" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  implicit_fast="$(HOME="$home" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  implicit_full="$(HOME="$home" CODEX_HOME="$codex_home" PATH="/usr/bin:/bin" CODEX_AUTH_FAST_PATCH=0 "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"

  [[ "$implicit_fast" == "$explicit" ]] || fail "fast patch lookup did not select standalone current"
  [[ "$implicit_full" == "$explicit" ]] || fail "full patch lookup did not select standalone current"
}

test_patch_generation_selection_is_key_specific() {
  local tmp home root stock_a stock_b key_a key_b path_a path_b
  tmp="$(mktemp -d)"
  home="$tmp/home"
  root="$home/patched"
  stock_a="$tmp/stock-a"
  stock_b="$tmp/stock-b"
  write_named_fake_codex "$stock_a" stock-a 1.2.3
  write_named_fake_codex "$stock_b" stock-b 1.2.4
  key_a="$(CODEX_HOME="$home" CODEX_AUTH_PATCH_CODEX_DIR="$root" CODEX_AUTH_STOCK_CODEX_BIN="$stock_a" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  key_b="$(CODEX_HOME="$home" CODEX_AUTH_PATCH_CODEX_DIR="$root" CODEX_AUTH_STOCK_CODEX_BIN="$stock_b" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  mkdir -p "$root/generations/$key_a" "$root/generations/$key_b"
  write_fake_patched_codex "$root/generations/$key_a/codex"
  write_fake_patched_codex "$root/generations/$key_b/codex"
  printf 'patch_version=2\nstock_key=%s\n' "$key_a" > "$root/generations/$key_a/current.env"
  printf 'patch_version=2\nstock_key=%s\n' "$key_b" > "$root/generations/$key_b/current.env"

  path_a="$(CODEX_HOME="$home" CODEX_AUTH_PATCH_CODEX_DIR="$root" CODEX_AUTH_STOCK_CODEX_BIN="$stock_a" "$REPO_ROOT/bin/codex-auth" patch-codex --print-bin --quiet)"
  path_b="$(CODEX_HOME="$home" CODEX_AUTH_PATCH_CODEX_DIR="$root" CODEX_AUTH_STOCK_CODEX_BIN="$stock_b" "$REPO_ROOT/bin/codex-auth" patch-codex --print-bin --quiet)"

  [[ "$path_a" == "$root/generations/$key_a/codex" ]] || fail "stock A did not select its immutable generation"
  [[ "$path_b" == "$root/generations/$key_b/codex" ]] || fail "stock B did not select its immutable generation"
  [[ "$path_a" != "$path_b" ]] || fail "different stock keys shared one patched binary"
}

test_patch_missing_exact_tag_fails_closed() {
  local tmp home root source stock key
  tmp="$(mktemp -d)"
  home="$tmp/home"
  root="$home/patched"
  source="$tmp/source"
  stock="$tmp/stock"
  write_named_fake_codex "$stock" stock 9.8.7
  mkdir -p "$source/codex-rs/login/src/auth"
  : > "$source/codex-rs/login/src/auth/manager.rs"
  git init -q "$source"
  key="$(CODEX_HOME="$home" CODEX_AUTH_PATCH_CODEX_DIR="$root" CODEX_AUTH_STOCK_CODEX_BIN="$stock" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"

  if CODEX_HOME="$home" \
    CODEX_AUTH_PATCH_CODEX_DIR="$root" \
    CODEX_AUTH_PATCH_RETRY_SECS=60 \
    CODEX_AUTH_STOCK_CODEX_BIN="$stock" \
    CODEX_AUTH_FAST_PATCH=0 \
    "$REPO_ROOT/bin/codex-auth" patch-codex --foreground --source-dir "$source" --no-fetch --quiet \
    > "$tmp/out" 2>&1
  then
    fail "automatic patch build accepted source without the exact release tag"
  fi

  assert_contains 'exact Codex source tag is not available yet: rust-v9.8.7' "$tmp/out"
  [[ ! -e "$root/generations/$key/codex" ]] || fail "missing exact tag published a patched generation"
  [[ -f "$root/failures/$key.env" ]] || fail "missing exact tag did not record retry backoff"
}

test_maintain_waits_for_installer_then_restores_shim() {
  local tmp home codex_home root release stock target key lock_fd
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/.codex"
  root="$codex_home/patched-codex"
  release="$codex_home/packages/standalone/releases/9.8.7-test"
  stock="$release/bin/codex"
  target="$tmp/bin/codex"
  write_fake_codex "$stock"
  mkdir -p "$codex_home/packages/standalone" "$tmp/bin"
  ln -s "$release" "$codex_home/packages/standalone/current"
  ln -s "$codex_home/packages/standalone/current/bin/codex" "$target"
  key="$(HOME="$home" CODEX_HOME="$codex_home" CODEX_AUTH_STOCK_CODEX_BIN="$stock" "$REPO_ROOT/bin/codex-auth" patch-codex --print-key)"
  mkdir -p "$root/generations/$key"
  write_fake_patched_codex "$root/generations/$key/codex"
  printf 'patch_version=2\nstock_key=%s\n' "$key" > "$root/generations/$key/current.env"

  exec {lock_fd}>"$codex_home/packages/standalone/install.lock"
  flock -n "$lock_fd"
  HOME="$home" CODEX_HOME="$codex_home" CODEX_AUTH_SHIM_PATH="$target" CODEX_AUTH_SHIM_TEMPLATE="$REPO_ROOT/bin/codex" \
    "$REPO_ROOT/bin/codex-auth" maintain --quiet
  [[ -L "$target" ]] || fail "maintainer rewrote codex while the official installer lock was held"
  flock -u "$lock_fd"
  exec {lock_fd}>&-

  HOME="$home" CODEX_HOME="$codex_home" CODEX_AUTH_SHIM_PATH="$target" CODEX_AUTH_SHIM_TEMPLATE="$REPO_ROOT/bin/codex" \
    "$REPO_ROOT/bin/codex-auth" maintain --quiet
  [[ ! -L "$target" ]] || fail "maintainer did not replace the official standalone link"
  assert_contains 'CODEX_AUTH_SHIM=1' "$target"
}

test_install_maintenance_cron_is_idempotent() {
  local tmp home prefix fake_bin cron_state begin_count
  tmp="$(mktemp -d)"
  home="$tmp/home"
  prefix="$tmp/prefix"
  fake_bin="$tmp/fake-bin"
  cron_state="$tmp/crontab"
  mkdir -p "$fake_bin"
  printf '%s\n' '0 9 * * 0 /existing/weekly-job' > "$cron_state"
  cat > "$fake_bin/crontab" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == "-l" ]]; then
  cat "$CODEX_TEST_CRONTAB_FILE"
else
  cp "$1" "$CODEX_TEST_CRONTAB_FILE"
fi
EOF
  chmod 0755 "$fake_bin/crontab"
  write_fake_codex "$prefix/bin/codex"

  for _ in 1 2; do
    HOME="$home" CODEX_HOME="$home/.codex" PREFIX="$prefix" PATH="$fake_bin:$PATH" \
      CODEX_TEST_CRONTAB_FILE="$cron_state" CODEX_AUTH_TUI_SKIP_BOOTSTRAP=1 \
      CODEX_AUTH_INSTALL_MAINTAIN_CRON=1 "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  done

  assert_contains '0 9 * * 0 /existing/weekly-job' "$cron_state"
  assert_contains "'$prefix/bin/codex-auth' maintain --quiet" "$cron_state"
  begin_count="$(grep -Fc '# BEGIN codex-auth maintain' "$cron_state")"
  [[ "$begin_count" == "1" ]] || fail "installer added duplicate codex-auth cron entries"
}

test_install_promotes_existing_codex_to_real() {
  local tmp home prefix log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  prefix="$tmp/prefix"
  log="$tmp/calls.log"
  write_fake_codex "$prefix/bin/codex"

  HOME="$home" CODEX_HOME="$home/.codex" PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not installed"

  HOME="$home" CODEX_HOME="$home/.codex" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$prefix/bin/codex" ping
  assert_contains 'real:--yolo ping' "$log"
}

test_install_refreshes_stale_real_from_standalone_current() {
  local tmp home codex_home prefix release log backup real_target
  local backups=()
  tmp="$(mktemp -d)"
  home="$tmp/home"
  codex_home="$home/.codex"
  prefix="$home/.local"
  release="$codex_home/packages/standalone/releases/4.5.6-test"
  log="$tmp/calls.log"
  write_named_fake_codex "$release/bin/codex" standalone-current 4.5.6
  write_named_fake_codex "$prefix/bin/codex-real" stale-real 0.1.0
  mkdir -p "$codex_home/packages/standalone" "$prefix/bin"
  ln -s "$release" "$codex_home/packages/standalone/current"
  ln -s "$codex_home/packages/standalone/current/bin/codex" "$prefix/bin/codex"

  HOME="$home" CODEX_HOME="$codex_home" PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null

  if [[ -L "$prefix/bin/codex-real" ]]; then
    real_target="$(readlink "$prefix/bin/codex-real")"
    [[ "$real_target" == "$codex_home/packages/standalone/current/bin/codex" ]] || fail "codex-real did not preserve standalone current"
    [[ "$real_target" != "$release/bin/codex" ]] || fail "codex-real pinned one standalone release"
  else
    assert_contains "$codex_home/packages/standalone/current/bin/codex" "$prefix/bin/codex-real"
    assert_not_contains "$release/bin/codex" "$prefix/bin/codex-real"
  fi
  shopt -s nullglob
  backups=("$prefix/bin"/codex.backup.*)
  shopt -u nullglob
  [[ "${#backups[@]}" == "1" ]] || fail "standalone wrap did not create one backup link"
  backup="${backups[0]}"
  [[ -L "$backup" ]] || fail "standalone backup was dereferenced instead of preserved as a symlink"

  HOME="$home" CODEX_HOME="$codex_home" PATH="$prefix/bin:/usr/bin:/bin" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$prefix/bin/codex" installed
  assert_contains 'standalone-current:--yolo installed' "$log"
  assert_not_contains 'stale-real:' "$log"
}

test_install_recovers_real_from_old_backup() {
  local tmp home prefix log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  prefix="$tmp/prefix"
  log="$tmp/calls.log"
  mkdir -p "$prefix/bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'CODEX_AUTH_SHIM=1' \
    'exec codex-auth run -- "$@"' > "$prefix/bin/codex"
  chmod 0755 "$prefix/bin/codex"
  write_fake_codex "$prefix/bin/codex.backup.202605180001"

  HOME="$home" CODEX_HOME="$home/.codex" PREFIX="$prefix" "$REPO_ROOT/install.sh" --wrap-codex >/dev/null
  [[ -x "$prefix/bin/codex-real" ]] || fail "codex-real was not recovered from backup"

  HOME="$home" CODEX_HOME="$home/.codex" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$prefix/bin/codex" ping
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

  HOME="$tmp/home" CODEX_HOME="$tmp/home/.codex" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$prefix/bin/codex" ping
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

  HOME="$fake_home" CODEX_HOME="$fake_home/.codex" CODEX_TEST_LOG="$log" CODEX_AUTH_AUTO=0 CODEX_AUTH_PATCH_AUTO=0 "$prefix/bin/codex" ping
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
  [[ -r "$prefix/lib/codex-auth/rolling-auth-v2.patch" ]] || fail "rolling auth source patch was not installed"
  [[ -x "$prefix/bin/codex-auth-tui" ]] || fail "TUI launcher was not installed"
  [[ -r "$prefix/lib/codex-auth/tui/pyproject.toml" ]] || fail "TUI project was not installed"
  [[ -r "$prefix/lib/codex-auth/tui/src/codex_auth_tui/__init__.py" ]] || fail "TUI package was not installed"
  [[ ! -d "$prefix/lib/codex-auth/tui/.venv" ]] || fail "TUI bootstrap opt-out created a venv"

  TERM=dumb CODEX_HOME="$home" "$prefix/bin/codex-auth" paths >"$output"
  assert_contains 'auth' "$output"
  assert_contains 'profiles' "$output"
}

test_install_bootstraps_tui_with_private_uv_project() {
  local tmp prefix fake_bin uv_log
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  fake_bin="$tmp/bin"
  uv_log="$tmp/uv.log"
  mkdir -p "$fake_bin"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$@" > "$CODEX_TEST_UV_LOG"' \
    '[[ "${1:-}" == "--native-tls" && "${2:-}" == "sync" && "${3:-}" == "--project" && -n "${4:-}" && "${5:-}" == "--no-dev" && "${6:-}" == "--locked" ]] || exit 64' \
    'mkdir -p "$4/.venv/bin"' \
    'printf "#!/usr/bin/env bash\\nexit 0\\n" > "$4/.venv/bin/python"' \
    'chmod 0755 "$4/.venv/bin/python"' \
    'printf "#!/usr/bin/env bash\\n" > "$4/.venv/bin/codex-auth-tui"' \
    'chmod 0755 "$4/.venv/bin/codex-auth-tui"' > "$fake_bin/uv"
  chmod 0755 "$fake_bin/uv"

  PATH="$fake_bin:$PATH" CODEX_TEST_UV_LOG="$uv_log" CODEX_AUTH_TUI_SKIP_BOOTSTRAP=0 PREFIX="$prefix" "$REPO_ROOT/install.sh" >/dev/null

  assert_contains '--native-tls' "$uv_log"
  assert_contains 'sync' "$uv_log"
  assert_contains "$prefix/lib/codex-auth/tui" "$uv_log"
  assert_contains '--no-dev' "$uv_log"
  assert_contains '--locked' "$uv_log"
  [[ -x "$prefix/lib/codex-auth/tui/.venv/bin/codex-auth-tui" ]] || fail "private TUI venv was not bootstrapped"
}

test_failed_tui_bootstrap_keeps_previous_install() {
  local tmp prefix fake_bin status
  tmp="$(mktemp -d)"
  prefix="$tmp/prefix"
  fake_bin="$tmp/bin"
  mkdir -p "$fake_bin"

  CODEX_AUTH_TUI_SKIP_BOOTSTRAP=1 PREFIX="$prefix" "$REPO_ROOT/install.sh" >/dev/null
  printf '%s\n' '#!/usr/bin/env bash' 'printf "previous-shell\n"' > "$prefix/bin/codex-auth"
  chmod 0755 "$prefix/bin/codex-auth"
  printf '%s\n' 'previous-tui' > "$prefix/lib/codex-auth/tui/previous.marker"
  printf '%s\n' '#!/usr/bin/env bash' 'exit 42' > "$fake_bin/uv"
  chmod 0755 "$fake_bin/uv"

  set +e
  PATH="$fake_bin:$PATH" CODEX_AUTH_TUI_SKIP_BOOTSTRAP=0 PREFIX="$prefix" "$REPO_ROOT/install.sh" >/dev/null 2>&1
  status=$?
  set -e

  [[ "$status" != "0" ]] || fail "failed uv bootstrap reported success"
  assert_contains 'previous-shell' "$prefix/bin/codex-auth"
  assert_contains 'previous-tui' "$prefix/lib/codex-auth/tui/previous.marker"
  if find "$prefix/lib/codex-auth" -maxdepth 1 -type d -name '.codex-auth-install.*' | grep -q .; then
    fail "failed bootstrap left an install staging directory"
  fi
}

test_watch_and_tui_forward_exact_args() {
  local tmp fake watch_log tui_log watch_expected tui_expected
  tmp="$(mktemp -d)"
  fake="$tmp/fake-tui"
  watch_log="$tmp/watch.log"
  tui_log="$tmp/tui.log"
  watch_expected="$tmp/watch.expected"
  tui_expected="$tmp/tui.expected"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$#" > "$CODEX_TEST_LOG"' \
    'printf "%s\\n" "$@" >> "$CODEX_TEST_LOG"' > "$fake"
  chmod 0755 "$fake"

  CODEX_TEST_LOG="$watch_log" CODEX_AUTH_TUI_PATCH_AUTO=0 CODEX_AUTH_TUI_BIN="$fake" "$REPO_ROOT/bin/codex-auth" watch --auto --live --threshold 0
  printf '%s\n' 4 --auto --live --threshold 0 > "$watch_expected"
  cmp -s "$watch_expected" "$watch_log" || fail "watch did not forward exact TUI arguments"

  CODEX_TEST_LOG="$tui_log" CODEX_AUTH_TUI_PATCH_AUTO=0 CODEX_AUTH_TUI_BIN="$fake" "$REPO_ROOT/bin/codex-auth" tui --interval 15
  printf '%s\n' 2 --interval 15 > "$tui_expected"
  cmp -s "$tui_expected" "$tui_log" || fail "tui did not forward exact TUI arguments"
}

test_tui_dispatches_patch_check_without_blocking() {
  local tmp fake_tui fake_lib stock tui_log patch_log started finished elapsed deadline count
  tmp="$(mktemp -d)"
  fake_tui="$tmp/fake-tui"
  fake_lib="$tmp/lib"
  stock="$tmp/stock-codex"
  tui_log="$tmp/tui.log"
  patch_log="$tmp/patch.log"
  mkdir -p "$fake_lib"

  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$@" > "$CODEX_TEST_TUI_LOG"' > "$fake_tui"
  chmod 0755 "$fake_tui"
  write_fake_codex "$stock"
  : > "$fake_lib/core.sh"
  : > "$fake_lib/render.sh"
  : > "$fake_lib/output.sh"
  printf '%s\n' \
    'cmd_patch_codex() {' \
    '  printf "%s\\n" "$*" >> "$CODEX_TEST_PATCH_LOG"' \
    '  sleep 2' \
    '}' > "$fake_lib/patch.sh"

  started="$(date +%s%N)"
  CODEX_HOME="$tmp/home" \
    CODEX_AUTH_CODEX_BIN="$stock" \
    CODEX_AUTH_LIB_DIR="$fake_lib" \
    CODEX_AUTH_TUI_BIN="$fake_tui" \
    CODEX_TEST_LOG="$tmp/codex.log" \
    CODEX_TEST_TUI_LOG="$tui_log" \
    CODEX_TEST_PATCH_LOG="$patch_log" \
    "$REPO_ROOT/bin/codex-auth" tui --interval 15
  finished="$(date +%s%N)"
  elapsed=$((finished - started))
  (( elapsed < 1000000000 )) || fail "TUI waited for the detached patch check"
  assert_contains '--interval' "$tui_log"

  deadline=$((SECONDS + 2))
  while [[ ! -s "$patch_log" && "$SECONDS" -lt "$deadline" ]]; do
    sleep 0.02
  done
  assert_contains '--background --quiet' "$patch_log"
  count="$(wc -l < "$patch_log")"
  [[ "$count" == "1" ]] || fail "TUI dispatched $count patch checks instead of one"
}

test_use_if_current_is_atomic_compare_and_switch() {
  local tmp home status expected_fp target_fp
  tmp="$(mktemp -d)"
  home="$tmp/home"
  mkdir -p "$home/auth-profiles"
  printf '%s\n' '{"OPENAI_API_KEY":"a"}' > "$home/auth-profiles/a.json"
  printf '%s\n' '{"OPENAI_API_KEY":"b"}' > "$home/auth-profiles/b.json"
  printf '%s\n' '{"OPENAI_API_KEY":"c"}' > "$home/auth-profiles/c.json"
  cp "$home/auth-profiles/a.json" "$home/auth.json"

  TERM=dumb CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use-if-current a b >/dev/null
  cmp -s "$home/auth.json" "$home/auth-profiles/b.json" || fail "compare-and-switch did not activate b"

  set +e
  TERM=dumb CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use-if-current a c >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "75" ]] || fail "stale compare-and-switch returned $status instead of 75"
  cmp -s "$home/auth.json" "$home/auth-profiles/b.json" || fail "stale compare-and-switch overwrote the newer active profile"

  cp "$home/auth-profiles/a.json" "$home/auth.json"
  expected_fp="$(printf '%s\n' 'api:a' | sha256sum)"
  expected_fp="${expected_fp%% *}"
  target_fp="$(printf '%s\n' 'api:b' | sha256sum)"
  target_fp="${target_fp%% *}"
  cat > "$home/auth-state.json" <<EOF
{"version":1,"profiles":{"a":{"fingerprint":"$expected_fp","refresh_generation":"generation-1","payload":{}},"b":{"fingerprint":"$target_fp","refresh_generation":"generation-1","payload":{}}}}
EOF
  TERM=dumb CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use-if-current a b generation-1 >/dev/null
  cmp -s "$home/auth.json" "$home/auth-profiles/b.json" || fail "generation-bound compare-and-switch did not activate b"

  cp "$home/auth-profiles/a.json" "$home/auth.json"
  printf '%s\n' '{"OPENAI_API_KEY":"b-changed"}' > "$home/auth-profiles/b.json"
  set +e
  TERM=dumb CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use-if-current a b generation-1 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "75" ]] || fail "changed target generation guard returned $status instead of 75"
  cmp -s "$home/auth.json" "$home/auth-profiles/a.json" || fail "changed unmeasured target was activated"

  printf '%s\n' '{"OPENAI_API_KEY":"b"}' > "$home/auth-profiles/b.json"
  printf '%s\n' '{"OPENAI_API_KEY":"a-changed"}' > "$home/auth-profiles/a.json"
  cp "$home/auth-profiles/a.json" "$home/auth.json"
  set +e
  TERM=dumb CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use-if-current a b generation-1 >/dev/null 2>&1
  status=$?
  set -e
  [[ "$status" == "75" ]] || fail "changed current generation guard returned $status instead of 75"
  cmp -s "$home/auth.json" "$home/auth-profiles/a.json" || fail "changed unmeasured current profile was switched"
}

test_tui_launcher_resolves_source_and_installed_layouts() {
  local tmp source_root installed_root source_log installed_log runner
  tmp="$(mktemp -d)"
  source_root="$tmp/source"
  installed_root="$tmp/installed"
  source_log="$tmp/source.log"
  installed_log="$tmp/installed.log"

  mkdir -p \
    "$source_root/bin" \
    "$source_root/tui/src/codex_auth_tui" \
    "$source_root/tui/.venv/bin" \
    "$installed_root/bin" \
    "$installed_root/lib/codex-auth/tui/src/codex_auth_tui" \
    "$installed_root/lib/codex-auth/tui/.venv/bin"
  install -m 0755 "$REPO_ROOT/bin/codex-auth-tui" "$source_root/bin/codex-auth-tui"
  install -m 0755 "$REPO_ROOT/bin/codex-auth-tui" "$installed_root/bin/codex-auth-tui"
  : > "$source_root/tui/pyproject.toml"
  : > "$installed_root/lib/codex-auth/tui/pyproject.toml"

  for runner in \
    "$source_root/tui/.venv/bin/codex-auth-tui" \
    "$installed_root/lib/codex-auth/tui/.venv/bin/codex-auth-tui"
  do
    printf '%s\n' \
      '#!/usr/bin/env bash' \
      'printf "%s\\n" "$@" > "$CODEX_TEST_LOG"' > "$runner"
    chmod 0755 "$runner"
  done
  for runner in \
    "$source_root/tui/.venv/bin/python" \
    "$installed_root/lib/codex-auth/tui/.venv/bin/python"
  do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$runner"
    chmod 0755 "$runner"
  done

  CODEX_TEST_LOG="$source_log" "$source_root/bin/codex-auth-tui" --auto --threshold 0
  CODEX_TEST_LOG="$installed_log" "$installed_root/bin/codex-auth-tui" --auto --live
  [[ "$(tr '\n' ' ' < "$source_log")" == "--auto --threshold 0 " ]] || fail "source TUI layout was not resolved"
  [[ "$(tr '\n' ' ' < "$installed_log")" == "--auto --live " ]] || fail "installed TUI layout was not resolved"
}

test_tui_launcher_falls_back_to_uv_project() {
  local tmp root fake_bin uv_log expected
  tmp="$(mktemp -d)"
  root="$tmp/source"
  fake_bin="$tmp/bin"
  uv_log="$tmp/uv.log"
  expected="$tmp/expected.log"
  mkdir -p "$root/bin" "$root/tui/src/codex_auth_tui" "$fake_bin"
  install -m 0755 "$REPO_ROOT/bin/codex-auth-tui" "$root/bin/codex-auth-tui"
  : > "$root/tui/pyproject.toml"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\\n" "$@" > "$CODEX_TEST_UV_LOG"' > "$fake_bin/uv"
  chmod 0755 "$fake_bin/uv"

  PATH="$fake_bin:/usr/bin:/bin" CODEX_TEST_UV_LOG="$uv_log" "$root/bin/codex-auth-tui" --auto --live >/dev/null 2>"$tmp/stderr"
  printf '%s\n' --native-tls run --project "$root/tui" --no-dev --locked codex-auth-tui --auto --live > "$expected"
  cmp -s "$expected" "$uv_log" || fail "TUI launcher did not fall back to the isolated uv project"
  assert_contains 'environment is missing' "$tmp/stderr"
}

test_help_defaults_to_daily_selector_surface() {
  local tmp home output full_output usage_output
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/help.txt"
  full_output="$tmp/help-all.txt"
  usage_output="$tmp/usage-help.txt"

  TERM=dumb COLUMNS=100 CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" help >"$output"
  assert_contains 'usage --sync' "$output"
  assert_contains 'usage --refresh --select' "$output"
  assert_contains 'usage --cached --select' "$output"
  assert_contains 'watch --auto --live' "$output"
  assert_contains 'help --all' "$output"
  assert_not_contains 'patch-codex' "$output"
  assert_not_contains 'run -- <args>' "$output"

  TERM=dumb COLUMNS=100 CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" help --all >"$full_output"
  assert_contains 'patch-codex' "$full_output"
  assert_contains 'run -- <args>' "$full_output"

  TERM=dumb COLUMNS=100 CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" usage --help >"$usage_output"
  assert_contains 'usage --sync' "$usage_output"
  assert_contains 'usage --refresh --select' "$usage_output"
}

test_current_does_not_need_usage_library() {
  local tmp home output log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/current.txt"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"
  mkdir -p "$home"
  printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$home/auth.json"

  TERM=dumb COLUMNS=100 CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" "$REPO_ROOT/bin/codex-auth" current >"$output"

  assert_contains 'Active profile' "$output"
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
  local tmp home log count iteration
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  count="$tmp/count"
  write_retry_codex "$tmp/retry-codex"

  for iteration in 1 2 3 4 5; do
    rm -f "$count"
    : > "$log"
    CODEX_TEST_LOG="$log" CODEX_TEST_COUNT="$count" CODEX_HOME="$home" CODEX_AUTH_RUN_AUTO=0 CODEX_AUTH_CODEX_BIN="$tmp/retry-codex" "$REPO_ROOT/bin/codex-auth" run -- prompt >/dev/null 2>"$tmp/stderr"
  done

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

test_recover_without_session_resumes_last() {
  local tmp home log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  write_fake_codex "$tmp/real-codex"

  if ! command -v script >/dev/null 2>&1; then
    printf 'skip - test_recover_without_session_resumes_last\n'
    return 0
  fi

  CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" script -qec "$REPO_ROOT/bin/codex-auth recover" /dev/null >/dev/null

  assert_contains 'real:resume --last' "$log"
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
  local tmp home output fzf_input fzf_args fp now primary_reset secondary_reset
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  fzf_input="$tmp/fzf-input.txt"
  fzf_args="$tmp/fzf-args.txt"
  mkdir -p "$home/auth-profiles" "$tmp/bin"
  printf '%s\n' '{"OPENAI_API_KEY":"test"}' > "$home/auth-profiles/a.json"
  fp="$(printf '%s\n' 'api:test' | sha256sum)"
  fp="${fp%% *}"
  now="$(date +%s)"
  primary_reset=$((now + 604800))
  secondary_reset=$((now + 18000))
  cat > "$home/auth-state.json" <<EOF
{"version":1,"updated_at":$now,"profiles":{"a":{"updated_at":$now,"fingerprint":"$fp","payload":{"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":30,"windowDurationMins":10080,"resetsAt":$primary_reset},"secondary":{"usedPercent":70,"windowDurationMins":300,"resetsAt":$secondary_reset}}}}}}}
EOF
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

  env -u NO_COLOR PATH="$tmp/bin:$PATH" CODEX_TEST_FZF_INPUT="$fzf_input" CODEX_TEST_FZF_ARGS="$fzf_args" TERM=xterm COLUMNS=120 CODEX_HOME="$home" timeout 2 script -qec "$REPO_ROOT/bin/codex-auth usage --cached --select" /dev/null >"$output"

  assert_contains '--with-nth=4..' "$fzf_args"
  assert_contains '--height=~' "$fzf_args"
  assert_not_contains '--height=100%' "$fzf_args"
  assert_contains $'action\tswitch\ta' "$fzf_input"
  assert_contains $'\033[' "$fzf_input"
  assert_contains $'\033[48;2;' "$fzf_input"
  assert_not_contains '1. ' "$fzf_input"
  assert_not_contains 'circular name reference' "$output"
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
  printf '%s\n' '{"OPENAI_API_KEY":"b"}' > "$home/auth-profiles/b.json"
  printf '%s\n' '{"OPENAI_API_KEY":"c"}' > "$home/auth-profiles/c.json"
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
  assert_not_contains 'circular name reference' "$output"
  assert_contains 'active a' "$output"
}

test_failed_usage_rows_offer_login() {
  local tmp home output fzf_input fzf_args fp now
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  fzf_input="$tmp/fzf-input.txt"
  fzf_args="$tmp/fzf-args.txt"
  mkdir -p "$home/auth-profiles" "$tmp/bin"
  printf '%s\n' '{"OPENAI_API_KEY":"a"}' > "$home/auth-profiles/a.json"
  fp="$(printf '%s\n' 'api:a' | sha256sum)"
  fp="${fp%% *}"
  now="$(date +%s)"
  cat > "$home/auth-state.json" <<EOF
{"version":1,"updated_at":$now,"profiles":{"a":{"updated_at":$now,"fingerprint":"$fp","payload":{"error":{"message":"failed to fetch"}}}}}
EOF
  cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_TEST_FZF_ARGS"
cat > "$CODEX_TEST_FZF_INPUT"
exit 130
EOF
  chmod 0755 "$tmp/bin/fzf"

  if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_failed_usage_rows_offer_login\n'
    return 0
  fi

  env -u NO_COLOR PATH="$tmp/bin:$PATH" CODEX_TEST_FZF_INPUT="$fzf_input" CODEX_TEST_FZF_ARGS="$fzf_args" TERM=xterm COLUMNS=120 CODEX_HOME="$home" timeout 2 script -qec "$REPO_ROOT/bin/codex-auth usage --cached --select" /dev/null >"$output"

  assert_contains $'action\tlogin\ta' "$fzf_input"
  assert_contains 'failed to fe' "$fzf_input"
  assert_not_contains $'action\tswitch\ta' "$fzf_input"
}

test_account_switch_refresh_errors_require_login() {
  local tmp home log shell_output python_output now
  local mismatch_fp signin_fp near_miss_fp
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  shell_output="$tmp/shell.txt"
  python_output="$tmp/python.txt"
  mkdir -p "$home/auth-profiles"
  printf '%s\n' '{"OPENAI_API_KEY":"mismatch"}' > "$home/auth-profiles/account-mismatch.json"
  printf '%s\n' '{"OPENAI_API_KEY":"signin"}' > "$home/auth-profiles/signin-again.json"
  printf '%s\n' '{"OPENAI_API_KEY":"near"}' > "$home/auth-profiles/near-miss.json"
  mismatch_fp="$(printf '%s\n' 'api:mismatch' | sha256sum)"
  mismatch_fp="${mismatch_fp%% *}"
  signin_fp="$(printf '%s\n' 'api:signin' | sha256sum)"
  signin_fp="${signin_fp%% *}"
  near_miss_fp="$(printf '%s\n' 'api:near' | sha256sum)"
  near_miss_fp="${near_miss_fp%% *}"
  now="$(date +%s)"
  cat > "$home/auth-state.json" <<EOF
{"version":1,"updated_at":$now,"profiles":{"account-mismatch":{"updated_at":$now,"fingerprint":"$mismatch_fp","payload":{"error":{"message":"Your access token could not be refreshed because you have since logged out or signed in to another account."}}},"signin-again":{"updated_at":$now,"fingerprint":"$signin_fp","payload":{"error":{"message":"Authentication failed. Please sign in again."}}},"near-miss":{"updated_at":$now,"fingerprint":"$near_miss_fp","payload":{"error":{"message":"access token could not be refreshed after a network error"}}}}}
EOF

  TERM=dumb COLUMNS=200 CODEX_AUTH_FAST_CACHED_PYTHON=0 CODEX_HOME="$home" \
    "$REPO_ROOT/bin/codex-auth" usage --cached > "$shell_output"
  grep -F 'account-mismatch' "$shell_output" | grep -Fq 'login' || fail "shell usage did not classify the account-mismatch refresh error as login"
  grep -F 'signin-again' "$shell_output" | grep -Fq 'login' || fail "shell usage did not classify the sign-in-again error as login"
  if grep -F 'near-miss' "$shell_output" | grep -Fq 'login'; then
    fail "shell usage classified a broader refresh failure as login"
  fi

  TERM=dumb COLUMNS=200 CODEX_AUTH_FAST_CACHED_PYTHON=1 CODEX_HOME="$home" \
    "$REPO_ROOT/bin/codex-auth" usage --cached > "$python_output"
  grep -F 'account-mismatch' "$python_output" | grep -Fq 'login' || fail "Python usage did not classify the account-mismatch refresh error as login"
  grep -F 'signin-again' "$python_output" | grep -Fq 'login' || fail "Python usage did not classify the sign-in-again error as login"
  if grep -F 'near-miss' "$python_output" | grep -Fq 'login'; then
    fail "Python usage classified a broader refresh failure as login"
  fi

  : > "$log"
  write_fake_codex "$tmp/real-codex"
  CODEX_AUTH_REFRESH_BLOCKED=1 \
    CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_TEST_LOG="$log" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast account-mismatch signin-again
  assert_not_contains 'app-server' "$log"
}

test_fast_refresh_persists_definitive_auth_error_generation() {
  local tmp home log profile fingerprint now error_message
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/work.json"
  error_message='Your access token could not be refreshed because you have since logged out or signed in to another account. Please sign in again.'
  write_chatgpt_auth "$profile" rt-work at-work acct-work
  write_rate_limit_codex "$tmp/real-codex"
  fingerprint="$(printf '%s\n' 'chatgpt:rt-work' | sha256sum)"
  fingerprint="${fingerprint%% *}"
  now="$(date +%s)"
  cat > "$home/auth-state.json" <<EOF
{"version":1,"updated_at":$now,"profiles":{"work":{"updated_at":$now,"fingerprint":"$fingerprint","refresh_generation":"old-generation","payload":{"rateLimitsByLimitId":{"codex":{"planType":"pro","primary":{"usedPercent":31,"windowDurationMins":10080,"resetsAt":$((now + 604800))},"secondary":{"usedPercent":22,"windowDurationMins":300,"resetsAt":$((now + 18000))}}}}}}}
EOF

  CODEX_AUTH_REFRESH_GENERATION=invalidated-generation \
    CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_TEST_RATE_ERROR="$error_message" \
    CODEX_TEST_LOG="$log" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast work

  [[ "$(jq -r '.profiles.work.refresh_generation // empty' "$home/auth-state.json")" == "invalidated-generation" ]] \
    || fail "definitive auth error did not stamp the requested refresh generation"
  [[ "$(jq -r '.profiles.work.payload.error.message // empty' "$home/auth-state.json")" == "$error_message" ]] \
    || fail "definitive auth error retained stale cached usage"
  [[ "$(jq -r '.profiles.work.payload.rateLimitsByLimitId // empty' "$home/auth-state.json")" == "" ]] \
    || fail "definitive auth error left stale rate-limit data in state"
}

test_default_usage_timeout_accepts_delayed_rate_limit_response() {
  local tmp home log profile
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/work.json"
  write_chatgpt_auth "$profile" rt-work at-work acct-work
  write_rate_limit_codex "$tmp/real-codex"

  env -u CODEX_AUTH_USAGE_TIMEOUT \
    CODEX_AUTH_REFRESH_GENERATION=delayed-generation \
    CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_TEST_RATE_SLEEP=4.5 \
    CODEX_TEST_LOG="$log" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast work

  [[ "$(jq -r '.profiles.work.refresh_generation // empty' "$home/auth-state.json")" == "delayed-generation" ]] \
    || fail "default usage timeout rejected a rate-limit response after 4.5 seconds"
  [[ "$(jq -r '.profiles.work.payload.rateLimitsByLimitId.codex.primary.usedPercent // empty' "$home/auth-state.json")" == "31" ]] \
    || fail "delayed rate-limit response was not persisted"
  [[ "$(jq -r '.profiles.work.payload.error.message // empty' "$home/auth-state.json")" == "" ]] \
    || fail "delayed rate-limit response was persisted as an error"
}

test_reset_credit_count_and_confirmed_consume() {
  local tmp home log output profile
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  output="$tmp/reset.out"
  profile="$home/auth-profiles/work.json"
  write_chatgpt_auth "$profile" rt-work at-work acct-work
  write_rate_limit_codex "$tmp/real-codex"

  CODEX_TEST_LOG="$log" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet work

  [[ "$(jq -r '.profiles.work.payload.rateLimitResetCredits.availableCount' "$home/auth-state.json")" == "2" ]] \
    || fail "refresh did not preserve the earned reset count"

  if CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work >"$tmp/unconfirmed.out" 2>&1
  then
    fail "reset credit was consumed without --yes"
  fi
  assert_not_contains 'account/rateLimitResetCredit/consume' "$tmp/unconfirmed.out"

  CODEX_TEST_LOG="$log" \
    CODEX_TEST_RESET_CREDITS_AFTER=1 \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work --yes >"$output"

  assert_contains 'account/rateLimitResetCredit/consume' "$log"
  assert_contains 'idempotencyKey' "$log"
  assert_contains 'used reset work' "$output"
  [[ "$(jq -r '.profiles.work.payload.rateLimitResetCredits.availableCount' "$home/auth-state.json")" == "1" ]] \
    || fail "reset readback did not update the remaining count"
  [[ ! -e "$home/.tmp/reset-work.pending" ]] || fail "successful reset left a pending idempotency key"
  [[ ! -e "$home/auth.json" ]] || fail "inactive reset consumption switched live auth"
}

test_reset_credit_retry_reuses_idempotency_key() {
  local tmp home log profile keys
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/work.json"
  write_chatgpt_auth "$profile" rt-work at-work acct-work
  write_rate_limit_codex "$tmp/real-codex"

  CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet work

  if CODEX_TEST_LOG="$log" \
    CODEX_TEST_RESET_NO_RESPONSE=1 \
    CODEX_AUTH_RESET_TIMEOUT=1 \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work --yes >"$tmp/first.out" 2>&1
  then
    fail "ambiguous reset timeout reported success"
  fi
  [[ -s "$home/.tmp/reset-work.pending" ]] || fail "ambiguous reset lost its idempotency key"

  CODEX_TEST_LOG="$log" \
    CODEX_TEST_RESET_OUTCOME=alreadyRedeemed \
    CODEX_TEST_RESET_CREDITS_AFTER=1 \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work --yes >"$tmp/retry.out"

  keys="$(grep -F 'account/rateLimitResetCredit/consume' "$log" \
    | sed 's/^rpc://' \
    | jq -r '.params.idempotencyKey')"
  [[ "$(wc -l <<<"$keys" | tr -d ' ')" == "2" ]] || fail "expected two reset attempts"
  [[ "$(sort -u <<<"$keys" | wc -l | tr -d ' ')" == "1" ]] \
    || fail "reset retry minted a different idempotency key"
  assert_contains 'reset already applied work' "$tmp/retry.out"
  [[ ! -e "$home/.tmp/reset-work.pending" ]] || fail "idempotent success left a pending key"
}

test_reset_credit_non_consuming_outcomes_fail_closed() {
  local tmp home log profile
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/work.json"
  write_chatgpt_auth "$profile" rt-work at-work acct-work
  write_rate_limit_codex "$tmp/real-codex"

  CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet work

  if CODEX_TEST_LOG="$log" \
    CODEX_TEST_RESET_OUTCOME=nothingToReset \
    CODEX_TEST_RESET_CREDITS_AFTER=2 \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work --yes >"$tmp/nothing.out" 2>&1
  then
    fail "nothingToReset reported a consumed reset"
  fi
  assert_contains 'nothing eligible to reset' "$tmp/nothing.out"
  [[ ! -e "$home/.tmp/reset-work.pending" ]] || fail "nothingToReset left a pending key"

  if CODEX_TEST_LOG="$log" \
    CODEX_TEST_RESET_OUTCOME=noCredit \
    CODEX_TEST_RESET_CREDITS_AFTER=0 \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" reset work --yes >"$tmp/no-credit.out" 2>&1
  then
    fail "noCredit reported a consumed reset"
  fi
  assert_contains 'no earned resets available' "$tmp/no-credit.out"
  [[ "$(jq -r '.profiles.work.payload.rateLimitResetCredits.availableCount' "$home/auth-state.json")" == "0" ]] \
    || fail "noCredit readback did not zero the cached count"
  [[ ! -e "$home/.tmp/reset-work.pending" ]] || fail "noCredit left a pending key"
}

test_sync_opens_fresh_tui() {
  local tmp home output fzf_input fzf_args log name
  tmp="$(mktemp -d)"
  home="$tmp/home"
  output="$tmp/out.txt"
  fzf_input="$tmp/fzf-input.txt"
  fzf_args="$tmp/fzf-args.txt"
  log="$tmp/calls.log"
  mkdir -p "$home/auth-profiles" "$tmp/bin"
  for name in a b c d e f g h i j; do
    printf '{"OPENAI_API_KEY":"%s"}\n' "$name" > "$home/auth-profiles/$name.json"
  done
  write_rate_limit_codex "$tmp/real-codex"
  cat > "$tmp/bin/fzf" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_TEST_FZF_ARGS"
cat > "$CODEX_TEST_FZF_INPUT"
grep -m1 '^action' "$CODEX_TEST_FZF_INPUT"
EOF
  chmod 0755 "$tmp/bin/fzf"

  if ! command -v script >/dev/null 2>&1 || ! command -v timeout >/dev/null 2>&1; then
    printf 'skip - test_sync_opens_fresh_tui\n'
    return 0
  fi

  # Ten 0.8s fake refreshes run concurrently. Six seconds still catches a
  # serial regression (about eight seconds) without racing PTY setup on a busy
  # machine.
  env -u CODEX_AUTH_REFRESH_JOBS -u CODEX_AUTH_REFRESH_JOBS_MAX PATH="$tmp/bin:$PATH" CODEX_TEST_RATE_SLEEP=0.8 CODEX_TEST_LOG="$log" CODEX_TEST_FZF_INPUT="$fzf_input" CODEX_TEST_FZF_ARGS="$fzf_args" TERM=xterm CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" timeout 6 script -qec "$REPO_ROOT/bin/codex-auth usage --sync" /dev/null >"$output"

  assert_contains 'real:app-server --listen stdio://' "$log"
  assert_contains '--height=~' "$fzf_args"
  assert_contains $'action\tswitch\ta' "$fzf_input"
  assert_contains '78' "$fzf_input"
  assert_not_contains 'circular name reference' "$output"
  assert_contains 'active a' "$output"
}

test_usage_probe_persists_rotated_auth_to_profile_and_live() {
  local tmp home log profile rotated expected_fingerprint actual_fingerprint
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a 2026-07-10T00:00:00Z
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-new acct-a 2026-07-10T00:01:00Z
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$rotated" "$profile" || fail "usage probe did not persist the rotated profile credential"
  cmp -s "$rotated" "$home/auth.json" || fail "usage probe did not advance matching live auth"
  expected_fingerprint="$(printf '%s\n' 'chatgpt:rt-new' | sha256sum)"
  expected_fingerprint="${expected_fingerprint%% *}"
  actual_fingerprint="$(jq -r '.profiles.a.fingerprint // empty' "$home/auth-state.json")"
  [[ "$actual_fingerprint" == "$expected_fingerprint" ]] || fail "usage state kept the discarded pre-probe credential"
  [[ "$(jq -r '.profile_fingerprint // empty' "$home/active-profile.json")" == "$expected_fingerprint" ]] \
    || fail "active-profile marker kept the discarded pre-probe credential"
}

test_usage_probe_persists_rotation_when_rate_limit_read_fails() {
  local tmp home log profile rotated
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-new acct-a
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_PROBE_FAIL=1 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$rotated" "$profile" || fail "failed rate-limit read discarded the rotated profile credential"
  cmp -s "$rotated" "$home/auth.json" || fail "failed rate-limit read discarded matching live auth"
}

test_usage_probe_rejects_auth_without_a_credential() {
  local tmp home log profile invalid
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  invalid="$tmp/invalid.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  cp "$profile" "$home/auth.json"
  printf '%s\n' '{"tokens":{}}' > "$invalid"
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$invalid" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  [[ "$(jq -r '.tokens.refresh_token' "$profile")" == "rt-old" ]] || fail "invalid temp auth replaced the saved profile"
  [[ "$(jq -r '.tokens.refresh_token' "$home/auth.json")" == "rt-old" ]] || fail "invalid temp auth replaced live auth"
}

test_usage_probe_rejects_cross_account_auth() {
  local tmp home log profile switched
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  switched="$tmp/switched.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$switched" rt-other at-other acct-b
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$switched" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  [[ "$(jq -r '.tokens.refresh_token' "$profile")" == "rt-old" ]] || fail "cross-account temp auth replaced the saved profile"
  [[ "$(jq -r '.tokens.refresh_token' "$home/auth.json")" == "rt-old" ]] || fail "cross-account temp auth replaced live auth"
  if [[ -f "$home/auth-state.json" ]] && jq -e '.profiles.a? != null' "$home/auth-state.json" >/dev/null; then
    fail "cross-account probe payload was attached to the saved profile"
  fi
}

test_usage_probe_does_not_overwrite_concurrent_profile_switch() {
  local tmp home log profile rotated switched
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  switched="$tmp/switched.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-new acct-a
  write_chatgpt_auth "$switched" rt-other at-other acct-b
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_TEST_CONCURRENT_PROFILE_SOURCE="$switched" \
    CODEX_TEST_CONCURRENT_PROFILE_TARGET="$profile" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$switched" "$profile" || fail "probe overwrote a concurrently switched profile"
  [[ "$(jq -r '.tokens.refresh_token' "$home/auth.json")" == "rt-old" ]] || fail "profile CAS failure still advanced live auth"
  if [[ -f "$home/auth-state.json" ]] && jq -e '.profiles.a? != null' "$home/auth-state.json" >/dev/null; then
    fail "probe payload was cached against a concurrently switched profile"
  fi
}

test_usage_probe_does_not_overwrite_concurrent_live_switch() {
  local tmp home log profile rotated switched
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  switched="$tmp/switched.json"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-new acct-a
  write_chatgpt_auth "$switched" rt-other at-other acct-b
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_TEST_CONCURRENT_LIVE_SOURCE="$switched" \
    CODEX_TEST_CONCURRENT_LIVE_TARGET="$home/auth.json" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$rotated" "$profile" || fail "live switch prevented safe profile rotation persistence"
  cmp -s "$switched" "$home/auth.json" || fail "probe overwrote a concurrently switched live session"
}

test_usage_probe_does_not_overwrite_same_refresh_concurrent_profile_update() {
  local tmp home log profile rotated concurrent
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  concurrent="$tmp/concurrent.json"
  write_chatgpt_auth "$profile" rt-same at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-probe acct-a 2026-07-10T00:02:00Z
  write_chatgpt_auth "$concurrent" rt-same at-concurrent acct-a 2026-07-10T00:03:00Z
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_TEST_CONCURRENT_PROFILE_SOURCE="$concurrent" \
    CODEX_TEST_CONCURRENT_PROFILE_TARGET="$profile" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$concurrent" "$profile" || fail "probe overwrote a same-refresh concurrent profile update"
  [[ "$(jq -r '.tokens.access_token' "$home/auth.json")" == "at-old" ]] \
    || fail "profile revision CAS failure still advanced live auth"
}

test_usage_probe_does_not_overwrite_same_refresh_concurrent_live_update() {
  local tmp home log profile rotated concurrent
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  concurrent="$tmp/concurrent.json"
  write_chatgpt_auth "$profile" rt-same at-old acct-a
  cp "$profile" "$home/auth.json"
  write_chatgpt_auth "$rotated" rt-new at-probe acct-a 2026-07-10T00:02:00Z
  write_chatgpt_auth "$concurrent" rt-same at-concurrent acct-a 2026-07-10T00:03:00Z
  write_rotating_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_JOBS=1 \
    CODEX_AUTH_USAGE_TIMEOUT=2 \
    CODEX_TEST_LOG="$log" \
    CODEX_TEST_ROTATED_AUTH_FILE="$rotated" \
    CODEX_TEST_CONCURRENT_LIVE_SOURCE="$concurrent" \
    CODEX_TEST_CONCURRENT_LIVE_TARGET="$home/auth.json" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast a

  cmp -s "$rotated" "$profile" || fail "safe profile rotation was not persisted"
  cmp -s "$concurrent" "$home/auth.json" || fail "probe overwrote a same-refresh concurrent live update"
}

test_live_rotation_syncs_back_to_marked_profile() {
  local tmp home profile rotated log expected_fingerprint
  tmp="$(mktemp -d)"
  home="$tmp/home"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  log="$tmp/calls.log"
  write_chatgpt_auth "$profile" rt-old at-old acct-a
  write_chatgpt_auth "$rotated" rt-new at-new acct-a 2026-07-10T00:01:00Z
  write_fake_codex "$tmp/real-codex"

  CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use a >/dev/null
  cp "$rotated" "$home/auth.json"
  TERM=dumb CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" current > "$tmp/current.txt"

  cmp -s "$rotated" "$profile" || fail "live token rotation was not saved back to its marked profile"
  expected_fingerprint="$(printf '%s\n' 'chatgpt:rt-new' | sha256sum)"
  expected_fingerprint="${expected_fingerprint%% *}"
  [[ "$(jq -r '.profile // empty' "$home/active-profile.json")" == "a" ]] || fail "active marker lost its profile"
  [[ "$(jq -r '.profile_fingerprint // empty' "$home/active-profile.json")" == "$expected_fingerprint" ]] \
    || fail "active marker did not advance with the live token"
  assert_not_contains 'acct-a' "$home/active-profile.json"
  assert_not_contains 'user-acct-a' "$home/active-profile.json"
  assert_contains 'active a' "$tmp/current.txt"
}

test_live_rotation_with_same_refresh_token_syncs_full_auth() {
  local tmp home profile rotated log expected_revision
  tmp="$(mktemp -d)"
  home="$tmp/home"
  profile="$home/auth-profiles/a.json"
  rotated="$tmp/rotated.json"
  log="$tmp/calls.log"
  write_chatgpt_auth "$profile" rt-same at-old acct-a 2026-07-10T00:00:00Z
  write_chatgpt_auth "$rotated" rt-same at-new acct-a 2026-07-10T00:01:00Z
  write_fake_codex "$tmp/real-codex"

  CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use a >/dev/null
  cp "$rotated" "$home/auth.json"
  TERM=dumb CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" current > "$tmp/current.txt"

  cmp -s "$rotated" "$profile" || fail "same-refresh live auth update was not saved to the marked profile"
  expected_revision="$(jq -cS . "$profile" | sha256sum)"
  expected_revision="${expected_revision%% *}"
  [[ "$(jq -r '.profile_revision // empty' "$home/active-profile.json")" == "$expected_revision" ]] \
    || fail "active marker did not advance its full-auth revision"
  assert_contains 'active a' "$tmp/current.txt"
}

test_live_account_switch_never_overwrites_marked_profile() {
  local tmp home profile switched log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  profile="$home/auth-profiles/a.json"
  switched="$tmp/switched.json"
  log="$tmp/calls.log"
  write_chatgpt_auth "$profile" rt-a at-a acct-a
  write_chatgpt_auth "$switched" rt-b at-b acct-b
  write_fake_codex "$tmp/real-codex"

  CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use a >/dev/null
  cp "$switched" "$home/auth.json"
  TERM=dumb CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" current > "$tmp/current.txt"

  [[ "$(jq -r '.tokens.refresh_token' "$profile")" == "rt-a" ]] || fail "a real account switch overwrote the old profile"
  cmp -s "$switched" "$home/auth.json" || fail "profile sync pulled a switched live session backward"
  assert_contains 'active unsaved' "$tmp/current.txt"
}

test_live_rotation_does_not_guess_between_account_aliases() {
  local tmp home first second rotated log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  first="$home/auth-profiles/a.json"
  second="$home/auth-profiles/a-alias.json"
  rotated="$home/auth.json"
  log="$tmp/calls.log"
  write_chatgpt_auth "$first" rt-old-1 at-old-1 acct-a
  write_chatgpt_auth "$second" rt-old-2 at-old-2 acct-a
  write_chatgpt_auth "$rotated" rt-new at-new acct-a
  write_fake_codex "$tmp/real-codex"

  TERM=dumb CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" current > "$tmp/current.txt"

  [[ "$(jq -r '.tokens.refresh_token' "$first")" == "rt-old-1" ]] || fail "ambiguous identity rewrote the first alias"
  [[ "$(jq -r '.tokens.refresh_token' "$second")" == "rt-old-2" ]] || fail "ambiguous identity rewrote the second alias"
  [[ ! -e "$home/active-profile.json" ]] || fail "ambiguous aliases created an active marker"
  assert_contains 'active unsaved' "$tmp/current.txt"
}

test_api_key_mismatch_is_never_lineage_synced() {
  local tmp home profile log
  tmp="$(mktemp -d)"
  home="$tmp/home"
  profile="$home/auth-profiles/key.json"
  log="$tmp/calls.log"
  mkdir -p "$home/auth-profiles"
  printf '%s\n' '{"OPENAI_API_KEY":"api-a"}' > "$profile"
  write_fake_codex "$tmp/real-codex"

  CODEX_HOME="$home" "$REPO_ROOT/bin/codex-auth" use key >/dev/null
  printf '%s\n' '{"OPENAI_API_KEY":"api-b"}' > "$home/auth.json"
  TERM=dumb CODEX_TEST_LOG="$log" CODEX_HOME="$home" CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" current > "$tmp/current.txt"

  [[ "$(jq -r '.OPENAI_API_KEY' "$profile")" == "api-a" ]] || fail "API-key mismatch was lineage-synced"
  [[ "$(jq -r '.OPENAI_API_KEY' "$home/auth.json")" == "api-b" ]] || fail "API-key mismatch changed live auth"
}

test_parallel_refresh_preserves_one_complete_generation() {
  local tmp home log name
  tmp="$(mktemp -d)"
  home="$tmp/home"
  log="$tmp/calls.log"
  mkdir -p "$home/auth-profiles"
  for name in a b c d e f g h i j; do
    printf '{"OPENAI_API_KEY":"%s"}\n' "$name" > "$home/auth-profiles/$name.json"
  done
  write_rate_limit_codex "$tmp/real-codex"

  CODEX_AUTH_REFRESH_GENERATION=test-generation \
    CODEX_AUTH_REFRESH_JOBS=10 \
    CODEX_AUTH_REFRESH_JOBS_MAX=10 \
    CODEX_TEST_RATE_SLEEP=0.05 \
    CODEX_TEST_LOG="$log" \
    CODEX_HOME="$home" \
    CODEX_AUTH_CODEX_BIN="$tmp/real-codex" \
    "$REPO_ROOT/bin/codex-auth" refresh --quiet --fast

  [[ "$(jq -r '.profiles | length' "$home/auth-state.json")" == "10" ]] || fail "parallel refresh lost a profile state row"
  [[ "$(jq -r '[.profiles[].refresh_generation == "test-generation"] | all' "$home/auth-state.json")" == "true" ]] || fail "parallel refresh mixed generations"
}

test_rolling_hook_keeps_inline_auto_cached_by_default() {
  assert_contains 'CODEX_AUTH_ROLLING_TTL_ENV_VAR' "$REPO_ROOT/lib/codex-auth/patch.sh"
  assert_not_contains 'DEFAULT_ROLLING_AUTH_TTL_SECS' "$REPO_ROOT/lib/codex-auth/patch.sh"
  assert_contains 'PATCH_CODEX_PATCH_VERSION=2' "$REPO_ROOT/lib/codex-auth/patch.sh"
  assert_contains 'rust-v${package_base%%+*}' "$REPO_ROOT/lib/codex-auth/patch.sh"
  assert_contains 'maybe_sync_rolling_auth' "$REPO_ROOT/lib/codex-auth/rolling-auth-v2.patch"
  assert_contains 'Self::rolling_auth_enabled() && new_auth.is_some()' "$REPO_ROOT/lib/codex-auth/rolling-auth-v2.patch"
  assert_contains 'self.reload().await;' "$REPO_ROOT/lib/codex-auth/rolling-auth-v2.patch"
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
    test_shim_background_build_can_be_disabled \
    test_shim_update_restores_wrapper_and_starts_rebuild \
    test_shim_bypasses_auto_for_app_server \
    test_shim_honors_auto_bypass \
    test_shim_uses_matching_patched_codex \
    test_patch_background_build_is_single_flight \
    test_patch_codex_keys_forwarding_wrapper_to_target \
    test_patch_codex_keys_native_binary_without_script_scan \
    test_shim_prefers_standalone_current_and_tracks_repoint \
    test_shim_supports_legacy_standalone_current_layout \
    test_shim_skips_other_codex_auth_shim \
    test_shim_uses_matching_patched_standalone_codex \
    test_patch_codex_discovers_standalone_current \
    test_patch_generation_selection_is_key_specific \
    test_patch_missing_exact_tag_fails_closed \
    test_maintain_waits_for_installer_then_restores_shim \
    test_install_maintenance_cron_is_idempotent \
    test_install_promotes_existing_codex_to_real \
    test_install_refreshes_stale_real_from_standalone_current \
    test_install_recovers_real_from_old_backup \
    test_install_recovers_real_from_path \
    test_install_recovers_real_from_home_bun \
    test_install_installs_codex_auth_libs \
    test_install_bootstraps_tui_with_private_uv_project \
    test_failed_tui_bootstrap_keeps_previous_install \
    test_watch_and_tui_forward_exact_args \
    test_tui_dispatches_patch_check_without_blocking \
    test_use_if_current_is_atomic_compare_and_switch \
    test_tui_launcher_resolves_source_and_installed_layouts \
    test_tui_launcher_falls_back_to_uv_project \
    test_help_defaults_to_daily_selector_surface \
    test_current_does_not_need_usage_library \
    test_run_uses_cached_auto_without_app_server_refresh \
    test_run_retries_usage_limit_without_leftover_logs \
    test_recover_does_not_force_yolo \
    test_recover_without_session_resumes_last \
    test_dumb_selector_renders_without_fzf_prompt \
    test_selector_uses_fzf_by_default_when_available \
    test_refresh_select_uses_cached_selector_without_blocking \
    test_failed_usage_rows_offer_login \
    test_account_switch_refresh_errors_require_login \
    test_fast_refresh_persists_definitive_auth_error_generation \
    test_default_usage_timeout_accepts_delayed_rate_limit_response \
    test_reset_credit_count_and_confirmed_consume \
    test_reset_credit_retry_reuses_idempotency_key \
    test_reset_credit_non_consuming_outcomes_fail_closed \
    test_sync_opens_fresh_tui \
    test_usage_probe_persists_rotated_auth_to_profile_and_live \
    test_usage_probe_persists_rotation_when_rate_limit_read_fails \
    test_usage_probe_rejects_auth_without_a_credential \
    test_usage_probe_rejects_cross_account_auth \
    test_usage_probe_does_not_overwrite_concurrent_profile_switch \
    test_usage_probe_does_not_overwrite_concurrent_live_switch \
    test_usage_probe_does_not_overwrite_same_refresh_concurrent_profile_update \
    test_usage_probe_does_not_overwrite_same_refresh_concurrent_live_update \
    test_live_rotation_syncs_back_to_marked_profile \
    test_live_rotation_with_same_refresh_token_syncs_full_auth \
    test_live_account_switch_never_overwrites_marked_profile \
    test_live_rotation_does_not_guess_between_account_aliases \
    test_api_key_mismatch_is_never_lineage_synced \
    test_parallel_refresh_preserves_one_complete_generation \
    test_rolling_hook_keeps_inline_auto_cached_by_default \
    test_doctor_reports_legacy_sidecars \
    test_doctor_refuses_kill_without_yes
  do
    "$test_name"
    printf 'ok - %s\n' "$test_name"
  done
}

main "$@"
