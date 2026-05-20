# shellcheck shell=bash

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
  local updated tmp source

  updated="$(now_epoch)"
  if ! jq -e . >/dev/null 2>&1 <<<"$payload"; then
    payload='{"error":{"message":"invalid usage payload"}}'
  fi

  tmp="$(mktemp "$CODEX_HOME/.tmp/auth-state.XXXXXX")"
  if [[ -f "$STATE_FILE" ]] && jq -e . "$STATE_FILE" >/dev/null 2>&1; then
    source="$STATE_FILE"
  else
    source="/dev/null"
  fi

  {
    flock -x 9
    if [[ "$source" == "/dev/null" ]]; then
      printf '{}\n'
    else
      cat "$source"
    fi | jq -c \
      --arg name "$profile_name" \
      --arg fp "$fingerprint" \
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

usage_payload_still_blocked() {
  local payload="$1"
  local now

  now="$(now_epoch)"
  jq -e --argjson now "$now" '
    if .error? != null then
      ((.error.message // .error.data.message // .error.data.error.message // .error // "")
        | tostring
        | test("token has been invalidated|token_invalidated|invalidated oauth token|token_revoked"; "i"))
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

usage_payload_for_profile() {
  local profile_file="$1"
  local fingerprint="$2"
  local profile_name payload cached_payload age

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

  payload="$(usage_json_for_profile "$profile_file")"

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

  if [[ -n "$fingerprint" ]] && ! jq -e '.error? != null' >/dev/null 2>&1 <<<"$payload"; then
    state_update_profile "$profile_name" "$fingerprint" "$payload"
  fi
  printf '%s\n' "$payload"
}

usage_json_for_profile() (
  local profile_file="$1"
  local temp_home payload

  temp_home="$(mktemp -d "$CODEX_HOME/.tmp/auth-usage.XXXXXX")"
  trap '[[ -z "${temp_home:-}" ]] || rm -rf "$temp_home" 2>/dev/null || true' EXIT HUP INT TERM
  copy_auth_file_atomic "$profile_file" "$temp_home/auth.json"

  payload="$(usage_json_from_home "$temp_home")"
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
  timeout_sec="${CODEX_AUTH_USAGE_TIMEOUT:-4}"
  [[ "$timeout_sec" =~ ^[0-9]+$ && "$timeout_sec" -gt 0 ]] || timeout_sec=4

  if ! coproc CODEX_RATE { CODEX_AUTH_RUNNER=1 CODEX_HOME="$home_dir" "$codex_cli" app-server --listen stdio:// 2>/dev/null; }; then
    printf '%s\n' '{"error":{"message":"refresh unavailable"}}'
    return 0
  fi

  rate_out="${CODEX_RATE[0]}"
  rate_in="${CODEX_RATE[1]}"
  rate_pid="$CODEX_RATE_PID"
  start="$(now_epoch)"

  if ! printf '%s\n' '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"codex-auth","title":"Codex Auth","version":"0.1.0"},"capabilities":{"experimentalApi":true,"requestAttestation":false}}}' 2>/dev/null >&"$rate_in"; then
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
        printf '%s\n' '{"method":"initialized"}' 2>/dev/null >&"$rate_in" || true
        printf '%s\n' '{"id":2,"method":"account/rateLimits/read"}' 2>/dev/null >&"$rate_in" || true
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
    if [[ "$err" == *"token has been invalidated"* || "$err" == *"token_invalidated"* || "$err" == *"invalidated oauth token"* || "$err" == *"token_revoked"* ]]; then
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
  local valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age

  while IFS=$'\t' read -r valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age; do
    [[ -n "$profile" ]] || continue
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
      payload="$(usage_json_for_profile "$profile_file")"
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
      elif [[ -n "$fingerprint" ]]; then
        state_update_profile "$profile_name" "$fingerprint" "$payload"
      fi
    fi

    records+="$(usage_record_for_profile "$profile_name" "$profile_file" "$payload" "$active_fp" "$fingerprint")"$'\n'
  done

  printf '%s' "$records" | canonical_usage_active_marks
}

usage_limit_sort_fields() {
  local weekly="$1"
  local short="$2"
  local weekly_used="$3"
  local short_used="$4"
  local coverage_rank=9 short_score=101 week_score=101

  if [[ -n "$weekly" && "$weekly" != "-" && -n "$short" && "$short" != "-" ]]; then
    coverage_rank=0
  elif [[ -n "$short" && "$short" != "-" ]]; then
    coverage_rank=1
  elif [[ -n "$weekly" && "$weekly" != "-" ]]; then
    coverage_rank=2
  fi
  [[ -n "$short" && "$short" != "-" && "$short_used" =~ ^[0-9]+$ ]] && short_score="$short_used"
  [[ -n "$weekly" && "$weekly" != "-" && "$weekly_used" =~ ^[0-9]+$ ]] && week_score="$weekly_used"
  printf '%s\t%s\t%s\n' "$coverage_rank" "$short_score" "$week_score"
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
          IFS=$'\t' read -r coverage_rank short_score week_score <<<"$(usage_limit_sort_fields "$weekly" "$short" "$weekly_used" "$short_used")"
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

normalize_codex_status_text() {
  local text="$1" line normalized=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "WARNING: proceeding, even though we could not update PATH:"* ]] && continue
    line="${line//$'\t'/ }"
    normalized+=" $line"
  done <<<"$text"
  while [[ "$normalized" == *"  "* ]]; do normalized="${normalized//  / }"; done
  while [[ "$normalized" == " "* ]]; do normalized="${normalized# }"; done
  while [[ "$normalized" == *" " ]]; do normalized="${normalized% }"; done
  printf '%s\n' "$normalized"
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
    IFS=$'\t' read -r coverage_rank short_score week_score <<<"$(usage_limit_sort_fields "$weekly" "$short" "$weekly_used" "$short_used")"
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

  local auto_switch=0
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
        USAGE_FAST_REFRESH=0
        shift
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

  local profile_files=()
  profile_files_for_args_into profile_files 0 "$@" || return 0
  if (( ${#profile_files[@]} == 0 )); then
    [[ "$USAGE_QUIET" == "1" ]] || print_empty_profiles
    return 0
  fi
  if [[ "$USAGE_SELECT" == "1" && "$USAGE_REFRESH" == "1" && "$USAGE_FAST_REFRESH" == "1" ]] \
    && selector_prompt_available \
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
          cmd_use "$default_profile"
        elif [[ "$active_is_best" == "1" && "$USAGE_QUIET" != "1" ]]; then
          print_status_note ready "already on best profile"
        elif [[ "$USAGE_QUIET" != "1" ]]; then
          print_status_note blocked "no ready profile"
        fi
        return 0
        ;;
      0:1)
        arrow_action_menu "$default_profile" "${SORTED_USAGE_RECORDS[@]}"
        case "$MENU_ACTION" in
          login)
            local refreshed_profile="$MENU_PROFILE"
            local refreshed_profile_file refreshed_fingerprint refreshed_payload
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

PATCH_CODEX_PATCH_VERSION=1

