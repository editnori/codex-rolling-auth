# shellcheck shell=bash

USAGE_RECORD_EXTRACT_JQ='
  def blanks: "", "", "", "", "", "", "", "", "";
  def no_usage($age; $stale): ["no_usage", "", $age, $stale, blanks];
  def empty_limit: {used: 0, window: "-", window_num: 0, reset: "-"};
  def limit_row: {used: ((.usedPercent // 0) | tonumber? // 0 | floor), window: (.windowDurationMins // "-"), window_num: ((.windowDurationMins // 0) | tonumber? // 0), reset: (.resetsAt // "-")};
  def credit_label: if . == null then "-" elif .unlimited then "unlimited" elif .hasCredits then (.balance // "yes") else "0" end;
  def error_label: ((.error.message // .error.data.message // .error.data.error.message // .error // "error") | tostring | gsub("[\n\t]+"; " ") | gsub("  +"; " ") | gsub("^ "; "") | gsub(" $"; ""));
  (._codexAuthAgeSec // "") as $age
  | (._codexAuthStale // false | tostring) as $stale
  | if .error? != null then
      ["error", error_label, $age, $stale, blanks]
    else
      (.rateLimitsByLimitId.codex // .rateLimits // null) as $r
      | if $r == null then
          no_usage($age; $stale)
        else
          [($r.primary // empty), ($r.secondary // empty)]
          | map(select(type == "object") | limit_row)
          | map(select(.window_num > 0))
          | sort_by(if .window_num == 0 then 999999999 else .window_num end) as $limits
          | if ($limits | length) == 0 then
              no_usage($age; $stale)
            else
              (if ($limits | length) == 1 and ($limits[0].window_num >= 1440)
               then empty_limit
               else $limits[0]
               end) as $shortLimit
              | (if ($limits | length) == 1 and ($limits[0].window_num < 1440)
               then empty_limit
               else $limits[-1]
               end) as $weeklyLimit
              | ["usage", "", $age, $stale, ($r.planType // "-"),
                 $shortLimit.used, $shortLimit.window, $shortLimit.reset,
                 $weeklyLimit.used, $weeklyLimit.window, $weeklyLimit.reset,
                 ($r.credits | credit_label), ($r.rateLimitReachedType // "")]
            end
        end
    end
  | map(tostring)
  | join("\u001f")
'

state_payload_for_profile() {
  local profile_name="$1"
  local fingerprint="$2"
  local now
  now="$(now_epoch)"

  [[ -f "$STATE_FILE" ]] || return 1
  jq -c --arg name "$profile_name" --arg fp "$fingerprint" --argjson now "$now" '
    (.profiles[$name] // null) as $profile
    | select($profile != null and $profile.fingerprint == $fp)
    | ($profile.payload + {
        _codexAuthAgeSec: (if $profile.updated_at == null
          then null
          else ($now - ($profile.updated_at | tonumber))
        end)
      })
  ' "$STATE_FILE" 2>/dev/null
}

state_update_profile() {
  local profile_name="$1"
  local fingerprint="$2"
  local payload="$3"
  local updated tmp refresh_generation="${CODEX_AUTH_REFRESH_GENERATION:-}"

  updated="$(now_epoch)"
  if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    payload='{"error":{"message":"invalid usage payload"}}'
  fi

  tmp="$(mktemp "$CODEX_HOME/.tmp/auth-state.XXXXXX")"
  {
    flock -x 9
    # Decide which source to merge only after taking the lock.  Parallel
    # writers on a brand-new cache must see the profile written just before
    # them instead of each starting from an empty object and overwriting it.
    if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
      cat "$STATE_FILE"
    else
      printf '{}\n'
    fi | jq -c \
      --arg name "$profile_name" \
      --arg fp "$fingerprint" \
      --arg generation "$refresh_generation" \
      --argjson updated "$updated" \
      --argjson payload "$payload" '
        .version = 1
        | .updated_at = $updated
        | .profiles = (.profiles // {})
        | .profiles[$name] = {
            updated_at: $updated,
            fingerprint: $fp,
            payload: $payload
          }
        | if $generation == "" then . else
            .profiles[$name].refresh_generation = $generation
          end
      ' > "$tmp"
    chmod 600 "$tmp"
    mv "$tmp" "$STATE_FILE"
  } 9>"$CODEX_HOME/.tmp/codex-auth-state.lock"
}

mark_stale_payload() {
  local payload="$1"

  jq -c '. + {_codexAuthStale: true}' <<<"$payload" 2>/dev/null || printf '%s\n' "$payload"
}

format_cache_age() {
  local seconds="${1:-}"
  local mins hours days

  [[ "$seconds" =~ ^[0-9]+$ ]] || return 0
  if (( seconds < 60 )); then
    printf 'now'
  elif (( seconds < 3600 )); then
    mins=$(((seconds + 30) / 60))
    (( mins < 1 )) && mins=1
    printf '%dm' "$mins"
  elif (( seconds < 86400 )); then
    hours=$(((seconds + 1800) / 3600))
    (( hours < 1 )) && hours=1
    printf '%dh' "$hours"
  else
    days=$(((seconds + 43200) / 86400))
    (( days < 1 )) && days=1
    printf '%dd' "$days"
  fi
}

usage_metadata_summary_line() {
  local render_w="$1"
  shift
  local summary_w=$((render_w * 2))
  local line sep record _valid _weekly_used _short_used _mark _profile _plan _weekly _short _status _short_label _weekly_reset _short_reset cache_age
  local old_color="${USAGE_COLOR_ENABLED:-0}"
  local cache_age_max=-1 cache_age_label

  if (( render_w < 40 )); then
    summary_w="$render_w"
  else
    summary_w="$(clamp_int_between "$summary_w" 64 132)"
  fi
  USAGE_COLOR_ENABLED=0
  line="$(print_usage_summary_line "$summary_w" "$@")"
  USAGE_COLOR_ENABLED="$old_color"
  sep="$(usage_separator)"

  if [[ "$line" != cache\ * && "$line" != *"${sep}cache "* ]]; then
    for record in "$@"; do
      IFS=$'\t' read -r _valid _weekly_used _short_used _mark _profile _plan _weekly _short _status _short_label _weekly_reset _short_reset cache_age <<<"$record"
      if [[ "$cache_age" =~ ^[0-9]+$ ]] && (( cache_age > cache_age_max )); then
        cache_age_max="$cache_age"
      fi
    done
    if (( cache_age_max >= 0 )); then
      cache_age_label="$(format_cache_age "$cache_age_max")"
      [[ -n "$cache_age_label" ]] && line+="${sep}cache $cache_age_label"
    fi
  fi

  printf '%s' "$line"
}

usage_payload_still_blocked() {
  local payload="$1"
  local now

  now="$(now_epoch)"
  jq -e --argjson now "$now" '
    if .error? != null then
      ((.error.message // .error.data.message // .error.data.error.message // .error // "")
        | tostring
        | test("token has been invalidated|token_invalidated|invalidated oauth token|token_revoked|access token could not be refreshed because you have since logged out or signed in to another account|please sign in again"; "i"))
    else
      (.rateLimitsByLimitId.codex // .rateLimits // null) as $r
      | if $r == null then
          false
        else
          (($r.secondary.usedPercent // 0) >= 100 and ((($r.secondary.resetsAt // 0) | tonumber? // 0) > $now))
          or (($r.primary.usedPercent // 0) >= 100 and ((($r.primary.resetsAt // 0) | tonumber? // 0) > $now))
        end
    end
  ' <<<"$payload" >/dev/null 2>&1
}

usage_payload_transient_error() {
  local payload="$1"

  jq -e '
    (.error.message // .error.data.message // .error.data.error.message // .error // "")
    | tostring
    | test("^(refresh (timeout|unavailable)|no response)$")
  ' <<<"$payload" >/dev/null 2>&1
}

usage_error_requires_login() {
  local error_text="${1,,}"

  [[ "$error_text" == *"token has been invalidated"* \
    || "$error_text" == *"token_invalidated"* \
    || "$error_text" == *"invalidated oauth token"* \
    || "$error_text" == *"token_revoked"* \
    || "$error_text" == *"access token could not be refreshed because you have since logged out or signed in to another account"* \
    || "$error_text" == *"please sign in again"* ]]
}

usage_auth_file_has_credential() {
  local path="$1"

  auth_file_is_valid "$path" || return 1
  jq -e '
    (((.OPENAI_API_KEY? | type) == "string") and ((.OPENAI_API_KEY | length) > 0))
    or (((.tokens.refresh_token? | type) == "string") and ((.tokens.refresh_token | length) > 0))
    or (((.tokens.access_token? | type) == "string") and ((.tokens.access_token | length) > 0))
  ' "$path" >/dev/null 2>&1
}

usage_sync_probed_auth() {
  local profile_file="$1"
  local temp_auth="$2"
  local expected_fingerprint="$3"
  local expected_identity="${4:-}"
  local expected_revision="${5:-}"
  local current_fingerprint refreshed_fingerprint live_fingerprint=""
  local current_revision refreshed_revision live_revision=""
  local refreshed_identity="" profile_name marker_name marker_fp marker_identity marker_revision
  local update_live=0

  [[ -n "$expected_fingerprint" && -n "$expected_revision" ]] || return 0
  usage_auth_file_has_credential "$temp_auth" || return 0
  refreshed_fingerprint="$(credential_fingerprint "$temp_auth" || true)"
  refreshed_revision="$(auth_file_revision "$temp_auth" || true)"
  [[ -n "$refreshed_fingerprint" && -n "$refreshed_revision" ]] || return 0
  refreshed_identity="$(auth_file_account_identity "$temp_auth" || true)"
  if [[ -n "$expected_identity" ]]; then
    [[ "$refreshed_identity" == "$expected_identity" ]] || return 0
  else
    [[ "$refreshed_fingerprint" == "$expected_fingerprint" ]] || return 0
  fi

  # Most usage probes do not rotate auth. Nothing can be copied in that case,
  # so avoid serializing every parallel refresh on the global mutation lock.
  # Usage state remains bound to the credential fingerprint below; the full
  # revision CAS is only needed when the probe actually changed auth content.
  if [[ "$refreshed_revision" == "$expected_revision" ]]; then
    printf '%s\n' "$refreshed_fingerprint"
    return 0
  fi

  acquire_mutation_lock

  # The app-server probe started from expected_fingerprint. Only copy its
  # refreshed auth back while the saved profile still points at that exact
  # credential. A profile switch or a separate token rotation wins the race.
  usage_auth_file_has_credential "$profile_file" || return 0
  current_fingerprint="$(credential_fingerprint "$profile_file" || true)"
  current_revision="$(auth_file_revision "$profile_file" || true)"
  [[ "$current_fingerprint" == "$expected_fingerprint" \
    && "$current_revision" == "$expected_revision" ]] || return 0

  # Live auth follows the refresh only when it still points at the same
  # pre-probe credential. Never pull a concurrently switched session back.
  if usage_auth_file_has_credential "$AUTH_FILE"; then
    live_fingerprint="$(credential_fingerprint "$AUTH_FILE" || true)"
    live_revision="$(auth_file_revision "$AUTH_FILE" || true)"
    [[ "$live_fingerprint" == "$expected_fingerprint" \
      && "$live_revision" == "$expected_revision" ]] && update_live=1
  fi

  [[ "$(credential_fingerprint "$profile_file" || true)" == "$expected_fingerprint" \
    && "$(auth_file_revision "$profile_file" || true)" == "$expected_revision" ]] || return 0
  if ! cmp -s "$profile_file" "$temp_auth"; then
    copy_auth_file_atomic "$temp_auth" "$profile_file" || return 1
  fi
  if (( update_live )); then
    if [[ "$(credential_fingerprint "$AUTH_FILE" || true)" == "$expected_fingerprint" \
      && "$(auth_file_revision "$AUTH_FILE" || true)" == "$expected_revision" ]] \
      && ! cmp -s "$AUTH_FILE" "$temp_auth"
    then
      copy_auth_file_atomic "$temp_auth" "$AUTH_FILE" || return 1
    fi
  fi

  profile_name="$(basename "$profile_file" .json)"
  marker_name="$(active_profile_marker_read || true)"
  if [[ "$marker_name" == "$profile_name" ]]; then
    marker_fp="$(active_profile_marker_field profile_fingerprint || true)"
    marker_identity="$(active_profile_marker_field account_identity || true)"
    marker_revision="$(active_profile_marker_field profile_revision || true)"
    if [[ "$marker_fp" == "$expected_fingerprint" \
      && "$marker_revision" == "$expected_revision" \
      && ( -z "$expected_identity" || "$marker_identity" == "$expected_identity" ) ]]; then
      active_profile_marker_write "$profile_name" "$profile_file" || true
    fi
  fi

  # The caller uses this receipt when updating usage state. No receipt means
  # the profile changed during the probe and the payload must not be attached
  # to the concurrently selected credential.
  printf '%s\n' "$refreshed_fingerprint"
}

usage_payload_for_profile() {
  local profile_file="$1"
  local fingerprint="$2"
  local profile_name payload cached_payload age error_text
  local probe_fingerprint_file probe_fingerprint=""

  profile_name="$(basename "$profile_file" .json)"
  cached_payload=""
  [[ -n "$fingerprint" ]] && cached_payload="$(state_payload_for_profile "$profile_name" "$fingerprint" || true)"

  if [[ "$USAGE_REFRESH" == "1" && "${CODEX_AUTH_REFRESH_BLOCKED:-0}" == "1" && -n "$cached_payload" ]] \
    && usage_payload_still_blocked "$cached_payload"; then
    printf '%s\n' "$cached_payload"
    return 0
  fi
  if [[ -n "$fingerprint" && "$USAGE_REFRESH" != "1" ]]; then
    if [[ -n "$cached_payload" ]]; then
      age="$(jq -r '._codexAuthAgeSec // 999999999' <<<"$cached_payload" 2>/dev/null || printf '999999999\n')"
      if [[ "$USAGE_CACHED" == "1" ]]; then
        printf '%s\n' "$cached_payload"
        return 0
      fi
      if [[ "$age" =~ ^[0-9]+$ ]] && (( age <= CACHE_TTL )); then
        printf '%s\n' "$cached_payload"
        return 0
      fi
    elif [[ "$USAGE_CACHED" == "1" ]]; then
      printf 'null\n'
      return 0
    fi
  elif [[ "$USAGE_CACHED" == "1" ]]; then
    printf 'null\n'
    return 0
  fi

  probe_fingerprint_file="$(mktemp "$CODEX_HOME/.tmp/auth-probe-fingerprint.XXXXXX")"
  payload="$(usage_json_for_profile "$profile_file" "$probe_fingerprint_file")"
  if [[ -s "$probe_fingerprint_file" ]]; then
    IFS= read -r probe_fingerprint < "$probe_fingerprint_file" || true
  fi
  rm -f "$probe_fingerprint_file"

  if [[ -n "$payload" && "$payload" != "null" ]] && usage_payload_transient_error "$payload"; then
    if [[ -n "$cached_payload" ]]; then
      if [[ "$USAGE_REFRESH" == "1" && "${CODEX_AUTH_REFRESH_FALLBACK_CACHE:-1}" == "1" ]]; then
        mark_stale_payload "$cached_payload"
      else
        printf '%s\n' "$cached_payload"
      fi
    else
      printf '%s\n' "$payload"
    fi
    return 0
  fi

  if [[ -z "$payload" || "$payload" == "null" ]]; then
    if [[ -n "$cached_payload" ]]; then
      if [[ "$USAGE_REFRESH" == "1" ]]; then
        if [[ "${CODEX_AUTH_REFRESH_FALLBACK_CACHE:-1}" == "1" ]]; then
          mark_stale_payload "$cached_payload"
        else
          printf '%s\n' '{"error":{"message":"no response"}}'
        fi
      else
        printf '%s\n' "$cached_payload"
      fi
    else
      printf '%s\n' '{"error":{"message":"no response"}}'
    fi
    return 0
  fi

  if [[ -n "$probe_fingerprint" ]]; then
    if ! jq -e '.error? != null' >/dev/null 2>&1 <<<"$payload"; then
      state_update_profile "$profile_name" "$probe_fingerprint" "$payload"
    else
      # A revoked/invalidated session is an authoritative probe result, not a
      # transport failure. Persist it so consumers stop presenting an old
      # usage bar as though the refresh never happened. Transient failures
      # above continue to serve stale cache without advancing the generation.
      error_text="$(jq -r '
        .error.message // .error.data.message // .error.data.error.message // .error // ""
        | if type == "string" then . else tostring end
      ' <<<"$payload" 2>/dev/null || true)"
      if usage_error_requires_login "$error_text"; then
        state_update_profile "$profile_name" "$probe_fingerprint" "$payload"
      fi
    fi
  fi
  printf '%s\n' "$payload"
}

usage_json_for_profile() (
  local profile_file="$1"
  local probe_fingerprint_file="${2:-}"
  local temp_home payload expected_fingerprint expected_identity="" expected_revision="" synced_fingerprint=""

  temp_home="$(mktemp -d "$CODEX_HOME/.tmp/auth-usage.XXXXXX")"
  trap '[[ -z "${temp_home:-}" ]] || rm -rf "$temp_home" 2>/dev/null || true' EXIT HUP INT TERM
  copy_auth_file_atomic "$profile_file" "$temp_home/auth.json"
  if usage_auth_file_has_credential "$temp_home/auth.json"; then
    expected_fingerprint="$(credential_fingerprint "$temp_home/auth.json" || true)"
    expected_identity="$(auth_file_account_identity "$temp_home/auth.json" || true)"
    expected_revision="$(auth_file_revision "$temp_home/auth.json" || true)"
  else
    expected_fingerprint=""
  fi

  payload="$(usage_json_from_home "$temp_home")"
  synced_fingerprint="$(usage_sync_probed_auth "$profile_file" "$temp_home/auth.json" "$expected_fingerprint" "$expected_identity" "$expected_revision" || true)"
  if [[ -n "$probe_fingerprint_file" && -n "$synced_fingerprint" ]]; then
    printf '%s\n' "$synced_fingerprint" > "$probe_fingerprint_file"
  fi
  rm -rf "$temp_home" 2>/dev/null || true
  temp_home=""
  printf '%s\n' "$payload"
)

usage_kill_process_tree() {
  local pid="${1:-}"
  local signal="${2:-TERM}"
  local child

  [[ "$pid" =~ ^[0-9]+$ ]] || return 0
  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child; do
      [[ "$child" =~ ^[0-9]+$ && "$child" != "$pid" ]] || continue
      usage_kill_process_tree "$child" "$signal"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  fi
  kill "-$signal" "$pid" 2>/dev/null || true
}

usage_json_cleanup_coproc() {
  local rate_in="${1:-}"
  local rate_out="${2:-}"
  local rate_pid="${3:-}"

  [[ "$rate_in" =~ ^[0-9]+$ && -e "/proc/self/fd/$rate_in" ]] && exec {rate_in}>&- || true
  [[ "$rate_out" =~ ^[0-9]+$ && -e "/proc/self/fd/$rate_out" ]] && exec {rate_out}<&- || true
  if [[ -n "$rate_pid" ]]; then
    usage_kill_process_tree "$rate_pid"
    wait "$rate_pid" 2>/dev/null || true
  fi
}

usage_json_from_home() {
  local home_dir="$1"
  local codex_cli line line_id now payload rate_in rate_out rate_pid
  local requested=0 done=0
  local start timeout_sec

  codex_cli="$(codex_bin)" || return 0
  if codex_launcher_needs_node "$codex_cli" && ! command -v node >/dev/null 2>&1; then
    return 0
  fi
  # Current Codex may spend several seconds completing the reset-credit part
  # of account/rateLimits/read. Keep headroom for that response before
  # treating the probe as unavailable and falling back to cached usage.
  timeout_sec="${CODEX_AUTH_USAGE_TIMEOUT:-12}"
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=12

  if ! coproc CODEX_RATE { CODEX_AUTH_RUNNER=1 CODEX_HOME="$home_dir" "$codex_cli" app-server --listen stdio:// 2>/dev/null; }; then
    printf '%s\n' '{"error":{"message":"refresh unavailable"}}'
    return 0
  fi

  rate_out="${CODEX_RATE[0]}"
  rate_in="${CODEX_RATE[1]}"
  rate_pid="$CODEX_RATE_PID"
  start="$(now_epoch)"

  if ! printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-auth","title":"Codex Auth","version":"0.2.0"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}' 1>&"$rate_in" 2>/dev/null; then
    usage_json_cleanup_coproc "$rate_in" "$rate_out" "$rate_pid"
    printf '%s\n' '{"error":{"message":"refresh unavailable"}}'
    return 0
  fi

  while true; do
    if [[ ! "$rate_out" =~ ^[0-9]+$ || ! -e "/proc/self/fd/$rate_out" ]]; then
      payload='{"error":{"message":"refresh unavailable"}}'
      break
    fi
    if IFS= read -r -t 0.25 line 2>/dev/null <&"$rate_out"; then
      line_id="$(jq -r '.id // empty' <<<"$line" 2>/dev/null || true)"
      if [[ "$line_id" == "1" && "$requested" == "0" ]]; then
        printf '%s\n' '{"method":"initialized"}' 1>&"$rate_in" 2>/dev/null || true
        printf '%s\n' '{"id":2,"method":"account/rateLimits/read"}' 1>&"$rate_in" 2>/dev/null || true
        requested=1
      elif [[ "$line_id" == "2" ]]; then
        payload="$(jq -c 'if has("result") then .result else {error:.error} end' <<<"$line" 2>/dev/null || true)"
        done=1
      fi
    else
      now="$(now_epoch)"
      if (( now - start >= timeout_sec )); then
        payload='{"error":{"message":"refresh timeout"}}'
        done=1
      elif ! kill -0 "$rate_pid" 2>/dev/null; then
        payload='{"error":{"message":"refresh unavailable"}}'
        done=1
      fi
    fi
    (( done )) && break
  done

  usage_json_cleanup_coproc "$rate_in" "$rate_out" "$rate_pid"
  printf '%s\n' "$payload"
}

reset_idempotency_key() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    IFS= read -r REPLY < /proc/sys/kernel/random/uuid
    printf '%s\n' "$REPLY"
  elif command -v python3 >/dev/null 2>&1; then
    python3 -c 'import uuid; print(uuid.uuid4())'
  else
    printf 'codex-auth-%s-%s-%s-%s\n' "$(now_epoch)" "$$" "$RANDOM" "$RANDOM"
  fi
}

reset_credit_json_from_home() {
  local home_dir="$1"
  local idempotency_key="$2"
  local codex_cli line line_id now payload rate_payload rate_in rate_out rate_pid
  local outcome="" requested=0 consume_received=0 done=0
  local start timeout_sec

  codex_cli="$(codex_bin)" || {
    printf '%s\n' '{"error":{"message":"reset unavailable"}}'
    return 0
  }
  if codex_launcher_needs_node "$codex_cli" && ! command -v node >/dev/null 2>&1; then
    printf '%s\n' '{"error":{"message":"reset unavailable"}}'
    return 0
  fi
  timeout_sec="${CODEX_AUTH_RESET_TIMEOUT:-10}"
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=10

  if ! coproc CODEX_RESET { CODEX_AUTH_RUNNER=1 CODEX_HOME="$home_dir" "$codex_cli" app-server --listen stdio:// 2>/dev/null; }; then
    printf '%s\n' '{"error":{"message":"reset unavailable"}}'
    return 0
  fi

  rate_out="${CODEX_RESET[0]}"
  rate_in="${CODEX_RESET[1]}"
  rate_pid="$CODEX_RESET_PID"
  start="$(now_epoch)"

  if ! printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-auth","title":"Codex Auth","version":"0.2.0"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}' 1>&"$rate_in" 2>/dev/null; then
    usage_json_cleanup_coproc "$rate_in" "$rate_out" "$rate_pid"
    printf '%s\n' '{"error":{"message":"reset unavailable"}}'
    return 0
  fi

  while true; do
    if [[ ! "$rate_out" =~ ^[0-9]+$ || ! -e "/proc/self/fd/$rate_out" ]]; then
      if (( consume_received )); then
        payload="$(jq -cn --arg outcome "$outcome" '{outcome:$outcome,refreshError:{message:"usage refresh unavailable"}}')"
      else
        payload='{"error":{"message":"reset unavailable"}}'
      fi
      break
    fi
    if IFS= read -r -t 0.25 line 2>/dev/null <&"$rate_out"; then
      line_id="$(jq -r '.id // empty' <<<"$line" 2>/dev/null || true)"
      if [[ "$line_id" == "1" && "$requested" == "0" ]]; then
        printf '%s\n' '{"method":"initialized"}' 1>&"$rate_in" 2>/dev/null || true
        jq -cn --arg key "$idempotency_key" \
          '{id:2,method:"account/rateLimitResetCredit/consume",params:{idempotencyKey:$key}}' \
          1>&"$rate_in" 2>/dev/null || true
        requested=1
      elif [[ "$line_id" == "2" ]]; then
        outcome="$(jq -r '.result.outcome // empty' <<<"$line" 2>/dev/null || true)"
        if [[ -n "$outcome" ]]; then
          consume_received=1
          printf '%s\n' '{"id":3,"method":"account/rateLimits/read"}' 1>&"$rate_in" 2>/dev/null || true
        else
          payload="$(jq -c 'if has("error") then {error:.error} else {error:{message:"invalid reset response"}} end' <<<"$line" 2>/dev/null || true)"
          [[ -n "$payload" ]] || payload='{"error":{"message":"invalid reset response"}}'
          done=1
        fi
      elif [[ "$line_id" == "3" && "$consume_received" == "1" ]]; then
        if jq -e 'has("result")' <<<"$line" >/dev/null 2>&1; then
          rate_payload="$(jq -c '.result' <<<"$line" 2>/dev/null || printf '{}')"
          payload="$(jq -cn --arg outcome "$outcome" --argjson rateLimits "$rate_payload" \
            '{outcome:$outcome,rateLimits:$rateLimits}')"
        else
          payload="$(jq -cn --arg outcome "$outcome" --argjson error "$(jq -c '.error // {message:"usage refresh failed"}' <<<"$line")" \
            '{outcome:$outcome,refreshError:$error}')"
        fi
        done=1
      fi
    else
      now="$(now_epoch)"
      if (( now - start >= timeout_sec )); then
        if (( consume_received )); then
          payload="$(jq -cn --arg outcome "$outcome" '{outcome:$outcome,refreshError:{message:"usage refresh timeout"}}')"
        else
          payload='{"error":{"message":"reset timeout"}}'
        fi
        done=1
      elif ! kill -0 "$rate_pid" 2>/dev/null; then
        if (( consume_received )); then
          payload="$(jq -cn --arg outcome "$outcome" '{outcome:$outcome,refreshError:{message:"usage refresh unavailable"}}')"
        else
          payload='{"error":{"message":"reset unavailable"}}'
        fi
        done=1
      fi
    fi
    (( done )) && break
  done

  usage_json_cleanup_coproc "$rate_in" "$rate_out" "$rate_pid"
  printf '%s\n' "${payload:-{\"error\":{\"message\":\"reset unavailable\"}}}"
}

reset_credit_for_profile() (
  local profile_file="$1"
  local idempotency_key="$2"
  local profile_name temp_home result rate_payload
  local expected_fingerprint="" expected_identity="" expected_revision=""
  local synced_fingerprint=""

  profile_name="$(basename "$profile_file" .json)"
  temp_home="$(mktemp -d "$CODEX_HOME/.tmp/auth-reset.XXXXXX")"
  trap '[[ -z "${temp_home:-}" ]] || rm -rf "$temp_home" 2>/dev/null || true' EXIT HUP INT TERM
  copy_auth_file_atomic "$profile_file" "$temp_home/auth.json"
  expected_fingerprint="$(credential_fingerprint "$temp_home/auth.json" || true)"
  expected_identity="$(auth_file_account_identity "$temp_home/auth.json" || true)"
  expected_revision="$(auth_file_revision "$temp_home/auth.json" || true)"

  result="$(reset_credit_json_from_home "$temp_home" "$idempotency_key")"
  synced_fingerprint="$(usage_sync_probed_auth \
    "$profile_file" "$temp_home/auth.json" "$expected_fingerprint" \
    "$expected_identity" "$expected_revision" || true)"

  rate_payload="$(jq -c '.rateLimits // empty' <<<"$result" 2>/dev/null || true)"
  if [[ -n "$synced_fingerprint" && -n "$rate_payload" ]] \
    && ! jq -e '.error? != null' <<<"$rate_payload" >/dev/null 2>&1
  then
    state_update_profile "$profile_name" "$synced_fingerprint" "$rate_payload"
  fi

  rm -rf "$temp_home" 2>/dev/null || true
  temp_home=""
  printf '%s\n' "$result"
)

cmd_reset() {
  local name="$1" yes="${2:-}" source kind pending pending_tmp idempotency_key
  local result outcome remaining error profile_fingerprint state_fingerprint count

  require_name "$name"
  [[ "$yes" == "--yes" ]] || die "usage: codex-auth reset <profile> --yes"
  ensure_dirs
  source="$(profile_path "$name")"
  [[ -f "$source" ]] || die "profile not found: $name"
  require_auth_file "$source"
  kind="$(auth_file_kind "$source" || true)"
  [[ "$kind" == "chatgpt" ]] || die "earned resets require a ChatGPT profile: $name"
  acquire_mutation_lock

  profile_fingerprint="$(credential_fingerprint "$source" || true)"
  state_fingerprint="$(jq -r --arg name "$name" '.profiles[$name].fingerprint // empty' "$STATE_FILE" 2>/dev/null || true)"
  [[ -n "$profile_fingerprint" && "$profile_fingerprint" == "$state_fingerprint" ]] \
    || die "profile changed since its usage check; refresh before using a reset: $name"
  count="$(jq -r --arg name "$name" '
    .profiles[$name].payload.rateLimitResetCredits.availableCount
    | numbers | select(. >= 0) | floor
  ' "$STATE_FILE" 2>/dev/null || true)"
  [[ "$count" =~ ^[0-9]+$ ]] \
    || die "reset availability is unknown; refresh usage first: $name"
  if (( count == 0 )); then
    print_error "no earned resets available for profile: $name"
    return 3
  fi

  pending="$CODEX_HOME/.tmp/reset-$name.pending"
  idempotency_key=""
  if [[ -s "$pending" ]]; then
    IFS= read -r idempotency_key < "$pending" || true
  fi
  if [[ -z "$idempotency_key" ]]; then
    idempotency_key="$(reset_idempotency_key)"
    pending_tmp="$(mktemp "$CODEX_HOME/.tmp/reset-$name.pending.XXXXXX")"
    printf '%s\n' "$idempotency_key" > "$pending_tmp"
    chmod 600 "$pending_tmp"
    mv -f "$pending_tmp" "$pending"
  fi

  result="$(reset_credit_for_profile "$source" "$idempotency_key")"
  outcome="$(jq -r '.outcome // empty' <<<"$result" 2>/dev/null || true)"
  case "$outcome" in
    reset|alreadyRedeemed)
      rm -f "$pending"
      remaining="$(jq -r '.rateLimits.rateLimitResetCredits.availableCount // empty' <<<"$result" 2>/dev/null || true)"
      [[ -n "$remaining" ]] || remaining="refresh pending"
      if [[ "$outcome" == "alreadyRedeemed" ]]; then
        print_result_block "reset already applied $name" \
          "profile"$'\t'"$name"$'\t'"active" \
          "remaining"$'\t'"$remaining"$'\t'"muted"
      else
        print_result_block "used reset $name" \
          "profile"$'\t'"$name"$'\t'"active" \
          "remaining"$'\t'"$remaining"$'\t'"muted"
      fi
      ;;
    nothingToReset)
      rm -f "$pending"
      print_error "nothing eligible to reset for profile: $name"
      return 3
      ;;
    noCredit)
      rm -f "$pending"
      print_error "no earned resets available for profile: $name"
      return 3
      ;;
    *)
      error="$(jq -r '.error.message // .error.data.message // .error // "reset failed" | if type == "string" then . else tostring end' <<<"$result" 2>/dev/null || true)"
      [[ -n "$error" ]] || error="reset failed"
      print_error "$error"
      return 1
      ;;
  esac
}

usage_limit_remaining_fields() {
  local used="$1"
  local window="$2"
  local reset="$3"
  local left reset_text

  if [[ -z "$window" || "$window" == "-" || "$window" == "0" ]]; then
    printf '0\t-\t-\n'
    return 0
  fi

  left=$((100 - used))
  (( left < 0 )) && left=0
  reset_text="-"
  if [[ -n "$reset" && "$reset" != "-" && "$reset" != "null" && "$reset" != "0" ]]; then
    reset_text="$(TZ="${TZ:-America/Chicago}" date -d "@$reset" '+%m-%d %H:%M' 2>/dev/null || printf '-')"
  fi
  printf '%s\t%s%%\t%s\n' "$used" "$left" "$reset_text"
}

usage_record_for_profile() {
  local profile_name="$1"
  local profile_file="$2"
  local payload="$3"
  local active_fp="$4"
  local profile_fp="${5:-}"
  local mark=" "

  if [[ -n "$active_fp" ]]; then
    [[ -n "$profile_fp" ]] || profile_fp="$(credential_fingerprint "$profile_file" || true)"
  fi
  if [[ -n "$active_fp" && "$profile_fp" == "$active_fp" ]]; then
    mark="*"
  fi

  if [[ -z "$payload" || "$payload" == "null" ]]; then
    printf '1\t-1\t-1\t%s\t%s\t-\t-\t-\tno data\t5h\t-\t-\t\n' "$mark" "$profile_name"
    return 0
  fi

  local extracted kind err cache_age stale plan short_used short_window short_reset weekly_used weekly_window weekly_reset credits reached
  extracted="$(jq -r "$USAGE_RECORD_EXTRACT_JQ" <<<"$payload" 2>/dev/null || true)"
  IFS=$'\037' read -r kind err cache_age stale plan short_used short_window short_reset weekly_used weekly_window weekly_reset credits reached <<<"$extracted"

  if [[ "$kind" == "error" ]]; then
    if usage_error_requires_login "$err"; then
      err="login"
    elif [[ "$err" == "refresh timeout" || "$err" == "refresh unavailable" || "$err" == "no response" ]]; then
      err="offline"
    fi
    printf '1\t-1\t-1\t%s\t%s\t-\t-\t-\t%s\t5h\t-\t-\t%s\n' "$mark" "$profile_name" "$err" "$cache_age"
    return 0
  fi

  if [[ "$kind" != "usage" ]]; then
    printf '1\t-1\t-1\t%s\t%s\t-\t-\t-\tno usage\t5h\t-\t-\t%s\n' "$mark" "$profile_name" "$cache_age"
    return 0
  fi

  local short weekly status short_label weekly_reset_text short_reset_text stale_age_label
  if [[ ! "$short_window" =~ ^[0-9]+$ || "$short_window" == "0" ]]; then
    short_label="short"
  elif (( short_window % 1440 == 0 )); then
    short_label="$((short_window / 1440))d"
  elif (( short_window >= 60 && short_window % 60 >= 55 )); then
    short_label="$(((short_window + 59) / 60))h"
  elif (( short_window % 60 == 0 )); then
    short_label="$((short_window / 60))h"
  else
    short_label="${short_window}m"
  fi
  IFS=$'\t' read -r short_used short short_reset_text <<<"$(usage_limit_remaining_fields "$short_used" "$short_window" "$short_reset")"
  IFS=$'\t' read -r weekly_used weekly weekly_reset_text <<<"$(usage_limit_remaining_fields "$weekly_used" "$weekly_window" "$weekly_reset")"
  status="ok"
  if (( weekly_used >= 100 && short_used >= 100 )); then
    status="week+5h cap"
  elif (( weekly_used >= 100 )); then
    status="week cap"
  elif (( short_used >= 100 )); then
    status="${short_label} cap"
  elif [[ -n "$reached" ]]; then
    status="$reached"
  fi
  if [[ "$stale" == "true" ]]; then
    stale_age_label="$(format_cache_age "$cache_age")"
    if [[ -n "$stale_age_label" ]]; then
      status="stale $stale_age_label $status"
    else
      status="stale $status"
    fi
  fi

  printf '0\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$weekly_used" "$short_used" "$mark" "$profile_name" "$plan" "$weekly" "$short" "$status" "$short_label" "$weekly_reset_text" "$short_reset_text" "$cache_age"
}

canonical_usage_active_marks() {
  local seen_active=0
  local active_name=""
  local valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age

  active_name="$(resolve_active_profile_for_auth "$AUTH_FILE" || true)"

  while IFS=$'\t' read -r valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age; do
    [[ -n "$profile" ]] || continue
    if [[ -n "$active_name" ]]; then
      [[ "$profile" == "$active_name" ]] && mark="*" || mark=" "
    fi
    if [[ "$mark" == "*" ]]; then
      if (( seen_active )); then
        mark="="
      else
        seen_active=1
      fi
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$valid" "$weekly_used" "$short_used" "$mark" "$profile" "$_plan" "$weekly" "$short" "$status" "$short_label" "$weekly_reset" "$short_reset" "$_cache_age"
  done
}

collect_usage_records_cached_python() {
  local active_fp="$1"
  shift
  local python_output

  command -v python3 >/dev/null 2>&1 || return 1
  python_output="$(
    CODEX_AUTH_ACTIVE_FP="$active_fp" \
    CODEX_AUTH_STATE_FILE="$STATE_FILE" \
    CODEX_AUTH_NOW="$(now_epoch)" \
    python3 - "$@" <<'PY'
import hashlib
import json
import math
import os
import re
import sys
import time

ACTIVE_FP = os.environ.get("CODEX_AUTH_ACTIVE_FP", "")
STATE_FILE = os.environ.get("CODEX_AUTH_STATE_FILE", "")
NOW = int(float(os.environ.get("CODEX_AUTH_NOW") or time.time()))
EMPTY_FP = "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

if "TZ" not in os.environ:
    os.environ["TZ"] = "America/Chicago"
try:
    time.tzset()
except AttributeError:
    pass


def clean_account(value):
    return re.sub(r"\s+", "", str(value or ""))


def fingerprint_secret(secret):
    if not secret:
        return EMPTY_FP
    if re.fullmatch(r"[0-9a-f]{64}", secret):
        return secret
    return hashlib.sha256((secret + "\n").encode()).hexdigest()


def profile_secret(payload):
    if isinstance(payload, dict) and payload.get("OPENAI_API_KEY"):
        return "api:" + str(payload["OPENAI_API_KEY"])
    tokens = payload.get("tokens") if isinstance(payload, dict) else None
    if isinstance(tokens, dict):
        if tokens.get("refresh_token"):
            return "chatgpt:" + str(tokens["refresh_token"])
        if tokens.get("access_token"):
            return "chatgpt-access:" + str(tokens["access_token"])
    return ""


def profile_name(path):
    base = os.path.basename(path)
    return base[:-5] if base.endswith(".json") else base


def nested_error(payload):
    err = payload.get("error") if isinstance(payload, dict) else None
    if isinstance(err, dict):
        data = err.get("data")
        for value in (
            err.get("message"),
            data.get("message") if isinstance(data, dict) else None,
            data.get("error", {}).get("message") if isinstance(data, dict) and isinstance(data.get("error"), dict) else None,
        ):
            if value is not None:
                return normalize_error(value)
    if err is not None:
        return normalize_error(err)
    return "error"


def normalize_error(value):
    text = re.sub(r"[\n\t]+", " ", str(value))
    text = re.sub(r"  +", " ", text).strip()
    return text or "error"


def limit_row(value):
    if not isinstance(value, dict):
        return None
    try:
        used = math.floor(float(value.get("usedPercent", 0) or 0))
    except (TypeError, ValueError):
        used = 0
    window = value.get("windowDurationMins", "-")
    try:
        window_num = int(float(window or 0))
    except (TypeError, ValueError):
        window_num = 0
    return {
        "used": used,
        "window": str(window),
        "window_num": window_num,
        "reset": value.get("resetsAt", "-"),
    }


def remaining_fields(used, window, reset):
    if not window or window == "-" or window == "0":
        return "0", "-", "-"
    left = max(100 - int(used), 0)
    reset_text = "-"
    if reset not in (None, "", "-", "null", "0"):
        try:
            reset_text = time.strftime("%m-%d %H:%M", time.localtime(int(float(reset))))
        except (TypeError, ValueError, OSError):
            reset_text = "-"
    return str(int(used)), f"{left}%", reset_text


def cache_age(entry):
    updated = entry.get("updated_at") if isinstance(entry, dict) else None
    try:
        return str(max(NOW - int(float(updated)), 0))
    except (TypeError, ValueError):
        return ""


def record_for(profile, payload, mark, age):
    if payload is None:
        return ["1", "-1", "-1", mark, profile, "-", "-", "-", "no data", "5h", "-", "-", ""]
    if not isinstance(payload, dict):
        return ["1", "-1", "-1", mark, profile, "-", "-", "-", "no usage", "5h", "-", "-", age]
    if payload.get("error") is not None:
        err = nested_error(payload)
        login_error = err.casefold()
        if any(part in login_error for part in (
            "token has been invalidated",
            "token_invalidated",
            "invalidated oauth token",
            "token_revoked",
            "access token could not be refreshed because you have since logged out or signed in to another account",
            "please sign in again",
        )):
            err = "login"
        elif err in ("refresh timeout", "refresh unavailable", "no response"):
            err = "offline"
        return ["1", "-1", "-1", mark, profile, "-", "-", "-", err, "5h", "-", "-", age]

    rates = None
    by_id = payload.get("rateLimitsByLimitId")
    if isinstance(by_id, dict):
        rates = by_id.get("codex")
    if rates is None:
        rates = payload.get("rateLimits")
    if not isinstance(rates, dict):
        return ["1", "-1", "-1", mark, profile, "-", "-", "-", "no usage", "5h", "-", "-", age]

    limits = []
    for key in ("primary", "secondary"):
        row = limit_row(rates.get(key))
        if row and row["window_num"] > 0:
            limits.append(row)
    limits.sort(key=lambda item: 999999999 if item["window_num"] == 0 else item["window_num"])
    if not limits:
        return ["1", "-1", "-1", mark, profile, "-", "-", "-", "no usage", "5h", "-", "-", age]

    empty = {"used": 0, "window": "-", "window_num": 0, "reset": "-"}
    if len(limits) == 1 and limits[0]["window_num"] >= 1440:
        short_limit = empty
    else:
        short_limit = limits[0]
    if len(limits) == 1 and limits[0]["window_num"] < 1440:
        weekly_limit = empty
    else:
        weekly_limit = limits[-1]

    short_window = short_limit["window"]
    short_window_num = short_limit["window_num"]
    if not short_window_num:
        short_label = "short"
    elif short_window_num % 1440 == 0:
        short_label = f"{short_window_num // 1440}d"
    elif short_window_num >= 60 and short_window_num % 60 >= 55:
        short_label = f"{(short_window_num + 59) // 60}h"
    elif short_window_num % 60 == 0:
        short_label = f"{short_window_num // 60}h"
    else:
        short_label = f"{short_window_num}m"

    short_used, short, short_reset = remaining_fields(short_limit["used"], short_window, short_limit["reset"])
    weekly_used, weekly, weekly_reset = remaining_fields(weekly_limit["used"], weekly_limit["window"], weekly_limit["reset"])

    reached = str(rates.get("rateLimitReachedType") or "")
    status = "ok"
    if int(weekly_used) >= 100 and int(short_used) >= 100:
        status = "week+5h cap"
    elif int(weekly_used) >= 100:
        status = "week cap"
    elif int(short_used) >= 100:
        status = f"{short_label} cap"
    elif reached:
        status = reached
    if payload.get("_codexAuthStale") is True:
        stale_age = format_age(age)
        status = f"stale {stale_age} {status}" if stale_age else f"stale {status}"

    return [
        "0",
        weekly_used,
        short_used,
        mark,
        profile,
        str(rates.get("planType") or "-"),
        weekly,
        short,
        status,
        short_label,
        weekly_reset,
        short_reset,
        age,
    ]


def format_age(seconds):
    try:
        seconds = int(seconds)
    except (TypeError, ValueError):
        return ""
    if seconds < 60:
        return "now"
    if seconds < 3600:
        return f"{max((seconds + 30) // 60, 1)}m"
    if seconds < 86400:
        return f"{max((seconds + 1800) // 3600, 1)}h"
    return f"{max((seconds + 43200) // 86400, 1)}d"


try:
    state = {}
    if STATE_FILE and os.path.exists(STATE_FILE):
        with open(STATE_FILE, "r", encoding="utf-8") as handle:
            state = json.load(handle)
    state_profiles = state.get("profiles") if isinstance(state, dict) else {}
    if not isinstance(state_profiles, dict):
        state_profiles = {}

    rows = []
    for path in sys.argv[1:]:
        name = profile_name(path)
        try:
            with open(path, "r", encoding="utf-8") as handle:
                auth_payload = json.load(handle)
        except (OSError, json.JSONDecodeError):
            fp = ""
        else:
            fp = fingerprint_secret(profile_secret(auth_payload))
        mark = "*" if ACTIVE_FP and fp == ACTIVE_FP else " "
        entry = state_profiles.get(name)
        payload = None
        age = ""
        if isinstance(entry, dict) and entry.get("fingerprint") == fp:
            payload = entry.get("payload")
            age = cache_age(entry)
            if isinstance(payload, dict) and age != "":
                payload = dict(payload)
                payload["_codexAuthAgeSec"] = age
        rows.append(record_for(name, payload, mark, age))

    seen_active = False
    for row in rows:
        if row[3] == "*":
            if seen_active:
                row[3] = "="
            else:
                seen_active = True
        print("\t".join(str(part) for part in row))
except Exception:
    sys.exit(1)
PY
  )" || return 1

  printf '%s\n' "$python_output"
}

collect_usage_records() {
  local active_fp="$1"
  shift
  local profile_files=("$@")
  local records_dir profile_file i record
  local max_jobs="${CODEX_AUTH_REFRESH_JOBS:-4}"
  local max_jobs_cap="${CODEX_AUTH_REFRESH_JOBS_MAX:-4}"
  local active_jobs=0

  [[ "$max_jobs" =~ ^[0-9]+$ && "$max_jobs" -gt 0 ]] || max_jobs=4
  [[ "$max_jobs_cap" =~ ^[0-9]+$ && "$max_jobs_cap" -gt 0 ]] || max_jobs_cap=4
  (( max_jobs > max_jobs_cap )) && max_jobs="$max_jobs_cap"
  (( max_jobs > ${#profile_files[@]} )) && max_jobs="${#profile_files[@]}"
  (( max_jobs < 1 )) && max_jobs=1
  records_dir="$(mktemp -d "$CODEX_HOME/.tmp/auth-records.XXXXXX")"

  for i in "${!profile_files[@]}"; do
    profile_file="${profile_files[$i]}"
    (
      profile_name="$(basename "$profile_file" .json)"
      require_auth_file "$profile_file"
      fingerprint="$(credential_fingerprint "$profile_file" || true)"
      payload="$(usage_payload_for_profile "$profile_file" "$fingerprint")"
      fingerprint="$(credential_fingerprint "$profile_file" || true)"
      usage_record_for_profile "$profile_name" "$profile_file" "$payload" "$active_fp" "$fingerprint" > "$records_dir/$i.record"
    ) &
    active_jobs=$((active_jobs + 1))
    if (( active_jobs >= max_jobs )); then
      wait -n || true
      active_jobs=$((active_jobs - 1))
    fi
  done

  while (( active_jobs > 0 )); do
    wait -n || true
    active_jobs=$((active_jobs - 1))
  done

  for i in "${!profile_files[@]}"; do
    [[ -f "$records_dir/$i.record" ]] && { IFS= read -r record < "$records_dir/$i.record" && printf '%s\n' "$record"; }
  done | canonical_usage_active_marks
  rm -rf "$records_dir" 2>/dev/null || true
}

collect_usage_records_cached() {
  local active_fp="$1"
  shift
  local profile_files=("$@")
  local map_file profile_file profile_name meta_path mode hint secret fp payload now
  local -A profile_fp=()
  local -A payload_by_path=()

  if [[ -z "$active_fp" && ! -f "$STATE_FILE" ]]; then
    for profile_file in "${profile_files[@]}"; do
      profile_name="${profile_file##*/}"
      profile_name="${profile_name%.json}"
      usage_record_for_profile "$profile_name" "$profile_file" "null" "" ""
    done | canonical_usage_active_marks
    return 0
  fi

  if [[ "${CODEX_AUTH_FAST_CACHED_PYTHON:-1}" != "0" ]]; then
    collect_usage_records_cached_python "$active_fp" "${profile_files[@]}" && return 0
  fi

  map_file="$(mktemp "$CODEX_HOME/.tmp/auth-cache-map.XXXXXX")"

  while IFS=$'\037' read -r meta_path mode hint secret; do
    [[ -n "$meta_path" ]] || continue
    fp="$(auth_record_fingerprint "$secret")"
    profile_name="$(basename "$meta_path" .json)"
    profile_fp["$meta_path"]="$fp"
    printf '%s\037%s\037%s\n' "$meta_path" "$profile_name" "$fp" >> "$map_file"
  done < <(auth_metadata_records "${profile_files[@]}")

  if [[ -f "$STATE_FILE" && -s "$map_file" ]]; then
    now="$(now_epoch)"
    while IFS=$'\037' read -r meta_path profile_name payload; do
      [[ -n "$meta_path" ]] || continue
      payload_by_path["$meta_path"]="$payload"
    done < <(
      jq -r --rawfile requested "$map_file" --argjson now "$now" '
        . as $state
        | $requested
        | split("\n")[]
        | select(length > 0)
        | split("\u001f") as $item
        | {
            path: ($item[0] // ""),
            name: ($item[1] // ""),
            fp: ($item[2] // "")
          } as $req
        | ($state.profiles[$req.name] // null) as $profile
        | select($profile != null and $profile.fingerprint == $req.fp)
        | [
            $req.path,
            $req.name,
            (($profile.payload + {
              _codexAuthAgeSec: (if $profile.updated_at == null
                then null
                else ($now - ($profile.updated_at | tonumber))
              end)
            }) | @json)
          ]
        | join("\u001f")
      ' "$STATE_FILE" 2>/dev/null
    )
  fi

  for profile_file in "${profile_files[@]}"; do
    profile_name="$(basename "$profile_file" .json)"
    fp="${profile_fp["$profile_file"]:-}"
    payload="${payload_by_path["$profile_file"]:-null}"
    usage_record_for_profile "$profile_name" "$profile_file" "$payload" "$active_fp" "$fp"
  done | canonical_usage_active_marks

  rm -f "$map_file" 2>/dev/null || true
}

collect_usage_records_synced() {
  local active_fp="$1"
  shift
  local profile_files=("$@")
  local records=""
  local profile_file profile_name fingerprint payload fallback_payload
  local probe_fingerprint_file probe_fingerprint

  for profile_file in "${profile_files[@]}"; do
    require_auth_file "$profile_file"
    profile_name="$(basename "$profile_file" .json)"
    fingerprint="$(credential_fingerprint "$profile_file" || true)"

    payload=""
    if [[ "${CODEX_AUTH_REFRESH_BLOCKED:-0}" == "1" && -n "$fingerprint" ]]; then
      payload="$(state_payload_for_profile "$profile_name" "$fingerprint" || true)"
      if [[ -z "$payload" ]] || ! usage_payload_still_blocked "$payload"; then
        payload=""
      fi
    fi

    if [[ -z "$payload" ]]; then
      probe_fingerprint=""
      probe_fingerprint_file="$(mktemp "$CODEX_HOME/.tmp/auth-probe-fingerprint.XXXXXX")"
      payload="$(usage_json_for_profile "$profile_file" "$probe_fingerprint_file")"
      if [[ -s "$probe_fingerprint_file" ]]; then
        IFS= read -r probe_fingerprint < "$probe_fingerprint_file" || true
      fi
      rm -f "$probe_fingerprint_file"
      if [[ -n "$payload" && "$payload" != "null" ]] && usage_payload_transient_error "$payload"; then
        payload=""
      fi
      if [[ -z "$payload" || "$payload" == "null" ]]; then
        fallback_payload=""
        [[ -n "$fingerprint" ]] && fallback_payload="$(state_payload_for_profile "$profile_name" "$fingerprint" || true)"
        if [[ -n "$fallback_payload" && "${CODEX_AUTH_REFRESH_FALLBACK_CACHE:-1}" == "1" ]]; then
          payload="$(mark_stale_payload "$fallback_payload")"
        else
          payload='{"error":{"message":"no response"}}'
        fi
      elif [[ -n "$probe_fingerprint" ]]; then
        state_update_profile "$profile_name" "$probe_fingerprint" "$payload"
      fi
    fi

    fingerprint="$(credential_fingerprint "$profile_file" || true)"
    records+="$(usage_record_for_profile "$profile_name" "$profile_file" "$payload" "$active_fp" "$fingerprint")"$'\n'
  done

  printf '%s' "$records" | canonical_usage_active_marks
}

usage_limit_sort_fields() {
  local coverage_rank short_score week_score

  usage_limit_sort_fields_into coverage_rank short_score week_score "$@"
  printf '%s\t%s\t%s\n' "$coverage_rank" "$short_score" "$week_score"
}

usage_limit_sort_fields_into() {
  local -n coverage_rank_ref="$1"
  local -n short_score_ref="$2"
  local -n week_score_ref="$3"
  shift 3
  local weekly="$1"
  local short="$2"
  local weekly_used="$3"
  local short_used="$4"
  local coverage_value=9 short_value=101 week_value=101

  if [[ -n "$weekly" && "$weekly" != "-" && -n "$short" && "$short" != "-" ]]; then
    coverage_value=0
  elif [[ -n "$short" && "$short" != "-" ]]; then
    coverage_value=1
  elif [[ -n "$weekly" && "$weekly" != "-" ]]; then
    coverage_value=2
  fi
  [[ -n "$short" && "$short" != "-" && "$short_used" =~ ^[0-9]+$ ]] && short_value="$short_used"
  [[ -n "$weekly" && "$weekly" != "-" && "$weekly_used" =~ ^[0-9]+$ ]] && week_value="$weekly_used"
  coverage_rank_ref="$coverage_value"
  short_score_ref="$short_value"
  week_score_ref="$week_value"
}

prepare_usage_records() {
  local records="$1"
  local default_profile="${2:-}"
  local sorted_records=()
  local record valid weekly_used short_used mark profile plan weekly short status record_short_label weekly_reset short_reset cache_age
  local rank coverage_rank short_score week_score drop_i

  mapfile -t sorted_records < <(
    printf '%s\n' "$records" \
      | while IFS= read -r record; do
          [[ "$record" =~ [^[:space:]] ]] || continue
          IFS=$'\t' read -r valid weekly_used short_used mark profile plan weekly short status record_short_label weekly_reset short_reset cache_age <<<"$record"
          case "$status" in
            offline) rank=7 ;;
            login) rank=8 ;;
            *)
              if [[ "$valid" != "0" ]]; then
                rank=9
              elif [[ "$status" == "ok" ]]; then
                if [[ -n "$default_profile" && "$profile" == "$default_profile" ]]; then
                  rank=0
                else
                  case "$mark" in
                    '*') rank=1 ;;
                    '=') rank=4 ;;
                    *) rank=2 ;;
                  esac
                fi
              else
                case "$status:$mark" in
                  stale*) rank=3 ;;
                  *:'*') rank=4 ;;
                  *cap*:*) rank=5 ;;
                  *) rank=6 ;;
                esac
              fi
              ;;
          esac
          usage_limit_sort_fields_into coverage_rank short_score week_score "$weekly" "$short" "$weekly_used" "$short_used"
          printf '%s\t%s\t%03d\t%03d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$rank" "$coverage_rank" "$short_score" "$week_score" "$profile" \
            "$valid" "$weekly_used" "$short_used" "$mark" "$profile" "$plan" "$weekly" "$short" "$status" "$record_short_label" "$weekly_reset" "$short_reset" "$cache_age"
        done \
      | sort -t $'\t' -k1,1n -k2,2n -k3,3n -k4,4n -k5,5 \
      | while IFS= read -r record; do
          for ((drop_i = 0; drop_i < 5; drop_i++)); do record="${record#*$'\t'}"; done
          printf '%s\n' "$record"
        done
  )

  USAGE_SHORT_LABEL="5h"
  USAGE_PROFILE_WIDTH_HINT=12
  for record in "${sorted_records[@]}"; do
    IFS=$'\t' read -r _valid _weekly_used _short_used _mark profile _plan _weekly _short _status record_short_label _weekly_reset _short_reset _cache_age <<<"$record"
    if (( ${#profile} > USAGE_PROFILE_WIDTH_HINT )); then
      USAGE_PROFILE_WIDTH_HINT="${#profile}"
    fi
    if [[ -n "$record_short_label" && "$record_short_label" != "short" && "$record_short_label" != "5h" ]]; then
      USAGE_SHORT_LABEL="$record_short_label"
    fi
  done
  SORTED_USAGE_RECORDS=("${sorted_records[@]}")
}

render_usage_records() {
  local records="$1"
  local default_profile="$2"

  prepare_usage_records "$records" "$default_profile"

  local mode role_w profile_w cell_w status_w bar_width
  local display_role display_status total_w group previous_group=""
  local render_cols max_cols header_role
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1
  max_cols=$((120 + USAGE_VERBOSE * 12))
  render_cols="$(clamp_int_between "$(terminal_width)" 0 "$max_cols")"
  IFS=$'\t' read -r mode role_w profile_w cell_w status_w bar_width <<<"$(usage_render_widths "$render_cols")"
  total_w=$((role_w + 1 + (role_w > 1) + profile_w + 1 + cell_w + 1 + cell_w))
  (( status_w > 0 )) && total_w=$((total_w + 1 + (role_w > 1) + status_w))

  print_palette_summary_header "Codex profiles" "$(usage_metadata_summary_line "$total_w" "$default_profile" "${SORTED_USAGE_RECORDS[@]}")" "$total_w" usage 0
  if [[ "${CODEX_AUTH_USAGE_HEADER:-0}" == "1" ]]; then
    header_role="act"
    (( role_w <= 1 )) && header_role=""
    print_usage_render_header "$header_role" "$role_w" "$profile_w" "$cell_w" "$status_w" "$mode"
  fi

  for record in "${SORTED_USAGE_RECORDS[@]}"; do
    IFS=$'\t' read -r valid weekly_used short_used mark profile plan weekly short status record_short_label weekly_reset short_reset cache_age <<<"$record"
    if [[ "$status" == "offline" ]]; then
      group="offline"
    elif [[ "$status" == "login" ]]; then
      group="login"
    elif [[ "$valid" != "0" || "$status" == "no data" || "$status" == "no usage" ]]; then
      group="unavailable"
    elif [[ "$status" == stale* ]]; then
      group="stale"
    elif [[ "$status" == "ok" ]]; then
      group="ready"
    else
      group="limited"
    fi
    if [[ -z "$previous_group" ]]; then
      if [[ "$group" != "ready" && "$group" != "limited" ]]; then
        print_usage_section_rule "$total_w" "$group"
      fi
    elif [[ "$group" != "$previous_group" && "$group" != "ready" && "$group" != "limited" ]]; then
      print_usage_section_rule "$total_w" "$group"
    fi
    previous_group="$group"

    display_role=""
    if [[ "$mark" == "*" ]]; then
      display_role="stay"
    elif [[ "$mark" == "=" ]]; then
      display_role="same"
    elif [[ -n "$default_profile" && "$profile" == "$default_profile" ]]; then
      display_role="use"
    elif [[ "$status" == *cap* ]]; then
      display_role="cap"
    elif [[ "$status" == "login" ]]; then
      display_role="login"
    elif [[ "$valid" == "0" && "$status" == "ok" ]]; then
      display_role="use"
    fi
    if (( role_w <= 1 )); then
      [[ "$display_role" == "same" ]] && display_role="alias"
      display_role="${display_role:0:1}"
    fi
    display_status="$(usage_display_status "$status" "$mode")"
    print_usage_render_data_line "$display_role" "$profile" "$weekly" "$weekly_reset" "$short" "$short_reset" \
      "$display_status" "$status" "$valid" "$weekly_used" "$short_used" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width" "$mode"
  done
}

profile_files_for_args_into() {
  local -n profile_files_ref="$1"
  local quiet_missing="$2"
  shift 2
  local name profile_file

  profile_files_ref=()
  if (( $# > 0 )); then
    for name in "$@"; do
      require_name "$name"
      profile_file="$(profile_path "$name")"
      if [[ ! -f "$profile_file" ]]; then
        [[ "$quiet_missing" == "1" && "$USAGE_QUIET" == "1" ]] && return 1
        die "profile not found: $name"
      fi
      profile_files_ref+=("$profile_file")
    done
  else
    shopt -s nullglob
    profile_files_ref=("$PROFILE_DIR"/*.json)
    shopt -u nullglob
  fi
}

active_auth_fingerprint() {
  [[ -f "$AUTH_FILE" ]] || return 0
  credential_fingerprint "$AUTH_FILE" || true
}

acquire_refresh_lock_into() {
  local -n fd_ref="$1"
  local mode="${2:-wait}" refresh_lock_wait

  exec {fd_ref}>"$CODEX_HOME/.tmp/codex-auth-refresh.lock"
  [[ "$mode" == "try" ]] && { flock -n "$fd_ref"; return $?; }
  refresh_lock_wait="${CODEX_AUTH_REFRESH_LOCK_WAIT:-1}"
  [[ "$refresh_lock_wait" =~ ^[0-9]+$ ]] || refresh_lock_wait=1
  flock -w "$refresh_lock_wait" "$fd_ref"
}

start_usage_background_refresh() {
  local profile_file profile_name script background_jobs
  local profile_names=()

  (( $# > 0 )) || return 0
  for profile_file in "$@"; do
    profile_name="$(basename "$profile_file" .json)"
    [[ -n "$profile_name" ]] && profile_names+=("$profile_name")
  done
  (( ${#profile_names[@]} > 0 )) || return 0

  script="$CODEX_AUTH_SELF"
  background_jobs="${CODEX_AUTH_BACKGROUND_REFRESH_JOBS:-1}"
  [[ "$background_jobs" =~ ^[0-9]+$ && "$background_jobs" -gt 0 ]] || background_jobs=1
  nohup env CODEX_AUTH_REFRESH_LOCK=try CODEX_AUTH_NO_BACKGROUND=1 CODEX_AUTH_REFRESH_BLOCKED=1 CODEX_AUTH_REFRESH_FALLBACK_CACHE=1 CODEX_AUTH_REFRESH_JOBS="$background_jobs" "$script" refresh --quiet --fast "${profile_names[@]}" >/dev/null 2>&1 &
}

usage_best_selection_into() {
  local records="$1"
  local -n default_profile_ref="$2"
  local -n active_is_best_ref="$3"
  local best_week=101
  local best_short=101
  local best_coverage=99
  local best_profile=""
  local best_mark=""
  local valid weekly_used short_used mark profile _plan weekly short status _rest
  local coverage_rank short_score week_score

  default_profile_ref=""
  active_is_best_ref=0
  while IFS=$'\t' read -r valid weekly_used short_used mark profile _plan weekly short status _rest; do
    [[ -n "$profile" ]] || continue
    [[ "$valid" == "0" && "$status" == "ok" ]] || continue
    (( weekly_used < 100 && short_used < 100 )) || continue
    usage_limit_sort_fields_into coverage_rank short_score week_score "$weekly" "$short" "$weekly_used" "$short_used"
    (( coverage_rank < 9 )) || continue
    if (( coverage_rank < best_coverage )) \
      || (( coverage_rank == best_coverage && short_score < best_short )) \
      || (( coverage_rank == best_coverage && short_score == best_short && week_score < best_week )) \
      || [[ "$mark" == "*" && "$best_mark" != "*" && "$coverage_rank" == "$best_coverage" && "$short_score" == "$best_short" && "$week_score" == "$best_week" ]]; then
      best_profile="$profile"
      best_mark="$mark"
      best_coverage="$coverage_rank"
      best_week="$week_score"
      best_short="$short_score"
    fi
  done <<<"$records"

  if [[ -n "$best_profile" ]]; then
    if [[ "$best_mark" == "*" ]]; then
      active_is_best_ref=1
    else
      default_profile_ref="$best_profile"
    fi
  fi
}

cmd_usage() {
  ensure_dirs
  command -v jq >/dev/null 2>&1 || die "jq is required for usage output"
  sync_active_profile_from_live

  local auto_switch=0
  local usage_sync_refresh=0
  local args=()
  local refresh_lock_held=0
  local refresh_lock_fd=""
  USAGE_QUIET=0
  USAGE_CACHED=0
  USAGE_REFRESH=0
  USAGE_SELECT=0
  USAGE_FAST_REFRESH=1
  while (( $# > 0 )); do
    case "$1" in
      --auto)
        auto_switch=1
        shift
        ;;
      --cached)
        USAGE_CACHED=1
        shift
        ;;
      --refresh)
        USAGE_REFRESH=1
        shift
        ;;
      --fast)
        USAGE_FAST_REFRESH=1
        shift
        ;;
      --sync)
        usage_sync_refresh=1
        USAGE_REFRESH=1
        USAGE_FAST_REFRESH=1
        shift
        ;;
      --help|-h)
        source_codex_auth_libs help.sh
        usage
        return 0
        ;;
      --quiet|-q)
        USAGE_QUIET=1
        shift
        ;;
      --verbose|-v)
        USAGE_VERBOSE=1
        shift
        ;;
      --select|--menu)
        USAGE_SELECT=1
        shift
        ;;
      --ttl)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || die "usage: --ttl seconds"
        CACHE_TTL="$2"
        shift 2
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      -*)
        die "unknown usage option: $1"
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${args[@]}"

  if [[ "$usage_sync_refresh" == "1" && "$auto_switch" != "1" && "$USAGE_QUIET" != "1" ]]; then
    USAGE_SELECT=1
  fi

  local profile_files=()
  profile_files_for_args_into profile_files 0 "$@" || return 0
  if (( ${#profile_files[@]} == 0 )); then
    [[ "$USAGE_QUIET" == "1" ]] || print_empty_profiles
    return 0
  fi
  if [[ "$usage_sync_refresh" == "1" && "$USAGE_REFRESH" == "1" ]]; then
    local sync_jobs="${CODEX_AUTH_SYNC_REFRESH_JOBS:-${#profile_files[@]}}"
    [[ "$sync_jobs" =~ ^[0-9]+$ && "$sync_jobs" -gt 0 ]] || sync_jobs="${#profile_files[@]}"
    (( sync_jobs > 12 )) && sync_jobs=12
    export CODEX_AUTH_REFRESH_JOBS="${CODEX_AUTH_REFRESH_JOBS:-$sync_jobs}"
    export CODEX_AUTH_REFRESH_JOBS_MAX="${CODEX_AUTH_REFRESH_JOBS_MAX:-${CODEX_AUTH_SYNC_REFRESH_JOBS_MAX:-$sync_jobs}}"
  fi
  if [[ "$USAGE_SELECT" == "1" && "$USAGE_REFRESH" == "1" && "$USAGE_FAST_REFRESH" == "1" ]] \
    && selector_prompt_available \
    && [[ "${CODEX_AUTH_SELECT_BACKGROUND_REFRESH:-1}" == "1" ]] \
    && [[ "$usage_sync_refresh" != "1" ]] \
    && [[ "${CODEX_AUTH_SELECT_SYNC_REFRESH:-0}" != "1" ]]; then
    start_usage_background_refresh "${profile_files[@]}"
    USAGE_REFRESH=0
    USAGE_CACHED=1
  fi
  if [[ "$USAGE_REFRESH" == "1" && "$USAGE_QUIET" != "1" && -t 2 ]]; then
    print_status_note refresh "${#profile_files[@]} profiles" >&2
  fi
  if [[ "$USAGE_REFRESH" == "1" ]]; then
    if ! acquire_refresh_lock_into refresh_lock_fd; then
      [[ "$USAGE_QUIET" == "1" ]] || print_status_note cache "refresh busy" >&2
      USAGE_REFRESH=0
      USAGE_CACHED=1
    else
      refresh_lock_held=1
    fi
  fi

  while true; do
    local active_fp
    active_fp="$(active_auth_fingerprint)"

    local records=""
    if [[ "$USAGE_CACHED" == "1" && "$USAGE_REFRESH" != "1" ]]; then
      records="$(collect_usage_records_cached "$active_fp" "${profile_files[@]}")"
    elif [[ "$USAGE_REFRESH" == "1" && "$USAGE_FAST_REFRESH" != "1" ]]; then
      records="$(collect_usage_records_synced "$active_fp" "${profile_files[@]}")"
    else
      records="$(collect_usage_records "$active_fp" "${profile_files[@]}")"
    fi
    if (( refresh_lock_held )); then
      flock -u "$refresh_lock_fd" 2>/dev/null || true; exec {refresh_lock_fd}>&- 2>/dev/null || true
      refresh_lock_held=0
    fi

    local default_profile active_is_best
    usage_best_selection_into "$records" default_profile active_is_best

    if [[ "$USAGE_SELECT" == "1" ]]; then
      if selector_prompt_available; then
        prepare_usage_records "$records" "$default_profile"
      elif [[ "$USAGE_QUIET" != "1" ]]; then
        render_usage_records "$records" "$default_profile"
      fi
    elif [[ "$USAGE_QUIET" != "1" ]]; then
      render_usage_records "$records" "$default_profile"
    fi

    case "$auto_switch:$USAGE_SELECT" in
      1:*)
        [[ "$USAGE_SELECT" == "1" || "$USAGE_QUIET" == "1" ]] || printf '\n'
        if [[ -n "$default_profile" ]]; then
          source_codex_auth_libs profiles.sh
          cmd_use "$default_profile"
        elif [[ "$active_is_best" == "1" && "$USAGE_QUIET" != "1" ]]; then
          print_status_note ready "already on best profile"
        elif [[ "$USAGE_QUIET" != "1" ]]; then
          print_status_note blocked "no ready profile"
        fi
        return 0
        ;;
      0:1)
        source_codex_auth_libs selector.sh
        arrow_action_menu "$default_profile" "${SORTED_USAGE_RECORDS[@]}"
        case "$MENU_ACTION" in
          login)
            local refreshed_profile="$MENU_PROFILE"
            local refreshed_profile_file refreshed_fingerprint refreshed_payload
            source_codex_auth_libs profiles.sh
            cmd_login "$refreshed_profile"
            printf '\n'
            print_status_note refresh "$refreshed_profile"
            refreshed_profile_file="$(profile_path "$refreshed_profile")"
            require_auth_file "$refreshed_profile_file"
            refreshed_fingerprint="$(credential_fingerprint "$refreshed_profile_file" || true)"
            refreshed_payload="$(usage_json_from_home "$CODEX_HOME")"
            if [[ -n "$refreshed_payload" && "$refreshed_payload" != "null" && -n "$refreshed_fingerprint" ]] \
              && ! usage_payload_transient_error "$refreshed_payload" \
              && ! jq -e '.error? != null' >/dev/null 2>&1 <<<"$refreshed_payload"; then
              state_update_profile "$refreshed_profile" "$refreshed_fingerprint" "$refreshed_payload"
            fi
            USAGE_REFRESH=0
            USAGE_CACHED=1
            ;;
          blocked)
            print_status_note blocked "choose switch/login/skip"
            return 0
            ;;
          switch)
            source_codex_auth_libs profiles.sh
            cmd_use "$MENU_PROFILE"
            return 0
            ;;
          skip|*)
            return 0
            ;;
        esac
        ;;
      *) return 0 ;;
    esac
  done
}

cmd_refresh() {
  ensure_dirs
  command -v jq >/dev/null 2>&1 || die "jq is required for usage refresh"
  sync_active_profile_from_live

  USAGE_QUIET=0
  USAGE_CACHED=0
  USAGE_REFRESH=1
  USAGE_FAST_REFRESH=1

  local args=()
  while (( $# > 0 )); do
    case "$1" in
      --quiet|-q)
        USAGE_QUIET=1
        shift
        ;;
      --fast)
        USAGE_FAST_REFRESH=1
        shift
        ;;
      --sync)
        USAGE_FAST_REFRESH=0
        shift
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${args[@]}"

  local refresh_lock_fd=""
  if ! acquire_refresh_lock_into refresh_lock_fd "${CODEX_AUTH_REFRESH_LOCK:-wait}"; then
    if [[ "${CODEX_AUTH_REFRESH_LOCK:-}" != "try" && "$USAGE_QUIET" != "1" ]]; then
      print_status_note cache "refresh busy" >&2
    fi
    return 0
  fi

  local profile_files=()
  profile_files_for_args_into profile_files 0 "$@"

  if (( ${#profile_files[@]} == 0 )); then
    [[ "$USAGE_QUIET" == "1" ]] || print_empty_profiles
    return 0
  fi
  if [[ "$USAGE_QUIET" != "1" && -t 2 ]]; then
    print_status_note refresh "${#profile_files[@]} profiles" >&2
  fi

  local active_fp
  active_fp="$(active_auth_fingerprint)"

  local records default_profile active_is_best
  if [[ "$USAGE_FAST_REFRESH" == "1" ]]; then
    records="$(collect_usage_records "$active_fp" "${profile_files[@]}")"
  else
    records="$(collect_usage_records_synced "$active_fp" "${profile_files[@]}")"
  fi
  usage_best_selection_into "$records" default_profile active_is_best

  [[ "$USAGE_QUIET" == "1" ]] || render_usage_records "$records" "$default_profile"
}

cmd_auto() {
  ensure_dirs
  command -v jq >/dev/null 2>&1 || return 0
  sync_active_profile_from_live

  USAGE_QUIET=0
  USAGE_CACHED=1
  USAGE_REFRESH=0
  USAGE_BACKGROUND=1

  local args=()
  while (( $# > 0 )); do
    case "$1" in
      --quiet|-q)
        USAGE_QUIET=1
        shift
        ;;
      --ttl)
        [[ "${2:-}" =~ ^[0-9]+$ ]] || return 0
        CACHE_TTL="$2"
        USAGE_CACHED=0
        shift 2
        ;;
      --no-background)
        USAGE_BACKGROUND=0
        shift
        ;;
      --)
        shift
        args+=("$@")
        break
        ;;
      *)
        args+=("$1")
        shift
        ;;
    esac
  done
  set -- "${args[@]}"

  local profile_files=()
  profile_files_for_args_into profile_files 1 "$@" || return 0
  (( ${#profile_files[@]} > 0 )) || return 0

  local active_fp
  active_fp="$(active_auth_fingerprint)"

  local records default_profile active_is_best
  if [[ "$USAGE_CACHED" == "1" ]]; then
    records="$(collect_usage_records_cached "$active_fp" "${profile_files[@]}")"
  else
    records="$(collect_usage_records "$active_fp" "${profile_files[@]}")"
  fi
  usage_best_selection_into "$records" default_profile active_is_best

  if [[ "$USAGE_QUIET" != "1" ]]; then
    render_usage_records "$records" "$default_profile"
  fi

  if [[ -n "$default_profile" ]]; then
    if [[ "$USAGE_QUIET" == "1" ]]; then
      cmd_use "$default_profile" >/dev/null
    else
      printf '\n'
      cmd_use "$default_profile"
    fi
  elif [[ "$USAGE_QUIET" != "1" ]]; then
    printf '\n'
    if [[ "$active_is_best" == "1" ]]; then
      print_status_note ready "already on best profile"
    else
      print_status_note blocked "no ready profile"
    fi
  fi

  if (( ! USAGE_BACKGROUND )) || [[ "${CODEX_AUTH_NO_BACKGROUND:-}" == "1" ]]; then
    return 0
  fi

  local stale_names=()
  local profile_file profile_name fingerprint payload age
  for profile_file in "${profile_files[@]}"; do
    profile_name="$(basename "$profile_file" .json)"
    fingerprint="$(credential_fingerprint "$profile_file" || true)"
    payload=""
    [[ -n "$fingerprint" ]] && payload="$(state_payload_for_profile "$profile_name" "$fingerprint" || true)"
    age="999999999"
    [[ -n "$payload" ]] && age="$(jq -r '._codexAuthAgeSec // 999999999' <<<"$payload" 2>/dev/null || printf '999999999\n')"
    if [[ -z "$payload" || ! "$age" =~ ^[0-9]+$ || "$age" -gt "$CACHE_TTL" ]]; then
      stale_names+=("$profile_name")
    fi
  done
  if (( ${#stale_names[@]} > 0 )); then
    local script="$CODEX_AUTH_SELF"
    local background_jobs="${CODEX_AUTH_BACKGROUND_REFRESH_JOBS:-1}"
    [[ "$background_jobs" =~ ^[0-9]+$ && "$background_jobs" -gt 0 ]] || background_jobs=1
    nohup env CODEX_AUTH_REFRESH_LOCK=try CODEX_AUTH_NO_BACKGROUND=1 CODEX_AUTH_REFRESH_BLOCKED=1 CODEX_AUTH_REFRESH_FALLBACK_CACHE=1 CODEX_AUTH_REFRESH_JOBS="$background_jobs" "$script" refresh --quiet --fast "${stale_names[@]}" >/dev/null 2>&1 &
  fi
}
