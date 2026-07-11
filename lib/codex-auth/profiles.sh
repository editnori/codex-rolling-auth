# shellcheck shell=bash

resolve_active_profile_for_auth() {
  local auth_path="$1"
  local live_fp live_kind live_identity marker_name marker_kind marker_identity marker_fp marker_revision
  local path name profile_fp profile_kind profile_identity profile_revision matched="" identity_match="" identity_count=0

  auth_file_is_valid "$auth_path" || return 1
  live_fp="$(credential_fingerprint "$auth_path" || true)"
  live_kind="$(auth_file_kind "$auth_path" || true)"
  live_identity="$(auth_file_account_identity "$auth_path" || true)"

  marker_name="$(active_profile_marker_read || true)"
  if [[ -n "$marker_name" ]]; then
    path="$(profile_path "$marker_name")"
    marker_fp="$(active_profile_marker_field profile_fingerprint || true)"
    profile_fp="$(credential_fingerprint "$path" || true)"
    if [[ -n "$live_fp" && "$profile_fp" == "$live_fp" && "$marker_fp" == "$live_fp" ]]; then
      printf '%s\n' "$marker_name"
      return 0
    fi
  fi

  shopt -s nullglob
  for path in "$PROFILE_DIR"/*.json; do
    profile_fp="$(credential_fingerprint "$path" || true)"
    if [[ -n "$live_fp" && "$profile_fp" == "$live_fp" ]]; then
      matched="$(basename "$path" .json)"
      break
    fi
  done
  shopt -u nullglob
  if [[ -n "$matched" ]]; then
    printf '%s\n' "$matched"
    return 0
  fi

  [[ "$live_kind" == "chatgpt" && -n "$live_identity" ]] || return 1
  if [[ -n "$marker_name" ]]; then
    path="$(profile_path "$marker_name")"
    if [[ -f "$path" ]]; then
      marker_kind="$(active_profile_marker_field kind || true)"
      marker_identity="$(active_profile_marker_field account_identity || true)"
      marker_fp="$(active_profile_marker_field profile_fingerprint || true)"
      marker_revision="$(active_profile_marker_field profile_revision || true)"
      profile_kind="$(auth_file_kind "$path" || true)"
      profile_identity="$(auth_file_account_identity "$path" || true)"
      profile_fp="$(credential_fingerprint "$path" || true)"
      profile_revision="$(auth_file_revision "$path" || true)"
      if [[ "$marker_kind" == "chatgpt" \
        && "$profile_kind" == "chatgpt" \
        && -n "$marker_identity" \
        && "$marker_identity" == "$live_identity" \
        && "$profile_identity" == "$live_identity" \
        && -n "$marker_fp" \
        && "$profile_fp" == "$marker_fp" \
        && -n "$marker_revision" \
        && "$profile_revision" == "$marker_revision" ]]; then
        printf '%s\n' "$marker_name"
        return 0
      fi
    fi
  fi

  shopt -s nullglob
  for path in "$PROFILE_DIR"/*.json; do
    profile_kind="$(auth_file_kind "$path" || true)"
    [[ "$profile_kind" == "chatgpt" ]] || continue
    profile_identity="$(auth_file_account_identity "$path" || true)"
    [[ -n "$profile_identity" && "$profile_identity" == "$live_identity" ]] || continue
    identity_match="$(basename "$path" .json)"
    identity_count=$((identity_count + 1))
  done
  shopt -u nullglob
  [[ "$identity_count" == "1" ]] || return 1
  printf '%s\n' "$identity_match"
}

sync_active_profile_from_live() (
  local snapshot name profile live_fp profile_fp live_revision profile_revision current_revision live_kind profile_kind
  local live_identity profile_identity marker_name marker_fp marker_identity marker_revision

  [[ -f "$AUTH_FILE" ]] && auth_file_is_valid "$AUTH_FILE" || return 0
  command -v jq >/dev/null 2>&1 || return 0
  ensure_dirs
  acquire_mutation_lock

  snapshot="$(mktemp "$CODEX_HOME/.tmp/active-auth.XXXXXX.json")"
  if ! copy_auth_file_atomic "$AUTH_FILE" "$snapshot"; then
    rm -f "$snapshot"
    return 0
  fi
  name="$(resolve_active_profile_for_auth "$snapshot" || true)"
  if [[ -z "$name" ]]; then
    rm -f "$snapshot"
    return 0
  fi
  profile="$(profile_path "$name")"
  if [[ ! -f "$profile" ]] || ! auth_file_is_valid "$profile"; then
    rm -f "$snapshot"
    return 0
  fi

  live_fp="$(credential_fingerprint "$snapshot" || true)"
  profile_fp="$(credential_fingerprint "$profile" || true)"
  live_revision="$(auth_file_revision "$snapshot" || true)"
  profile_revision="$(auth_file_revision "$profile" || true)"
  current_revision="$(auth_file_revision "$AUTH_FILE" || true)"
  if [[ -z "$live_fp" || -z "$live_revision" || "$current_revision" != "$live_revision" ]]; then
    rm -f "$snapshot"
    return 0
  fi
  if [[ "$live_revision" == "$profile_revision" ]]; then
    active_profile_marker_write "$name" "$profile" || true
    rm -f "$snapshot"
    return 0
  fi

  live_kind="$(auth_file_kind "$snapshot" || true)"
  profile_kind="$(auth_file_kind "$profile" || true)"
  live_identity="$(auth_file_account_identity "$snapshot" || true)"
  profile_identity="$(auth_file_account_identity "$profile" || true)"
  [[ "$live_kind" == "chatgpt" \
    && "$profile_kind" == "chatgpt" \
    && -n "$live_identity" \
    && "$live_identity" == "$profile_identity" ]] || { rm -f "$snapshot"; return 0; }

  marker_name="$(active_profile_marker_read || true)"
  if [[ -n "$marker_name" ]]; then
    marker_fp="$(active_profile_marker_field profile_fingerprint || true)"
    marker_identity="$(active_profile_marker_field account_identity || true)"
    marker_revision="$(active_profile_marker_field profile_revision || true)"
    [[ "$marker_name" == "$name" \
      && -n "$marker_fp" \
      && "$marker_fp" == "$profile_fp" \
      && "$marker_identity" == "$live_identity" \
      && -n "$marker_revision" \
      && "$marker_revision" == "$profile_revision" ]] || { rm -f "$snapshot"; return 0; }
  fi

  [[ "$(auth_file_revision "$profile" || true)" == "$profile_revision" \
    && "$(auth_file_revision "$AUTH_FILE" || true)" == "$live_revision" ]] \
    || { rm -f "$snapshot"; return 0; }
  copy_auth_file_atomic "$snapshot" "$profile" || { rm -f "$snapshot"; return 0; }
  active_profile_marker_write "$name" "$profile" || true
  rm -f "$snapshot"
)

cmd_list() {
  ensure_dirs
  sync_active_profile_from_live
  local list_verbose=0

  while (( $# > 0 )); do
    case "$1" in
      --verbose|-v)
        list_verbose=1
        shift
        ;;
      *)
        die "usage: codex-auth list [-v]"
        ;;
    esac
  done

  shopt -s nullglob
  local profiles=("$PROFILE_DIR"/*.json)
  if (( ${#profiles[@]} == 0 )); then
    print_empty_profiles
    return 0
  fi

  local active_fp=""
  local active_name="" count=0
  local alias_count=0
  local meta_files=()
  local -A account_primary=()
  local -A account_count=()
  local -A profile_mode=()
  local -A profile_hint=()
  local -A profile_fp=()
  local fp meta_path mode hint secret name path

  [[ -f "$AUTH_FILE" ]] && meta_files+=("$AUTH_FILE")
  meta_files+=("${profiles[@]}")
  while IFS=$'\037' read -r meta_path mode hint secret; do
    [[ -n "$meta_path" ]] || continue
    fp="$(auth_record_fingerprint "$secret")"
    if [[ "$meta_path" == "$AUTH_FILE" ]]; then
      active_fp="$fp"
    else
      name="$(basename "$meta_path" .json)"
      profile_mode["$name"]="$mode"
      profile_hint["$name"]="$hint"
      profile_fp["$name"]="$fp"
    fi
  done < <(auth_metadata_records "${meta_files[@]}")
  PROFILE_LIST_WIDTH_HINT=12
  for path in "${profiles[@]}"; do
    name="$(basename "$path" .json)"
    (( ${#name} > PROFILE_LIST_WIDTH_HINT )) && PROFILE_LIST_WIDTH_HINT="${#name}"
    hint="${profile_hint["$name"]:-}"
    fp="${profile_fp["$name"]:-}"
    if [[ -z "$active_name" && -n "$active_fp" && "$fp" == "$active_fp" ]]; then
      active_name="$name"
    fi
    if [[ -n "$hint" ]]; then
      account_count["$hint"]=$(( ${account_count["$hint"]:-0} + 1 ))
      if (( account_count["$hint"] > 1 )); then
        alias_count=$((alias_count + 1))
      fi
      if [[ -z "${account_primary["$hint"]:-}" || ( "${account_primary["$hint"]:-}" == "current" && "$name" != "current" ) ]]; then
        account_primary["$hint"]="$name"
      fi
    fi
    count=$((count + 1))
  done

  local cols role_w=5 profile_w mode_w=7 account_w account_min=10 max_profile_w wanted_profile_w
  local total_w summary role_header profile_header active_summary active_label active_short active_tiny alias_summary sep
  local action action_label alias_of account_display account_base clean right left alias_label alias_text compact_alias alias_glyph
  cols="$(terminal_width)"
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1
  USAGE_VERBOSE="$list_verbose"
  wanted_profile_w="${PROFILE_LIST_WIDTH_HINT:-12}"
  wanted_profile_w="$(usage_profile_width_hint "$cols" "$wanted_profile_w" "$USAGE_VERBOSE")"
  if (( cols < 34 )); then
    role_w=1
    mode_w=4
    account_min=8
  elif (( cols < 40 )); then
    role_w=1
    mode_w=7
    account_min=10
  fi
  max_profile_w=$((cols - role_w - mode_w - account_min - 3))
  profile_w="$wanted_profile_w"
  (( profile_w > max_profile_w )) && profile_w="$max_profile_w"
  if (( cols < 23 )); then
    (( profile_w < 4 )) && profile_w=4
  else
    (( profile_w < 5 )) && profile_w=5
  fi
  account_w=$((cols - role_w - profile_w - mode_w - 3))
  (( account_w < account_min )) && account_w="$account_min"

  total_w=$((role_w + 1 + profile_w + 1 + mode_w + 1 + account_w))
  summary="profiles $count"
  if [[ -n "$active_name" ]]; then
    sep="$(usage_separator)"
    active_short="$(usage_display_profile_name "$active_name" "" 6)"
    active_tiny="$(usage_display_profile_name "$active_name" "" 3)"
    for active_label in "active $active_name" "act $active_name" "act $active_short" "act $active_tiny"; do
      active_summary="$summary$sep$active_label"
      if (( ${#active_summary} <= total_w )); then
        summary="$active_summary"
        break
      fi
    done
  fi
  if (( alias_count > 0 )); then
    alias_summary="$summary$(usage_separator)aliases $alias_count"
    if (( ${#alias_summary} <= total_w )); then
      summary="$alias_summary"
    fi
  fi
  print_palette_summary_header "Saved profiles" "$summary" "$total_w"
  role_header="act"; (( role_w < 2 )) && role_header=""
  profile_header="profile"; (( profile_w < 7 )) && profile_header="prof"
  print_profile_list_line "$role_header" "$profile_header" "auth" "account" "$role_w" "$profile_w" "$mode_w" "$account_w"
  for path in "${profiles[@]}"; do
    name="$(basename "$path" .json)"
    mode="${profile_mode["$name"]:-unknown}"
    hint="${profile_hint["$name"]:-}"
    fp="${profile_fp["$name"]:-}"
    alias_of=""
    if [[ -n "$hint" && "${account_count["$hint"]:-0}" -gt 1 && "$name" != "${account_primary["$hint"]:-}" ]]; then
      alias_of="${account_primary["$hint"]}"
    fi
    if [[ -n "$active_name" && "$name" == "$active_name" ]]; then
      action="stay"
    elif [[ -n "$alias_of" || ( -n "$active_fp" && "$fp" == "$active_fp" ) ]]; then
      action="alias"
    else
      action="use"
    fi
    if (( role_w <= 1 )); then
      action_label="${action:0:1}"
    else
      action_label="$action"
    fi
    if [[ -n "$alias_of" ]]; then
      alias_label="$(usage_display_profile_name "$alias_of" "" "$account_w")"
      if usage_unicode_enabled; then
        alias_glyph="↔"
      else
        alias_glyph="="
      fi
      if (( list_verbose )) && [[ -n "$hint" ]]; then
        account_base="$hint"
      else
        account_base="$(short_account_hint "$hint" 13)"
      fi
      alias_text="$account_base $alias_glyph $alias_label"
      compact_alias="$alias_glyph $alias_label"
      if (( ${#alias_text} > account_w )) && (( list_verbose )); then
        account_base="$(short_account_hint "$hint" 13)"
        alias_text="$account_base $alias_glyph $alias_label"
      fi
      if (( ${#alias_text} <= account_w )); then
        account_display="$alias_text"
      elif (( ${#compact_alias} <= account_w )); then
        account_display="$compact_alias"
      elif (( account_w >= 5 )); then
        alias_label="$(usage_display_profile_name "$alias_of" "" "$((account_w - 2))")"
        compact_alias="$alias_glyph $alias_label"
        if (( ${#compact_alias} <= account_w )); then
          account_display="$compact_alias"
        else
          account_display="$alias_glyph$(fit_profile_text "$alias_label" "$((account_w - 1))")"
        fi
      elif (( account_w >= 2 )); then
        account_display="$alias_glyph$(fit_profile_text "$alias_label" "$((account_w - 1))")"
      else
        account_display="$(fit_text "$(short_account_hint "$hint" "$account_w")" "$account_w")"
      fi
    elif [[ -n "$hint" ]]; then
      if (( list_verbose )); then
        if (( ${#hint} <= account_w )); then
          account_base="$hint"
        else
          clean="${hint//-/}"
          if [[ "$hint" =~ ^[0-9a-fA-F-]+$ && ${#clean} -gt 12 ]]; then
            if (( account_w >= 13 )); then
              right=$((account_w - 9))
              (( right < 4 )) && right=4
              account_base="${clean:0:8}$(usage_glyph '…' '~')${clean:${#clean}-right:right}"
            elif (( account_w >= 8 )); then
              right=4
              left=$((account_w - right - 1))
              (( left < 3 )) && left=3
              account_base="${clean:0:left}$(usage_glyph '…' '~')${clean:${#clean}-right:right}"
            else
              account_base="$(fit_profile_text "$clean" "$account_w")"
            fi
          else
            account_base="$(fit_profile_text "$hint" "$account_w")"
          fi
        fi
      else
        account_base="$(short_account_hint "$hint" "$account_w")"
      fi
      account_display="$(fit_text "$account_base" "$account_w")"
    else
      account_display=""
    fi
    print_profile_list_line "$action_label" "$name" "$mode" "$account_display" "$role_w" "$profile_w" "$mode_w" "$account_w"
  done
}

cmd_current() {
  ensure_dirs
  sync_active_profile_from_live
  local cols label_w value_w total_w status_text
  cols="$(terminal_width)"
  IFS=$'\t' read -r label_w value_w <<<"$(detail_widths "$cols")"
  total_w=$((label_w + 1 + value_w))
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1

  if [[ ! -f "$AUTH_FILE" ]] || ! auth_file_is_valid "$AUTH_FILE"; then
    local current_profiles=() current_status first_profile next_command action
    if [[ -f "$AUTH_FILE" ]]; then
      current_status="bad active auth"
    else
      current_status="no active auth"
    fi

    shopt -s nullglob
    current_profiles=("$PROFILE_DIR"/*.json)
    shopt -u nullglob

    print_palette_summary_header "Active profile" "$current_status" "$total_w"
    [[ "$current_status" == "bad active auth" ]] && print_detail_line "live" "$(compact_display_path "$AUTH_FILE" "$value_w")" "$label_w" "$value_w" bad
    if (( ${#current_profiles[@]} > 0 )); then
      first_profile="$(basename "${current_profiles[0]}" .json)"
      next_command="$first_profile"
      action="use"
    elif [[ "$current_status" == "no active auth" ]]; then
      next_command="codex-auth add <name>"
      action="login"
    else
      if (( total_w < 24 )); then
        next_command="login"
      else
        next_command="codex-auth login <name>"
      fi
      action="fix"
    fi
    print_detail_text_line "$action" "$(compact_command_display "$next_command" "$value_w")" "$label_w" "$value_w" active
    [[ "$current_status" == "no active auth" ]] && print_detail_line "live" "$(compact_display_path "$AUTH_FILE" "$value_w")" "$label_w" "$value_w" bad
    return 0
  fi

  if (( cols < 68 )); then
    label_w=7
    value_w=$((cols - label_w - 1))
    (( value_w < 10 )) && value_w=10
    total_w=$((label_w + 1 + value_w))
  fi

  local active_fp="" mode mode_display mode_summary_display matched matched_display hint account_display summary
  local active_mode="" active_hint=""
  local meta_files=()
  local -A meta_fp=()
  local fp meta_path secret meta_mode meta_hint path codex_cli

  shopt -s nullglob
  meta_files+=("$AUTH_FILE")
  for path in "$PROFILE_DIR"/*.json; do
    meta_files+=("$path")
  done
  while IFS=$'\037' read -r meta_path meta_mode meta_hint secret; do
    [[ -n "$meta_path" ]] || continue
    fp="$(auth_record_fingerprint "$secret")"
    meta_fp["$meta_path"]="$fp"
    if [[ "$meta_path" == "$AUTH_FILE" ]]; then
      active_fp="$fp"
      active_mode="${meta_mode:-unknown}"
      active_hint="${meta_hint:-}"
    fi
  done < <(auth_metadata_records "${meta_files[@]}")
  mode="${active_mode:-unknown}"
  mode_display="$(auth_mode_display_label "$mode")"
  hint="${active_hint:-}"
  active_fp="${active_fp:-}"
  account_display="$(short_account_hint "$hint" "$value_w")"
  matched=""
  if [[ -n "$active_fp" ]]; then
    for path in "$PROFILE_DIR"/*.json; do
      fp="${meta_fp["$path"]:-}"
      if [[ "$fp" == "$active_fp" ]]; then
        matched="$(basename "$path" .json)"
        break
      fi
    done
  fi
  mode_summary_display="$mode_display"
  if (( total_w < 24 )); then
    case "$mode" in
      chatgpt) mode_summary_display="chat" ;;
      api_key) mode_summary_display="api" ;;
      unknown|"") mode_summary_display="n/a" ;;
      *) mode_summary_display="$(fit_text "$mode" 4)" ;;
    esac
  fi
  matched_display="$matched"
  if [[ -n "$matched_display" && "$total_w" -lt 22 ]]; then
    matched_display="$(usage_display_profile_name "$matched_display" "" 6)"
  fi
  if [[ -n "$matched" ]]; then
    summary="active $matched_display$(usage_separator)$mode_summary_display"
  elif (( total_w < 22 )); then
    summary="unsaved$(usage_separator)$mode_summary_display"
  else
    summary="active unsaved$(usage_separator)$mode_summary_display"
  fi
  if [[ -n "$hint" ]] && (( ${#summary} + ${#account_display} + 11 <= total_w )); then
    summary+="$(usage_separator)account $account_display"
  fi

  print_palette_summary_header "Active profile" "$summary" "$total_w" flat 0
  if [[ -n "$hint" && "$summary" != *"account "* ]]; then
    print_detail_line "account" "$account_display" "$label_w" "$value_w"
  fi
  status_text=""
  codex_cli="$(codex_bin || true)"
  if [[ -n "$codex_cli" ]] && { ! codex_launcher_needs_node "$codex_cli" || command -v node >/dev/null 2>&1; }; then
    status_text="$(CODEX_AUTH_RUNNER=1 "$codex_cli" login status 2>&1 || true)"
    status_text="$(normalize_codex_status_text "$status_text")"
    [[ "$status_text" == "Logged in using "* ]] && status_text="${status_text#Logged in using }"
    [[ "$status_text" != "$mode_display" ]] || status_text=""
  fi
  if [[ -n "$status_text" ]]; then
    print_detail_text_line "codex" "$status_text" "$label_w" "$value_w"
  fi
}

cmd_save() {
  local name="$1"
  local source="${2:-$AUTH_FILE}"
  local summary="${3:-saved $name}"
  require_name "$name"
  ensure_dirs
  acquire_mutation_lock
  if [[ "$source" == "$AUTH_FILE" ]]; then
    sync_active_profile_from_live
  fi
  if [[ "$source" == "$AUTH_FILE" && ! -f "$source" ]]; then
    die "no active auth to save"
  fi
  require_auth_file "$source"

  local dest
  dest="$(profile_path "$name")"
  copy_auth_file_atomic "$source" "$dest"
  if [[ "$source" == "$AUTH_FILE" ]]; then
    active_profile_marker_write "$name" "$dest" || true
  fi
  print_result_block "$summary" \
    "profile"$'\t'"$(display_path "$dest")"$'\t'"active" \
    "source"$'\t'"$(display_path "$source")"$'\t'"muted"
}

cmd_use() {
  local name="$1"
  require_name "$name"
  ensure_dirs
  acquire_mutation_lock
  sync_active_profile_from_live

  local source source_fp="" active_fp=""
  source="$(profile_path "$name")"
  [[ -f "$source" ]] || die "profile not found: $name"
  require_auth_file "$source"

  source_fp="$(credential_fingerprint "$source" || true)"
  if [[ -f "$AUTH_FILE" ]]; then
    active_fp="$(credential_fingerprint "$AUTH_FILE" || true)"
  fi
  if [[ -n "$source_fp" && -n "$active_fp" && "$source_fp" == "$active_fp" ]]; then
    active_profile_marker_write "$name" "$source" || true
    print_result_block "active $name" \
      "auth"$'\t'"$(display_path "$AUTH_FILE")"$'\t'"active" \
      "profile"$'\t'"$(display_path "$source")"$'\t'"muted" \
      "active"$'\t'"already active"$'\t'"active"
    return 0
  fi

  local backup=""
  backup="$(backup_current "pre-use-$name" || true)"
  copy_auth_file_atomic "$source" "$AUTH_FILE"
  active_profile_marker_write "$name" "$source" || true

  if [[ -n "$backup" ]]; then
    print_result_block "active $name" \
      "auth"$'\t'"$(display_path "$AUTH_FILE")"$'\t'"active" \
      "profile"$'\t'"$(display_path "$source")"$'\t'"muted" \
      "backup"$'\t'"$(display_path "$backup")"$'\t'"muted"
  else
    print_result_block "active $name" \
      "auth"$'\t'"$(display_path "$AUTH_FILE")"$'\t'"active" \
      "profile"$'\t'"$(display_path "$source")"$'\t'"muted"
  fi
}

cmd_use_if_current() {
  local expected="$1"
  local target="$2"
  local refresh_generation="${3:-}"
  require_name "$expected"
  require_name "$target"
  ensure_dirs
  acquire_mutation_lock
  sync_active_profile_from_live

  local expected_source expected_fp active_fp="" target_source target_fp
  expected_source="$(profile_path "$expected")"
  [[ -f "$expected_source" ]] || die "profile not found: $expected"
  require_auth_file "$expected_source"
  expected_fp="$(credential_fingerprint "$expected_source" || true)"
  if [[ -f "$AUTH_FILE" ]]; then
    active_fp="$(credential_fingerprint "$AUTH_FILE" || true)"
  fi
  if [[ -z "$expected_fp" || -z "$active_fp" || "$expected_fp" != "$active_fp" ]]; then
    print_error "active profile changed; expected $expected"
    return 75
  fi

  if [[ -n "$refresh_generation" ]]; then
    target_source="$(profile_path "$target")"
    [[ -f "$target_source" ]] || die "profile not found: $target"
    require_auth_file "$target_source"
    target_fp="$(credential_fingerprint "$target_source" || true)"
    if [[ -z "$target_fp" ]] || ! jq -e \
      --arg expected "$expected" \
      --arg expected_fp "$expected_fp" \
      --arg target "$target" \
      --arg target_fp "$target_fp" \
      --arg generation "$refresh_generation" '
        .profiles[$expected].fingerprint == $expected_fp
        and .profiles[$expected].refresh_generation == $generation
        and .profiles[$target].fingerprint == $target_fp
        and .profiles[$target].refresh_generation == $generation
      ' "$STATE_FILE" >/dev/null 2>&1
    then
      print_error "profile changed or was not refreshed; expected generation $refresh_generation"
      return 75
    fi
  fi

  cmd_use "$target"
}

cmd_login() {
  local name="$1"
  shift || true
  require_name "$name"
  [[ -t 0 && -t 1 ]] || die "login needs tty"
  local codex_cli
  codex_cli="$(codex_bin)" || die "codex command not found"
  require_codex_launcher "$codex_cli"
  ensure_dirs
  acquire_mutation_lock
  sync_active_profile_from_live

  backup_current "pre-login-$name" >/dev/null || true

  local hidden_auth="" message
  if [[ -f "$AUTH_FILE" ]]; then
    hidden_auth="$(reserve_unique_backup_path "hidden-for-login-$name")"
    mv "$AUTH_FILE" "$hidden_auth" || { rm -f "$hidden_auth"; die "could not hide active auth for login"; }
    chmod 600 "$hidden_auth"
  fi

  if ! CODEX_AUTH_RUNNER=1 "$codex_cli" login "$@"; then
    message="login failed"
    restore_hidden_auth "$hidden_auth" && message="login failed; restored previous auth"
    print_error "$message"
    exit 1
  fi

  if ! auth_file_is_valid "$AUTH_FILE"; then
    message="login did not produce valid auth"
    restore_hidden_auth "$hidden_auth" && message="login did not produce valid auth; restored previous auth"
    print_error "$message"
    exit 1
  fi

  cmd_save "$name" "$AUTH_FILE" "login $name"
  rm -f "$hidden_auth"
}

reauth_prepare_private_config() {
  local source="$1"
  local dest="$2"

  if [[ -f "$source" ]]; then
    cp -p "$source" "$dest" || return 1
  else
    : > "$dest" || return 1
  fi
  chmod 600 "$dest"
}

cmd_reauth() (
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: codex-auth reauth <name> [codex login args...]"
  shift || true
  require_name "$name"
  [[ -t 0 && -t 1 ]] || die "reauth needs tty"
  local login_arg
  for login_arg in "$@"; do
    [[ "$login_arg" != *cli_auth_credentials_store* ]] \
      || die "reauth controls cli_auth_credentials_store for isolated login"
  done

  local codex_cli profile expected_auth expected_revision expected_kind expected_identity
  local login_home login_auth login_kind login_identity active_name live_before marker_before marker_existed=0
  codex_cli="$(codex_bin)" || die "codex command not found"
  require_codex_launcher "$codex_cli"
  ensure_dirs

  profile="$(profile_path "$name")"
  [[ -f "$profile" ]] || die "profile not found: $name"
  require_auth_file "$profile"
  expected_kind="$(auth_file_kind "$profile" || true)"
  [[ "$expected_kind" == "chatgpt" ]] || die "reauth only supports ChatGPT profiles"

  login_home="$(mktemp -d "$CODEX_HOME/.tmp/reauth-${name}.XXXXXX")"
  chmod 700 "$login_home" || die "could not secure private login home"
  trap 'rm -rf "${login_home:-}"' EXIT
  trap 'exit 129' HUP
  trap 'exit 130' INT
  trap 'exit 143' TERM

  expected_auth="$login_home/expected-auth.json"
  copy_auth_file_atomic "$profile" "$expected_auth" || die "could not snapshot profile: $name"
  expected_revision="$(auth_file_revision "$expected_auth" || true)"
  [[ -n "$expected_revision" ]] || die "could not snapshot profile revision: $name"
  expected_identity="$(auth_file_account_identity "$expected_auth" || true)"
  [[ -n "$expected_identity" ]] || die "saved profile has no stable account identity; cannot safely reauthenticate"

  reauth_prepare_private_config "$CODEX_HOME/config.toml" "$login_home/config.toml" \
    || die "could not prepare private login config"

  if ! CODEX_HOME="$login_home" CODEX_AUTH_RUNNER=1 "$codex_cli" login \
    -c "cli_auth_credentials_store=\"file\"" "$@"; then
    print_error "login failed; saved profile was not changed"
    return 1
  fi

  login_auth="$login_home/auth.json"
  if ! auth_file_is_valid "$login_auth"; then
    print_error "login did not produce valid file-based auth; saved profile was not changed"
    return 1
  fi
  login_kind="$(auth_file_kind "$login_auth" || true)"
  [[ "$login_kind" == "chatgpt" ]] || {
    print_error "login did not produce ChatGPT auth; saved profile was not changed"
    return 1
  }
  if ! jq -e '
    (.tokens | type == "object")
    and ([.tokens.refresh_token?, .tokens.access_token?]
      | any(type == "string" and length > 0))
  ' "$login_auth" >/dev/null 2>&1; then
    print_error "login did not produce a ChatGPT credential; saved profile was not changed"
    return 1
  fi
  login_identity="$(auth_file_account_identity "$login_auth" || true)"
  if [[ "$login_identity" != "$expected_identity" ]]; then
    print_error "login account did not match saved profile; saved profile was not changed"
    return 1
  fi

  acquire_mutation_lock
  if [[ "$(auth_file_revision "$profile" || true)" != "$expected_revision" ]]; then
    print_error "profile changed while login was open; saved login was not applied"
    return 75
  fi

  active_name=""
  if [[ -f "$AUTH_FILE" ]] && auth_file_is_valid "$AUTH_FILE"; then
    active_name="$(resolve_active_profile_for_auth "$AUTH_FILE" || true)"
  fi

  if [[ "$active_name" != "$name" ]]; then
    copy_auth_file_atomic "$login_auth" "$profile" || die "could not update profile: $name"
    print_result_block "reauthenticated $name" \
      "profile"$'\t'"$(display_path "$profile")"$'\t'"active" \
      "active"$'\t'"unchanged"$'\t'"muted"
    return 0
  fi

  if [[ ! -f "$AUTH_FILE" ]] || ! auth_file_is_valid "$AUTH_FILE"; then
    print_error "active auth changed while login was open; saved login was not applied"
    return 75
  fi
  local live_identity
  live_identity="$(auth_file_account_identity "$AUTH_FILE" || true)"
  if [[ -n "$login_identity" && "$live_identity" != "$login_identity" ]]; then
    print_error "active account changed while login was open; saved login was not applied"
    return 75
  fi

  live_before="$login_home/live-before.json"
  copy_auth_file_atomic "$AUTH_FILE" "$live_before" || die "could not snapshot active auth"
  marker_before="$login_home/active-profile-before.json"
  if [[ -f "$ACTIVE_PROFILE_FILE" ]]; then
    cp -p "$ACTIVE_PROFILE_FILE" "$marker_before" || die "could not snapshot active profile marker"
    chmod 600 "$marker_before"
    marker_existed=1
  fi

  if ! copy_auth_file_atomic "$login_auth" "$profile" \
    || ! copy_auth_file_atomic "$login_auth" "$AUTH_FILE" \
    || ! active_profile_marker_write "$name" "$profile"
  then
    copy_auth_file_atomic "$expected_auth" "$profile" || true
    copy_auth_file_atomic "$live_before" "$AUTH_FILE" || true
    if (( marker_existed )); then
      copy_auth_file_atomic "$marker_before" "$ACTIVE_PROFILE_FILE" || true
    else
      rm -f "$ACTIVE_PROFILE_FILE"
    fi
    print_error "could not update active profile; previous auth was restored"
    return 1
  fi

  print_result_block "reauthenticated $name" \
    "profile"$'\t'"$(display_path "$profile")"$'\t'"active" \
    "active"$'\t'"kept $name"$'\t'"active"
)

cmd_add() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "usage: codex-auth add <name> [--current | --file <file> | codex login args...]"
  shift || true
  require_name "$name"

  local source=""
  local login_args=()

  while (( $# > 0 )); do
    case "$1" in
      --current)
        [[ -z "$source" ]] || die "add accepts one source: --current or --file"
        source="$AUTH_FILE"
        shift
        ;;
      --file|--from)
        [[ -n "${2:-}" ]] || die "usage: codex-auth add <name> --file <file>"
        [[ -z "$source" ]] || die "add accepts one source: --current or --file"
        source="$2"
        shift 2
        ;;
      --)
        shift
        login_args+=("$@")
        break
        ;;
      *)
        if [[ -f "$1" && -z "$source" ]]; then
          source="$1"
        else
          login_args+=("$1")
        fi
        shift
        ;;
    esac
  done

  if [[ -n "$source" ]]; then
    (( ${#login_args[@]} == 0 )) || die "add cannot mix --file/--current with login args"
    cmd_save "$name" "$source"
    return 0
  fi

  cmd_login "$name" "${login_args[@]}"
}

cmd_export() {
  local name="$1"
  local dest="$2"
  require_name "$name"
  ensure_dirs

  local source dest_dir
  source="$(profile_path "$name")"
  [[ -f "$source" ]] || die "profile not found: $name"
  require_auth_file "$source"
  dest_dir="$(dirname "$dest")"
  [[ -d "$dest_dir" ]] || die "export dir missing: $dest_dir"
  [[ ! -d "$dest" ]] || die "export path is a directory: $dest"
  copy_auth_file_atomic "$source" "$dest"
  print_result_block "export $name" \
    "dest"$'\t'"$(display_path "$dest")"$'\t'"active" \
    "source"$'\t'"$(display_path "$source")"$'\t'"muted"
}


cmd_remove() {
  local name="$1"
  local yes="${2:-}"
  require_name "$name"
  [[ "$yes" == "--yes" ]] || die "refusing to remove without --yes"
  ensure_dirs
  acquire_mutation_lock

  local path active_matches=0 active_fp="" profile_fp="" active_name="" remaining_name="" active_value="unsaved auth" marker_name=""
  local other other_name other_fp
  path="$(profile_path "$name")"
  [[ -f "$path" ]] || die "profile not found: $name"
  marker_name="$(active_profile_marker_read || true)"
  if [[ -f "$AUTH_FILE" ]]; then
    active_fp="$(credential_fingerprint "$AUTH_FILE" || true)"
    profile_fp="$(credential_fingerprint "$path" || true)"
    if [[ -n "$active_fp" && "$active_fp" == "$profile_fp" ]]; then
      shopt -s nullglob
      for other in "$PROFILE_DIR"/*.json; do
        other_fp="$(credential_fingerprint "$other" || true)"
        [[ -n "$other_fp" && "$other_fp" == "$active_fp" ]] || continue
        other_name="$(basename "$other" .json)"
        [[ -z "$active_name" ]] && active_name="$other_name"
        [[ "$other_name" != "$name" && -z "$remaining_name" ]] && remaining_name="$other_name"
      done
      [[ "$active_name" == "$name" ]] && active_matches=1
    fi
  fi

  rm -f "$path"
  if [[ "$marker_name" == "$name" ]]; then
    if [[ -n "$remaining_name" && -f "$(profile_path "$remaining_name")" ]]; then
      active_profile_marker_write "$remaining_name" "$(profile_path "$remaining_name")" || active_profile_marker_clear "$name"
    else
      active_profile_marker_clear "$name"
    fi
  fi
  if (( active_matches )); then
    [[ -n "$remaining_name" ]] && active_value="saved $remaining_name"
    print_result_block "removed active $name" \
      "profile"$'\t'"$(display_path "$path")"$'\t'"bad" \
      "active"$'\t'"$active_value"$'\t'"active"
    return 0
  fi
  print_result_block "removed $name" \
    "profile"$'\t'"$(display_path "$path")"$'\t'"bad"
}


cmd_paths() {
  ensure_dirs
  local cols role_w=5 target_w=8 path_w total_w home_label
  cols="$(terminal_width)"
  if (( cols < 39 )); then
    target_w=0
  elif (( cols >= 72 )); then
    role_w=6
    target_w=9
  fi
  if (( target_w <= 0 )); then
    path_w=$((cols - role_w - 1))
  else
    path_w=$((cols - role_w - target_w - 2))
  fi
  (( path_w < 8 )) && path_w=8
  if (( target_w > 0 )); then
    total_w=$((role_w + 1 + target_w + 1 + path_w))
  else
    total_w=$((role_w + 1 + path_w))
  fi
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1

  home_label="home $(compact_display_path "$CODEX_HOME" "$path_w")"
  print_palette_summary_header "Paths" "$home_label" "$total_w"
  print_path_line "live" "auth" "$AUTH_FILE" "$role_w" "$target_w" "$path_w" active
  print_path_line "saved" "profiles" "$PROFILE_DIR" "$role_w" "$target_w" "$path_w" good
  print_path_line "undo" "backups" "$BACKUP_DIR" "$role_w" "$target_w" "$path_w" warn
  print_path_line "cache" "usage" "$STATE_FILE" "$role_w" "$target_w" "$path_w" muted
}
