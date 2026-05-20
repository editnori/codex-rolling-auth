# shellcheck shell=bash

print_profile_list_line() {
  local role="$1"
  local profile="$2"
  local mode="$3"
  local account="$4"
  local role_w="$5"
  local profile_w="$6"
  local mode_w="$7"
  local account_w="$8"
  local role_tone="muted"
  local mode_display

  if [[ "$role" == "$(usage_glyph '●' '*')" || "$role" == "active" || "$role" == "stay" || "$role" == "s" || "$role" == "*" ]]; then
    role_tone="active"
  fi
  case "$role" in
    use|u)
      role_tone="good"
      ;;
    alias|a|=)
      role_tone="warn"
      ;;
  esac
  print_toned_fit "$role" "$role_w" "$role_tone"
  printf ' '
  fit_profile_text "$(usage_display_profile_name "$profile" "$role" "$profile_w")" "$profile_w"
  printf ' '
  if (( mode_w <= 4 )); then
    case "$mode" in
      chatgpt) mode_display="chat" ;;
      api_key) mode_display="api" ;;
      unknown|"") mode_display="n/a" ;;
      *) mode_display="$(fit_text "$mode" "$mode_w")" ;;
    esac
  else
    mode_display="$(fit_text "$(auth_mode_display_label "$mode")" "$mode_w")"
  fi
  printf '%s' "$mode_display"
  printf ' '
  fit_profile_text_rtrim "$account" "$account_w"
  printf '\n'
}

detail_widths() {
  local cols="$1"
  local label_w=8
  local value_w

  (( cols >= 72 )) && label_w=10
  value_w=$((cols - label_w - 1))
  (( value_w < 10 )) && value_w=10

  printf '%s\t%s\n' "$label_w" "$value_w"
}

print_detail_line() {
  local label="$1"
  local value="$2"
  local label_w="$3"
  local value_w="$4"
  local tone="${5:-muted}"

  print_toned_fit "$label" "$label_w" "$tone"
  printf ' '
  fit_profile_text_rtrim "$value" "$value_w"
  printf '\n'
}

print_detail_text_line() {
  local label="$1"
  local value="$2"
  local label_w="$3"
  local value_w="$4"
  local tone="${5:-muted}"

  print_toned_fit "$label" "$label_w" "$tone"
  printf ' '
  fit_text_rtrim "$value" "$value_w"
  printf '\n'
}

print_path_line() {
  local role="$1" target="$2" path="$3" role_w="$4" target_w="$5" path_w="$6"
  local tone="${7:-muted}" rendered role_label target_label base

  rendered="$(compact_display_path "$path" "$path_w")"
  base=""
  if [[ "$path" == */* ]]; then
    base="${path##*/}"
    (( ${#base} <= path_w )) || base=""
  fi
  if (( target_w <= 0 )) && { { (( path_w < 24 )) && [[ "$target" != "auth" ]]; } || [[ "$rendered" == "…/"* || "$rendered" == "*/"* ]]; }; then
    rendered="${base:-$rendered}"
  fi
  if (( ${#rendered} > path_w )); then
    rendered="${base:-$rendered}"
  fi
  if (( target_w <= 0 )) && [[ "$target" == "usage" && "$path_w" -lt 15 ]]; then
    base="state.json"
    (( ${#base} <= path_w )) && rendered="$base"
  fi
  role_label="$role"
  if (( role_w <= 4 )); then
    case "$role" in
      saved) role_label="save" ;;
      cache) role_label="cach" ;;
    esac
  fi
  print_toned_fit "$role_label" "$role_w" "$tone"
  printf ' '
  if (( target_w > 0 )); then
    target_label="$target"
    if (( target_w <= 4 )); then
      case "$target" in
        profiles) target_label="prof" ;;
        backups) target_label="back" ;;
        usage) target_label="usg" ;;
      esac
    fi
    fit_text "$target_label" "$target_w"
    printf ' '
  fi
  fit_profile_text_rtrim "$rendered" "$path_w"
  printf '\n'
}

compact_command_display() {
  local command="$1"
  local width="$2"

  if (( ${#command} > width )) && [[ "$command" == codex-auth\ * ]]; then
    command="${command#codex-auth }"
  fi
  if (( ${#command} > width )) && [[ "$command" == "add current --current" ]]; then
    command="save current"
  fi
  if (( ${#command} > width )) && [[ "$command" == "save current" ]]; then
    command="current"
  fi
  printf '%s' "$command"
}

print_result_block() {
  local summary="$1"
  shift
  local cols label_w value_w total_w row title display_summary
  local label value tone display_label base

  cols="$(terminal_width)"
  IFS=$'\t' read -r label_w value_w <<<"$(detail_widths "$cols")"
  total_w=$((label_w + 1 + value_w))
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1

  case "$summary" in
    active\ *|using\ profile\ *)
      title="Active profile"
      ;;
    saved\ *|login\ *|imported\ *|logged\ in\ profile\ *)
      title="Saved profile"
      ;;
    export\ *|exported\ profile\ *)
      title="Export"
      ;;
    removed\ *)
      title="Removed profile"
      ;;
    *)
      title="Result"
      ;;
  esac
  if (( total_w < 24 )) && [[ "$summary" == removed\ active\ * ]]; then
    display_summary="removed ${summary#removed active }"
  else
    display_summary="$summary"
  fi
  print_palette_summary_header "$title" "$display_summary" "$total_w"
  for row in "$@"; do
    IFS=$'\t' read -r label value tone <<<"$row"
    [[ -n "$tone" ]] || tone="muted"
    case "$label" in
      backup)
        if [[ "$value" == */* ]]; then
          if [[ "${CODEX_AUTH_SHOW_BACKUP_PATH:-0}" != "1" || value_w -lt 46 ]]; then
            value="created"
          else
            value="$(compact_display_path "$value" "$value_w")"
          fi
        fi
        ;;
      active|profile|source|dest|dir|auth|profiles|backups|state)
        if [[ "$value" == */* ]]; then
          if (( value_w < 18 )); then
            base="${value##*/}"
            value="$(fit_profile_text_rtrim "$base" "$value_w")"
          else
            value="$(compact_display_path "$value" "$value_w")"
          fi
        fi
        ;;
    esac
    if [[ "$label" == "active" && "$value" == "unsaved auth" && "$value_w" -lt 12 ]]; then
      value="unsaved"
    elif [[ "$label" == "active" && "$value" == "already active" && "$value_w" -lt 14 ]]; then
      value="already"
    elif [[ "$label" == "active" && "$value" == saved\ * && "$value_w" -lt 12 ]]; then
      value="saved"
    fi
    case "$label" in
      auth)
        display_label="live"
        ;;
      profile)
        if [[ "$summary" == removed* ]]; then
          display_label="gone"
        else
          display_label="saved"
        fi
        ;;
      source)
        display_label="from"
        ;;
      dest)
        display_label="out"
        ;;
      backup)
        display_label="undo"
        ;;
      active)
        display_label="state"
        ;;
      *)
        display_label="$label"
        ;;
    esac
    print_detail_line "$display_label" "$value" "$label_w" "$value_w" "$tone"
  done
}

COMPACT_ERROR_STATIC_ROWS=(
  $'refusing to remove without --yes\t-\tremove needs --yes'
  $'usage: --ttl seconds\t-\tttl needs seconds'
  $'usage: codex-auth add <name> --file <file>\t28\tadd needs file\tadd needs --file <file>'
  $'usage: codex-auth add <name> [--current | --file <file> | codex login args...]\t28\tadd needs name\tusage: add <name>'
  $'add accepts one source: --current or --file\t40\tchoose one source\tchoose --current or --file'
  $'add cannot mix --file/--current with login args\t40\tfile + login args\tcannot mix file and login args'
  $'no active auth to save\t-\tno active auth'
  $'jq is required for usage output\t24\tjq needed\tjq needed for usage'
  $'jq is required for usage refresh\t24\tjq needed\tjq needed for refresh'
  $'jq is required for recovery\t24\tjq needed\tjq needed for recover'
  $'node needed for codex\t24\tnode needed\tnode needed for codex'
  $'codex command not found\t32\tcodex missing\tcodex command not found'
  $'auth change already running\t32\tauth busy\tauth change busy'
  $'could not hide active auth for login\t32\thide auth failed\tcould not hide active auth'
  $'login failed; restored previous auth\t32\tlogin failed; restored\tlogin failed; auth restored'
  $'login did not produce valid auth; restored previous auth\t32\tbad login auth; restored\tlogin auth invalid; restored'
  $'login did not produce valid auth\t32\tbad login auth\tlogin auth invalid'
  $'profile names may only use letters, numbers, dot, underscore, and dash\t28\tbad profile name\tbad name: A-Z 0-9 . _ -'
  $'usage: codex-auth list [-v]\t-\tusage: list [-v]'
  $'usage: codex-auth remove <name> --yes\t28\tremove name --yes\tusage: remove <name> --yes'
  $'usage: codex-auth import <name> <file>\t34\timport name file\tusage: import <name> <file>'
  $'usage: codex-auth export <name> <file>\t34\texport name file\tusage: export <name> <file>'
  $'usage: codex-auth save <name> [file]\t34\tsave name file\tusage: save <name> [file]'
  $'usage: codex-auth use <name>\t34\tuse name\tusage: use <name>'
  $'usage: codex-auth login <name> [codex login args...]\t28\tlogin needs name\tusage: login <name>'
)

COMPACT_ERROR_PREFIX_ROWS=(
  $'auth file not found: \tbase\t28\tmissing %s\tmissing file: %s'
  $'auth file is empty: \tbase\t28\tempty %s\tempty file: %s'
  $'not a Codex auth.json with OPENAI_API_KEY or tokens: \tbase\t28\tbad auth %s\tbad auth file: %s'
  $'export dir missing: \tdir'
  $'export path is a directory: \tbase\t60\texport path is dir\texport path is dir: %s'
  $'unknown command: \tcommand\t28\tunknown %s\tunknown %s; help\t. Use: codex-auth help'
  $'unknown usage option: \traw\t28\tbad opt %s\tunknown option %s'
  $'profile not found: \tprofile'
)

print_error() {
  local message="$*"
  local cols prefix indent current word candidate rendered line_prefix line_width
  local row source cutoff short wide table_prefix kind suffix tail value
  local compacted=0 wrote_line=0
  local words=()
  local line_prefixes=()

  cols="$(terminal_width)"
  if (( cols < 68 )); then
    for row in "${COMPACT_ERROR_STATIC_ROWS[@]}"; do
      IFS=$'\t' read -r source cutoff short wide <<<"$row"
      if [[ "$message" == "$source" ]]; then
        if [[ "$cutoff" == "-" ]]; then
          message="$short"
        elif (( cols < cutoff )); then
          message="$short"
        else
          message="$wide"
        fi
        compacted=1
        break
      fi
    done
    if (( ! compacted )); then
      for row in "${COMPACT_ERROR_PREFIX_ROWS[@]}"; do
        IFS=$'\t' read -r table_prefix kind cutoff short wide suffix <<<"$row"
        [[ "$message" == "$table_prefix"* ]] || continue
        tail="${message#"$table_prefix"}"
        case "$kind" in
          base)
            value="${tail##*/}"
            ;;
          dir)
            value="${tail##*/}"
            if (( cols < 24 )); then
              message='missing dir'
            elif (( cols < 28 )); then
              message="missing dir $value"
            else
              message="missing dir: $value"
            fi
            compacted=1
            break
            ;;
          command)
            value="${tail%"$suffix"}"
            ;;
          raw)
            value="$tail"
            ;;
          profile)
            if (( cols < 40 )); then
              value="$(fit_profile_text_rtrim "$tail" "$((cols - 15))")"
              message="missing $value"
            else
              message="not found: $tail"
            fi
            compacted=1
            break
            ;;
        esac
        if (( cols < cutoff )); then
          message="$(printf "$short" "$value")"
        else
          message="$(printf "$wide" "$value")"
        fi
        compacted=1
        break
      done
    fi
  fi
  if (( cols < 32 )) && [[ "$message" == usage:\ codex-auth\ * ]]; then
    message="usage:${message#usage: codex-auth}"
  fi
  if usage_unicode_enabled || (( cols < 30 )); then
    prefix='! '
  else
    prefix='error: '
  fi
  indent="$(printf '%*s' "${#prefix}" '')"
  line_prefixes=("$prefix" "$indent")
  current="$prefix"
  read -r -a words <<<"$message"

  for word in "${words[@]}"; do
    if (( ${#current} == ${#prefix} || ${#current} == ${#indent} )); then
      candidate="${current}${word}"
    else
      candidate="$current $word"
    fi

    if (( ${#candidate} <= cols )); then
      current="$candidate"
      continue
    fi

    if [[ "$current" != "$prefix" && "$current" != "$indent" ]]; then
      rendered="$(fit_text_rtrim "$current" "$cols")"
      printf '%s\n' "$rendered" >&2
      wrote_line=1
    fi

    if (( ${#prefix} + ${#word} > cols )); then
      line_prefix="${line_prefixes[$wrote_line]}"
      line_width=$((cols - ${#line_prefix}))
      line_width=$(( line_width < 1 ? 1 : line_width ))
      rendered="$(fit_profile_text_rtrim "$word" "$line_width")"
      printf '%s%s\n' "$line_prefix" "$rendered" >&2
      wrote_line=1
      current="$indent"
    else
      current="${indent}${word}"
    fi
  done

  if [[ "$current" != "$prefix" && "$current" != "$indent" ]]; then
    rendered="$(fit_text_rtrim "$current" "$cols")"
    printf '%s\n' "$rendered" >&2
  fi
}

print_empty_profiles() {
  local cols label_w value_w total_w command action saved_path

  cols="$(terminal_width)"
  IFS=$'\t' read -r label_w value_w <<<"$(detail_widths "$cols")"
  total_w=$((label_w + 1 + value_w))
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1

  print_palette_summary_header "Profiles" "no saved profiles" "$total_w"
  if [[ -f "$AUTH_FILE" ]]; then
    if (( total_w < 32 )); then
      command="current"
    else
      command="codex-auth add current --current"
    fi
    action="save"
  else
    command="codex-auth add <name>"
    action="login"
  fi
  print_detail_text_line "$action" "$(compact_command_display "$command" "$value_w")" "$label_w" "$value_w" active
  if (( value_w < 13 )); then
    saved_path="profiles"
  elif (( value_w < 18 )); then
    saved_path="$(basename "$PROFILE_DIR")"
  else
    saved_path="$(compact_display_path "$PROFILE_DIR" "$value_w")"
  fi
  print_detail_line "saved" "$saved_path" "$label_w" "$value_w" good
}

print_status_note() {
  local kind="$1"
  local detail="${2:-}"
  local cols line tone="muted" glyph compact_detail

  cols="$(terminal_width)"
  case "$kind" in
    refresh)
      if usage_unicode_enabled; then
        line="↻ refresh"
      else
        line="refresh"
      fi
      tone="accent"
      ;;
    ready)
      line="ready"
      tone="good"
      ;;
    blocked)
      line="! blocked"
      tone="bad"
      ;;
    cache)
      line="cache"
      tone="warn"
      ;;
    recover)
      if usage_unicode_enabled; then
        line="↳ recover"
      else
        line="recover"
      fi
      tone="accent"
      ;;
    roll)
      line="roll"
      tone="warn"
      ;;
    *)
      glyph="$(usage_glyph '·' '.')"
      line="$glyph $kind"
      ;;
  esac
  case "$kind:$detail" in
    "ready:already on best profile")
      if (( cols < 28 )); then
        line="already best"
      else
        line="already on best profile"
      fi
      detail=""
      ;;
    "blocked:no ready profile")
      line="! no ready profile"
      detail=""
      ;;
    "blocked:choose switch/login/skip")
      line="! choose row"
      detail=""
      ;;
    "cache:refresh busy")
      detail="busy"
      ;;
    "roll:usage limit, rotating")
      line="roll auth"
      (( cols >= 32 )) && detail="resume"
      ;;
  esac
  [[ -n "$detail" ]] && line+=" $detail"
  if (( ${#line} > cols )); then
    case "$kind:$detail" in
      "blocked:no ready profile")
        line="! no ready profile"
        ;;
      "ready:already on best profile")
        line="ready already best"
        ;;
      "recover:latest session")
        if usage_unicode_enabled; then
          line="↳ recover latest"
        else
          line="recover latest"
        fi
        ;;
      "recover:session "*)
        compact_detail="${detail#session }"
        if usage_unicode_enabled; then
          line="↳ recover $compact_detail"
        else
          line="recover $compact_detail"
        fi
        ;;
    esac
  fi

  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1
  usage_tone_color "$tone"
  fit_text_rtrim "$line" "$cols"
  usage_tone_reset
  printf '\n'
}

usage_summary_split_once() {
  local text="$1"
  local sep="$2"

  if [[ "$text" == *"$sep"* ]]; then
    printf '%s\t%s\n' "${text%%"$sep"*}" "${text#*"$sep"}"
  else
    printf '%s\t\n' "$text"
  fi
}

print_palette_title_line() {
  local label="$1"
  local right="$2"
  local total_w="$3"
  local sep left compact_label compact_left gap

  sep="$(usage_separator)"
  left="Auth$sep$label"
  if (( ${#left} > total_w || ( ${#right} > 0 && ${#left} + ${#right} + 2 > total_w ) )); then
    case "$label" in
      Codex\ profiles|Saved\ profiles) compact_label="Profiles" ;;
      Active\ profile) compact_label="Active" ;;
      Removed\ profile) compact_label="Removed" ;;
      *) compact_label="$label" ;;
    esac
    compact_left="Auth$sep$compact_label"
    if (( ${#compact_left} < ${#left} )); then
      left="$compact_left"
    fi
  fi
  if (( ${#right} > 0 && ${#left} + ${#right} + 2 <= total_w )); then
    usage_tone_color accent
    printf '%s' "$left"
    usage_tone_reset
    gap=$((total_w - ${#left} - ${#right}))
    printf '%*s' "$gap" ''
    usage_tone_color muted
    printf '%s' "$right"
    usage_tone_reset
    printf '\n'
    return 0
  fi

  usage_tone_color accent
  fit_text_rtrim "$left" "$total_w"
  usage_tone_reset
  printf '\n'
}

print_flat_context_line() {
  local summary="$1"
  local total_w="$2"
  local text sep token parts=()

  sep="$(usage_separator)"
  while [[ -n "$summary" ]]; do
    IFS=$'\t' read -r token summary <<<"$(usage_summary_split_once "$summary" "$sep")"
    token="${token//capped /cap }"
    [[ "$token" == cache\ * ]] && continue
    [[ -n "$token" ]] && parts+=("$token")
  done

  if (( ${#parts[@]} == 0 )); then
    text=""
  else
    text="${parts[0]}"
    local i
    for ((i = 1; i < ${#parts[@]}; i++)); do
      text+="   ${parts[$i]}"
    done
  fi
  print_toned_fit_rtrim "$text" "$total_w" muted
  printf '\n'
}

print_palette_summary_header() {
  local label="$1"
  local summary="$2"
  local total_w="$3"
  local mode="${4:-flat}"
  local gap="${5:-1}"
  local right="" sep token rest

  sep="$(usage_separator)"
  rest="$summary"
  while [[ -n "$rest" ]]; do
    IFS=$'\t' read -r token rest <<<"$(usage_summary_split_once "$rest" "$sep")"
    token="${token//capped /cap }"
    if [[ "$token" == cache\ * ]]; then
      right="$token"
      break
    fi
  done
  print_palette_title_line "$label" "$right" "$total_w"
  if [[ "$mode" != "usage" ]]; then
    print_flat_context_line "$summary" "$total_w"
  fi
  if (( gap )); then
    printf '\n'
  fi
}

