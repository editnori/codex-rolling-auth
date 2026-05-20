# shellcheck shell=bash

MENU_ACTION=""
MENU_PROFILE=""

print_selector_row() {
  local action="$1"
  local profile="$2"
  local detail="$3"
  local action_w="$4"
  local profile_w="$5"
  local total_w="$6"
  local detail_w

  detail_w=$((total_w - action_w - profile_w - 2))
  (( detail_w < 1 )) && detail_w=1
  fit_text "$action" "$action_w"
  printf ' '
  fit_profile_text "$profile" "$profile_w"
  printf ' '
  fit_text_rtrim "$detail" "$detail_w"
}

selector_palette_table_widths() {
  local total_w="$1"
  local primary_w week_w short_w status_w metric_w status_gap=1 metric_gap=1 status_max=13
  local row

  if (( total_w < 32 )); then
    primary_w=13
  elif (( total_w < 60 )); then
    primary_w=19
  elif (( total_w < 68 )); then
    primary_w=20
  elif (( total_w >= 108 )); then
    primary_w=28
  elif (( total_w >= 88 )); then
    primary_w=26
  elif (( total_w >= 68 )); then
    primary_w=22
  fi
  for row in 108:8 88:6 68:4 58:3 48:2; do
    if (( total_w >= ${row%%:*} )); then
      status_gap="${row#*:}"
      break
    fi
  done
  (( total_w >= 48 )) && metric_gap=2
  if (( total_w < 58 )); then
    status_max=12
  fi
  if (( total_w < 24 )); then
    primary_w=$((total_w - 5))
    primary_w=$(( primary_w < 11 ? 11 : primary_w ))
    week_w=0
    short_w=4
    status_w=0
  else
    if (( total_w >= 108 )); then
      metric_w=23
    elif (( total_w >= 88 )); then
      metric_w=19
    elif (( total_w >= 68 )); then
      metric_w=13
    else
      metric_w=5
    fi
    week_w="$metric_w"
    short_w=$(( total_w < 50 ? 3 : metric_w ))
    status_w=$((total_w - primary_w - 1 - week_w - metric_gap - short_w - status_gap))
    while (( status_w < 2 && metric_w > 5 )); do
      metric_w=$((metric_w - 1))
      week_w="$metric_w"
      short_w=$(( total_w < 50 ? 3 : metric_w ))
      status_w=$((total_w - primary_w - 1 - week_w - metric_gap - short_w - status_gap))
    done
    status_w=$(( status_w < 2 ? 2 : status_w > status_max ? status_max : status_w ))
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$primary_w" "$week_w" "$short_w" "$status_w" "$status_gap" "$metric_gap"
}

selector_palette_status_compact() {
  local status="$1"
  local width="${2:-0}"

  case "$status" in
    "no data"|"no usage"|"n/a")
      if (( width > 0 && width < 3 )); then printf 'na'; else printf '%s' "$status"; fi
      ;;
    "login needed")
      if (( width > 0 && width < 4 )); then
        printf 'log'
      elif (( width > 0 && width < 6 )); then
        printf 'auth'
      elif (( width > 0 && width < 13 )); then
        printf 'login'
      else
        printf '%s' "$status"
      fi
      ;;
    cap)
      if (( width > 0 && width < 3 )); then printf 'cp'; else printf '%s' "$status"; fi
      ;;
    "old cap"|"both cap")
      if (( width > 0 && width < 3 )); then
        printf 'cp'
      elif (( width > 0 && width < 7 )); then
        printf 'cap'
      else
        printf '%s' "$status"
      fi
      ;;
    ready)
      if (( width > 0 && width < 5 )); then printf 'ok'; else printf '%s' "$status"; fi
      ;;
    offline)
      if (( width > 0 && width < 3 )); then
        printf 'of'
      elif (( width > 0 && width < 7 )); then
        printf 'off'
      else
        printf '%s' "$status"
      fi
      ;;
    same)
      if (( width > 0 && width < 4 )); then printf '='; else printf '%s' "$status"; fi
      ;;
    *)
      printf '%s' "$status"
      ;;
  esac
}

selector_palette_table_widths_into() {
  local -n primary_ref="$1"
  local -n week_ref="$2"
  local -n short_ref="$3"
  local -n status_ref="$4"
  local -n status_gap_ref="$5"
  local -n metric_gap_ref="$6"
  local total_w="$7"
  local metric_w row status_max=13

  primary_ref=0
  week_ref=0
  short_ref=0
  status_ref=0
  status_gap_ref=1
  metric_gap_ref=1
  if (( total_w < 32 )); then
    primary_ref=13
  elif (( total_w < 60 )); then
    primary_ref=19
  elif (( total_w < 68 )); then
    primary_ref=20
  elif (( total_w >= 108 )); then
    primary_ref=28
  elif (( total_w >= 88 )); then
    primary_ref=26
  elif (( total_w >= 68 )); then
    primary_ref=22
  fi
  for row in 108:8 88:6 68:4 58:3 48:2; do
    if (( total_w >= ${row%%:*} )); then
      status_gap_ref="${row#*:}"
      break
    fi
  done
  (( total_w >= 48 )) && metric_gap_ref=2
  (( total_w < 58 )) && status_max=12
  if (( total_w < 24 )); then
    primary_ref=$((total_w - 5))
    primary_ref=$(( primary_ref < 11 ? 11 : primary_ref ))
    week_ref=0
    short_ref=4
    status_ref=0
    return 0
  fi

  if (( total_w >= 108 )); then
    metric_w=23
  elif (( total_w >= 88 )); then
    metric_w=19
  elif (( total_w >= 68 )); then
    metric_w=13
  else
    metric_w=5
  fi
  week_ref="$metric_w"
  short_ref=$(( total_w < 50 ? 3 : metric_w ))
  status_ref=$((total_w - primary_ref - 1 - week_ref - metric_gap_ref - short_ref - status_gap_ref))
  while (( status_ref < 2 && metric_w > 5 )); do
    metric_w=$((metric_w - 1))
    week_ref="$metric_w"
    short_ref=$(( total_w < 50 ? 3 : metric_w ))
    status_ref=$((total_w - primary_ref - 1 - week_ref - metric_gap_ref - short_ref - status_gap_ref))
  done
  status_ref=$(( status_ref < 2 ? 2 : status_ref > status_max ? status_max : status_ref ))
}

selector_fast_fit_into() {
  local -n out_ref="$1"
  local text="$2"
  local width="$3"
  local align="${4:-left}"
  local trunc="…"
  local pad left right

  out_ref=""
  (( width <= 0 )) && return 0
  [[ "${CODEX_AUTH_ASCII:-0}" == "1" ]] && trunc="~"
  if (( ${#text} > width )); then
    if (( width == 1 )); then
      text="$trunc"
    else
      text="${text:0:width-1}${trunc}"
    fi
  fi
  pad=$((width - ${#text}))
  (( pad < 0 )) && pad=0
  case "$align" in
    right)
      printf -v out_ref '%*s%s' "$pad" '' "$text"
      ;;
    center)
      left=$(((pad + 1) / 2))
      right=$((pad - left))
      printf -v out_ref '%*s%s%*s' "$left" '' "$text" "$right" ''
      ;;
    *)
      printf -v out_ref '%s%*s' "$text" "$pad" ''
      ;;
  esac
}

selector_usage_display_profile_name_into() {
  local -n out_ref="$1"
  local profile="$2"
  local role="${3:-}"
  local width="${4:-0}"
  local suffix compact

  if [[ "$profile" == "current" && "$role" != "active" && "$role" != "●" && "$role" != "*" ]]; then
    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && "$width" -lt 7 ]]; then
      out_ref="cur"
    else
      out_ref="current"
    fi
  elif [[ "$profile" == "Layth" && "$width" =~ ^[0-9]+$ && "$width" -gt 0 && "$width" -lt 5 ]]; then
    out_ref="Lay"
  elif [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#profile} -gt width && "$profile" =~ ^Layth([0-9]+)$ ]]; then
    suffix="${BASH_REMATCH[1]}"
    compact="L$suffix"
    if (( ${#compact} <= width )); then out_ref="$compact"; else out_ref="${suffix:0:width}"; fi
  elif [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#profile} -gt width && "$profile" == Layth.* ]]; then
    suffix="${profile#Layth.}"
    if (( ${#suffix} <= width )); then out_ref="$suffix"; else out_ref="$profile"; fi
  else
    out_ref="$profile"
  fi
}

selector_fast_display_status_into() {
  local -n out_ref="$1"
  local status="$2"

  if [[ "$status" == stale\ * ]]; then
    status="${status#stale }"
    if [[ "$status" == *cap ]]; then out_ref="old cap"; else out_ref="stale"; fi
  elif [[ "$status" == "week+5h cap" || "$status" == "week cap" || "$status" == "5h cap" ]]; then
    out_ref="cap"
  else
    case "$status" in
      ok) out_ref="ready" ;;
      login) out_ref="login" ;;
      *) out_ref="$status" ;;
    esac
  fi
}

selector_fast_compact_status_into() {
  local -n out_ref="$1"
  local status="$2"
  local width="$3"

  case "$status" in
    "no data"|"no usage"|"n/a")
      if (( width > 0 && width < 3 )); then out_ref="na"; else out_ref="$status"; fi
      ;;
    "login needed")
      if (( width > 0 && width < 4 )); then out_ref="log"; elif (( width > 0 && width < 6 )); then out_ref="auth"; elif (( width > 0 && width < 13 )); then out_ref="login"; else out_ref="$status"; fi
      ;;
    cap)
      if (( width > 0 && width < 3 )); then out_ref="cp"; else out_ref="$status"; fi
      ;;
    "old cap"|"both cap")
      if (( width > 0 && width < 3 )); then out_ref="cp"; elif (( width > 0 && width < 7 )); then out_ref="cap"; else out_ref="$status"; fi
      ;;
    ready)
      if (( width > 0 && width < 5 )); then out_ref="ok"; else out_ref="$status"; fi
      ;;
    offline)
      if (( width > 0 && width < 3 )); then out_ref="of"; elif (( width > 0 && width < 7 )); then out_ref="off"; else out_ref="$status"; fi
      ;;
    same)
      if (( width > 0 && width < 4 )); then out_ref="="; else out_ref="$status"; fi
      ;;
    *)
      out_ref="$status"
      ;;
  esac
}

selector_palette_row_into() {
  local -n out_ref="$1"
  local primary="$2"
  local weekly="$3"
  local short="$4"
  local status="$5"
  local _raw_status="$6"
  local valid="$7"
  local total_w="$8"
  local primary_w week_w short_w status_w status_gap metric_gap
  local action profile action_cell profile_cell primary_cell week_cell short_cell status_cell compact_status spaces

  selector_palette_table_widths_into primary_w week_w short_w status_w status_gap metric_gap "$total_w"
  action="${primary%% *}"
  profile="${primary#* }"
  [[ "$profile" == "$primary" ]] && profile=""
  [[ "$action" == "best" ]] && action="use"
  selector_fast_fit_into action_cell "$action" 5 left
  if (( primary_w <= 7 )); then
    selector_fast_fit_into primary_cell "$action" "$primary_w" left
  else
    selector_usage_display_profile_name_into profile_cell "$profile" "$action" "$((primary_w - 7))"
    selector_fast_fit_into profile_cell "$profile_cell" "$((primary_w - 7))" left
    primary_cell="${action_cell}  ${profile_cell}"
  fi

  if [[ "$valid" == "0" ]]; then
    selector_fast_fit_into week_cell "${weekly:--}" "$week_w" center
    selector_fast_fit_into short_cell "${short:--}" "$short_w" center
  else
    selector_fast_fit_into week_cell "-" "$week_w" center
    selector_fast_fit_into short_cell "-" "$short_w" center
  fi
  selector_fast_compact_status_into compact_status "$status" "$status_w"
  selector_fast_fit_into status_cell "$compact_status" "$status_w" left
  printf -v spaces '%*s' "$metric_gap" ''
  out_ref="${primary_cell} ${week_cell}${spaces}${short_cell}"
  if (( status_w > 0 )); then
    printf -v spaces '%*s' "$status_gap" ''
    out_ref+="${spaces}${status_cell}"
  fi
}

selector_menu_row_for_record_into() {
  local -n out_ref="$1"
  shift
  local default_profile="$1"
  local selector_palette_mode="$2"
  local mode="$3"
  local role_w="$4"
  local profile_w="$5"
  local cell_w="$6"
  local status_w="$7"
  local bar_width="$8"
  local total_w="$9"
  local record="${10}"
  local valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age
  local display display_status palette_profile action_role row_action row_profile_field active_row=0

  if (( ! selector_palette_mode )); then
    out_ref="$(selector_menu_row_for_record "$default_profile" "$selector_palette_mode" "$mode" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width" "$total_w" "$record")"
    return $?
  fi

  IFS=$'\t' read -r valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age <<<"$record"
  [[ -n "$profile" ]] || return 1
  row_action="switch"
  row_profile_field="$profile"
  if (( total_w <= 30 )); then
    selector_usage_display_profile_name_into palette_profile "$profile" "" 6
  else
    palette_profile="$profile"
  fi

  if [[ "$valid" != "0" && "$status" == "login" ]]; then
    selector_palette_row_into display "login $palette_profile" "-" "-" "login needed" "$status" "$valid" "$total_w"
    row_action="login"
  elif [[ "$valid" == "0" ]]; then
    selector_fast_display_status_into display_status "$status"
    if [[ "$mark" == "*" ]]; then
      action_role="stay"
    elif [[ "$mark" == "=" ]]; then
      action_role="same"
    else
      case "$display_status" in
        ready|ok) if [[ -n "$default_profile" && "$profile" == "$default_profile" ]]; then action_role="best"; else action_role="use"; fi ;;
        cap|old\ cap|both\ cap) action_role="cap" ;;
        *) action_role="warn" ;;
      esac
    fi
    selector_palette_row_into display "$action_role $palette_profile" "$weekly" "$short" "$display_status" "$status" "$valid" "$total_w"
  else
    selector_fast_display_status_into display_status "$status"
    case "$mark" in
      "*") action_role="stay" ;;
      "=") action_role="same" ;;
      *) action_role="use" ;;
    esac
    selector_palette_row_into display "$action_role $palette_profile" "-" "-" "$display_status" "$status" "$valid" "$total_w"
  fi
  if [[ "$row_action" == "switch" && ( "$mark" == "*" || "$mark" == "=" ) ]]; then
    active_row=1
    row_action="skip"
    row_profile_field="-"
  fi

  printf -v out_ref '%s\037action\037%s\037%s\037%s' "$active_row" "$row_action" "$row_profile_field" "$display"
}

selector_palette_metric_cell() {
  local percent="$1"
  local width="$2"
  local tone bar_w label label_w=4
  local value bg_style units full partial used
  local bar_border_glyph="▁"
  local partial_glyphs=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")

  (( width <= 0 )) && return 0
  [[ -n "$percent" ]] || percent="-"
  label="${percent%\%}"
  tone="$(usage_limit_tone "$percent")"

  if [[ "$percent" == "-" ]]; then
    usage_tone_color muted
    if (( width < 8 )); then
      fit_text_center "-" "$width"
    else
      printf '%3s' "-"
      printf '%*s' "$((width - 3))" ''
    fi
    usage_tone_reset
    return 0
  fi

  usage_tone_color "$tone"
  if (( width < 8 )); then
    fit_text_center "$label" "$width"
    usage_tone_reset
    return 0
  fi
  if (( width >= 18 )); then
    label_w=5
  fi
  fit_text_center "$label" "$label_w"
  usage_tone_reset
  printf ' '
  bar_w=$((width - label_w - 1))
  (( bar_w < 0 )) && bar_w=0
  bg_style="${CODEX_AUTH_SELECTOR_BAR_STYLE:-bg}"
  if value="$(usage_clamped_percent "$percent")"; then
    if usage_unicode_enabled; then
      units=$(((value * bar_w * 8 + 50) / 100))
      full=$((units / 8))
      partial=$((units % 8))
      if (( full >= bar_w )); then
        full="$bar_w"
        partial=0
      fi
      used="$full"
      (( partial > 0 && used < bar_w )) && used=$((used + 1))
    else
      full=$(((value * bar_w + 50) / 100))
      (( full > bar_w )) && full="$bar_w"
      partial=0
      used="$full"
    fi
    if usage_color_active && [[ "$bg_style" == "bg" ]]; then
      if (( used > 0 )); then
        usage_tone_code 48 "$tone"
        usage_tone_color track_edge
        repeat_glyph "$bar_border_glyph" "$used"
        usage_tone_reset
      fi
      if (( bar_w > used )); then
        usage_tone_code 48 track
        usage_tone_color track_edge
        repeat_glyph "$bar_border_glyph" "$((bar_w - used))"
        usage_tone_reset
      fi
    elif usage_unicode_enabled; then
      usage_tone_color "$tone"
      repeat_glyph "█" "$full"
      (( partial > 0 && full < bar_w )) && printf '%s' "${partial_glyphs[$partial]}"
      usage_tone_reset
      (( bar_w > used )) && printf '%*s' "$((bar_w - used))" ''
    else
      usage_tone_color "$tone"
      repeat_glyph "#" "$full"
      usage_tone_reset
      (( bar_w > used )) && printf '%*s' "$((bar_w - used))" ''
    fi
    return 0
  elif usage_color_active && [[ "$bg_style" == "bg" ]]; then
    usage_tone_code 48 track
    usage_tone_color track_edge
    repeat_glyph "$bar_border_glyph" "$bar_w"
    usage_tone_reset
  else
    printf '%*s' "$bar_w" ''
  fi
}

selector_palette_table_header() {
  local total_w="$1"
  local primary_w week_w short_w status_w short_label status_label status_gap metric_gap
  local action_w=5 primary_gap=2 primary_profile_w profile_label

  IFS=$'\t' read -r primary_w week_w short_w status_w status_gap metric_gap <<<"$(selector_palette_table_widths "$total_w")"
  short_label="${USAGE_SHORT_LABEL:-5h}"
  [[ -n "$short_label" && "$short_label" != "short" ]] || short_label="5h"
  short_label="${short_label}%"
  status_label="status"
  if (( status_w > 0 && status_w < 7 )); then
    status_label="st"
  fi

  primary_profile_w=$((primary_w - action_w - primary_gap))
  (( primary_profile_w < 1 )) && primary_profile_w=1
  if (( primary_profile_w <= 6 )); then
    profile_label="name"
  else
    profile_label="profile"
  fi
  print_toned_fit_center "act" "$action_w" muted
  printf '%*s' "$primary_gap" ''
  print_toned_fit_center "$profile_label" "$primary_profile_w" muted
  printf ' '
  if (( week_w > 0 )); then
    usage_tone_color muted
    usage_metric_header_cell "week%" "$week_w" 1
    usage_tone_reset
    printf '%*s' "$metric_gap" ''
  fi
  usage_tone_color muted
  usage_metric_header_cell "$short_label" "$short_w" 1
  usage_tone_reset
  if (( status_w > 0 )); then
    printf '%*s' "$status_gap" ''
    print_toned_fit_center "$status_label" "$status_w" muted
  fi
  printf '\n'
}

print_selector_palette_table_row() {
  local primary="$1"
  local weekly="$2"
  local short="$3"
  local status="$4"
  local raw_status="$5"
  local valid="$6"
  local total_w="$7"
  local primary_w week_w short_w status_w compact_status status_gap metric_gap
  local primary_action primary_display_action primary_profile primary_action_w primary_profile_w primary_render primary_gap primary_tone

  IFS=$'\t' read -r primary_w week_w short_w status_w status_gap metric_gap <<<"$(selector_palette_table_widths "$total_w")"
  if (( primary_w > 0 )); then
    primary_action="${primary%% *}"
    if [[ "$primary" == "$primary_action" ]]; then
      fit_profile_text "$primary" "$primary_w"
    else
      primary_profile="${primary#* }"
      case "$primary_action" in
        best|stay|use|same|cap|login|warn)
          primary_display_action="$primary_action"
          [[ "$primary_action" == "best" ]] && primary_display_action="use"
          primary_tone="$(usage_role_tone "$primary_action")"
          [[ "$primary_action" == "warn" ]] && primary_tone="warn"
          primary_action_w=5
          primary_gap=2
          if (( primary_action_w + primary_gap >= primary_w )); then
            usage_tone_color "$primary_tone"
            fit_text "$primary_display_action" "$primary_w"
            usage_tone_reset
          else
            usage_tone_color "$primary_tone"
            fit_text "$primary_display_action" "$primary_action_w"
            usage_tone_reset
            printf '%*s' "$primary_gap" ''
            primary_profile_w=$((primary_w - primary_action_w - primary_gap))
            primary_render="$(usage_display_profile_name "$primary_profile" "$primary_action" "$primary_profile_w")"
            fit_profile_text "$primary_render" "$primary_profile_w"
          fi
          ;;
        *)
          fit_profile_text "$primary" "$primary_w"
          ;;
      esac
    fi
  fi
  printf ' '

  if (( week_w == 0 )); then
    if [[ "$valid" == "0" ]]; then
      selector_palette_metric_cell "$short" "$short_w"
    else
      compact_status="$(selector_palette_status_compact "$status" "$short_w")"
      print_toned_fit_center "$compact_status" "$short_w" "$(usage_status_tone "$raw_status" "$valid")"
    fi
    return 0
  fi

  compact_status="$(selector_palette_status_compact "$status" "$status_w")"
  if [[ "$valid" == "0" ]]; then
    selector_palette_metric_cell "$weekly" "$week_w"
    printf '%*s' "$metric_gap" ''
    selector_palette_metric_cell "$short" "$short_w"
  else
    selector_palette_metric_cell "-" "$week_w"
    printf '%*s' "$metric_gap" ''
    selector_palette_metric_cell "-" "$short_w"
  fi
  printf '%*s' "$status_gap" ''
  print_toned_fit "$compact_status" "$status_w" "$(usage_status_tone "$raw_status" "$valid")"
}

selector_action_role() {
  local action="$1"
  local role_w="$2"

  if (( role_w <= 1 )); then
    case "$action" in
      switch) printf ' ' ;;
      best) printf 'u' ;;
      cap) printf 'c' ;;
      login) printf 'l' ;;
      stay) usage_glyph '●' '*' ;;
      *) usage_glyph '·' '.' ;;
    esac
  elif (( role_w < 6 )); then
    case "$action" in
      best|switch) printf 'use' ;;
      cap) printf 'cap' ;;
      same) printf 'same' ;;
      login) printf 'login' ;;
      *) printf 'stay' ;;
    esac
  else
    case "$action" in
      switch|best) printf 'use' ;;
      same) printf 'same' ;;
      *) printf '%s' "$action" ;;
    esac
  fi
}

selector_header_meta_line() {
  local label="$1"
  local text="$2"
  local total_w="$3"
  local label_w="$4"
  local value_w value label_tone="muted"
  local sep name detail name_w detail_w

  if [[ -z "$label" ]]; then
    label="status"
    if [[ "$text" == "best "* ]]; then
      label="best"
      text="${text#best }"
    elif [[ "$text" == "active "* ]]; then
      label="active"
      text="${text#active }"
    elif [[ "$text" == "old "* ]]; then
      label="old"
      text="${text#old }"
    fi
  fi

  (( label_w < 1 )) && label_w=1
  value_w=$((total_w - label_w - 2))
  (( value_w < 1 )) && value_w=1
  case "$label" in
    best|active|old|status)
      IFS=' ' read -r name detail <<<"$text"
      if [[ -z "$detail" || ! "$value_w" =~ ^[0-9]+$ || "$value_w" -lt 18 ]]; then
        value="$text"
      else
        name_w=12
        (( value_w < 34 )) && name_w=10
        (( value_w < 26 )) && name_w=8
        if (( name_w > value_w - 8 )); then
          name_w=$((value_w - 8))
        fi
        if (( name_w < 6 )); then
          value="$text"
        else
          detail_w=$((value_w - name_w - 2))
          (( detail_w < 1 )) && detail_w=1
          value="$(fit_profile_text "$name" "$name_w"; printf '  '; fit_text "$detail" "$detail_w")"
        fi
      fi
      ;;
    *)
      sep="$(usage_separator)"
      value="${text//capped /cap }"
      detail=""
      while [[ "$value" == *"$sep"* ]]; do
        detail+="${value%%"$sep"*}   "
        value="${value#*"$sep"}"
      done
      value="$detail$value"
      ;;
  esac
  case "$label" in
    best) label_tone="accent" ;;
    active) label_tone="active" ;;
    old) label_tone="warn" ;;
  esac

  print_toned_fit "$label" "$label_w" "$label_tone"
  printf '  '
  fit_text "$value" "$value_w"
  printf '\n'
}

usage_summary_parts() {
  local summary="$1"
  local total_w="$2"
  local merge_pool_subject="${3:-0}"
  local sep first rest active_part="" next_part pool_head candidate value_candidate best_subject

  sep="$(usage_separator)"
  IFS=$'\t' read -r first rest <<<"$(usage_summary_split_once "$summary" "$sep")"
  case "$first" in
    best|"best active"|"best is active")
      if [[ -n "$rest" ]]; then
        IFS=$'\t' read -r next_part rest <<<"$(usage_summary_split_once "$rest" "$sep")"
        first="$first $next_part"
      fi
      ;;
  esac
  if [[ "$first" == "best active "* ]]; then
    best_subject="${first#best active }"
    first="best $best_subject"
  elif [[ "$first" == "best is active "* ]]; then
    best_subject="${first#best is active }"
    first="best $best_subject"
  fi
  if [[ -n "$rest" ]]; then
    IFS=$'\t' read -r pool_head next_part <<<"$(usage_summary_split_once "$rest" "$sep")"
    if [[ "$pool_head" == "active "* || "$pool_head" == "no active" ]]; then
      active_part="$pool_head"
      rest="$next_part"
    fi
  fi
  if (( merge_pool_subject )) && [[ -n "$rest" && -z "$active_part" ]]; then
    IFS=$'\t' read -r pool_head next_part <<<"$(usage_summary_split_once "$rest" "$sep")"
    case "$pool_head" in
      ready*|capped*|cap*|login*|"no data"*|offline*|stale*|cache*) ;;
      *)
        candidate="$first $pool_head"
        value_candidate="$candidate"
        [[ "$candidate" == "best "* ]] && value_candidate="${candidate#best }"
        if (( ${#value_candidate} <= total_w - 7 )); then
          first="$candidate"
          rest="$next_part"
        fi
        ;;
    esac
  fi
  printf '%s\037%s\037%s\n' "$first" "$active_part" "$rest"
}

selector_palette_controls_line() {
  local fallback="$1"
  local total_w="$2"
  local left left_compact left_short left_tiny right compact sep tiny_controls tiny_line
  local control_pair candidate_left candidate_right selected=0

  sep="$(usage_separator)"
  left="Auth${sep}Codex profiles"
  left_compact="Auth${sep}profiles"
  left_short="Auth${sep}prof"
  left_tiny="Auth"
  right="enter select${sep}esc stay"
  compact="enter${sep}esc"
  case "$fallback" in
    number*|num*|[0-9]*)
      right="$fallback"
      compact="$fallback"
      ;;
  esac

  for control_pair in "$left"$'\t'"$right" "$left_compact"$'\t'"$compact" "$left_short"$'\t'"$compact" "$left_tiny"$'\t'"$compact"; do
    IFS=$'\t' read -r candidate_left candidate_right <<<"$control_pair"
    if (( ${#candidate_left} + ${#candidate_right} + 3 <= total_w )); then
      left="$candidate_left"
      right="$candidate_right"
      selected=1
      break
    fi
  done

  if (( ! selected )); then
    tiny_controls="$compact"
    tiny_controls="${tiny_controls//$sep/ }"
    if (( ${#left_tiny} + ${#tiny_controls} + 3 > total_w )); then
      tiny_controls="${tiny_controls/ q stay/ q}"
    fi
    tiny_line="$left_tiny$sep$tiny_controls"
    fit_text_rtrim "$tiny_line" "$total_w"
    return 0
  fi

  if usage_color_active; then
    usage_tone_color accent
    printf '%s' "$left"
    usage_tone_reset
    printf '   '
    usage_tone_color muted
    printf '%s' "$right"
    usage_tone_reset
  else
    printf '%s   %s' "$left" "$right"
  fi
}

selector_fzf_menu() {
  local -n rows_ref="$1"
  local summary_text="$2"
  local total_w="$3"
  local role_w="$4"
  local profile_w="$5"
  local cell_w="$6"
  local status_w="$7"
  local mode="$8"
  local selector_palette_mode="$9"
  local choice kind action profile_choice fzf_prompt fzf_pointer fzf_header term_lines fzf_term
  local fzf_height fzf_height_arg fzf_outer_top_padding=0 fzf_pad_i
  local fzf_header_line_count=1
  local fzf_color_args=()
  local fzf_border_args=()
  local fzf_margin_args=()
  local fzf_padding_args=()
  local fzf_header_args=()
  local fzf_opencode_theme=0
  local selector_controls selector_control_sep max_height
  local fzf_color_arg
  local fzf_codex_colors='dark,fg:#eeeeee,fg+:#f4f0e8,bg:#141414,bg+:#262626,hl:#fab283,hl+:#ffd0a0,border:#323232,label:#fab283,prompt:#fab283,pointer:#fab283,header:#9a9a9a,info:#808080,gutter:#141414'
  local fzf_header_line action_label
  local palette_effective_w right_margin terminal_w primary_w week_w short_w palette_status_w status_gap metric_gap
  local fzf_vertical_padding=0

  fzf_height=$((${#rows_ref[@]} + 8))
  (( fzf_height < 12 )) && fzf_height=12
  term_lines="${LINES:-}"
  [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines="$(tput lines 2>/dev/null || true)"
  if [[ "$term_lines" =~ ^[0-9]+$ ]]; then
    max_height=$((term_lines - 2))
    (( max_height < 12 )) && max_height=12
    (( fzf_height > max_height )) && fzf_height="$max_height"
  elif (( fzf_height > 24 )); then
    fzf_height=24
  fi

  fzf_color_arg=""
  if [[ -n "${CODEX_AUTH_FZF_THEME:-}" ]]; then
    if [[ "$CODEX_AUTH_FZF_THEME" == "codex" || "$CODEX_AUTH_FZF_THEME" == "1" ]]; then
      fzf_color_arg="$fzf_codex_colors"
      fzf_opencode_theme=1
    else
      fzf_color_arg="$CODEX_AUTH_FZF_THEME"
    fi
  elif (( selector_palette_mode )); then
    if usage_color_active; then
      fzf_color_arg="$fzf_codex_colors"
    else
      fzf_color_arg="bw"
    fi
    fzf_opencode_theme=1
  fi
  [[ -n "$fzf_color_arg" ]] && fzf_color_args+=(--color="$fzf_color_arg")
  fzf_height_arg="~$fzf_height"
  selector_control_sep="$(usage_separator)"
  if usage_unicode_enabled; then
    fzf_prompt='filter ▸ '
    fzf_pointer='▸'
  else
    fzf_prompt='filter > '
    fzf_pointer='>'
  fi
  if (( total_w < 32 )); then
    selector_controls="enter${selector_control_sep}esc stay${selector_control_sep}filter"
  else
    selector_controls="enter select${selector_control_sep}esc stay${selector_control_sep}type filter"
  fi
  if (( fzf_opencode_theme )); then
    fzf_pointer=' '
    fzf_prompt='filter '
    terminal_w="$(terminal_width)"
    IFS=$'\t' read -r primary_w week_w short_w palette_status_w status_gap metric_gap <<<"$(selector_palette_table_widths "$total_w")"
    if (( week_w == 0 )); then
      palette_effective_w=$((primary_w + 1 + short_w))
    else
      palette_effective_w=$((primary_w + 1 + week_w + metric_gap + short_w))
      if (( palette_status_w > 0 )); then
        palette_effective_w=$((palette_effective_w + status_gap + palette_status_w))
      fi
    fi
    right_margin=$((terminal_w - palette_effective_w - 4))
    if (( right_margin > 0 )); then
      fzf_margin_args+=(--margin="0,$right_margin,0,0")
    fi
    fzf_border_args+=(--border=none)
  else
    fzf_border_args+=(--border=rounded --border-label=' auth profiles ' --border-label-pos=3)
  fi
  if (( fzf_opencode_theme )); then
    fzf_header="$(
      selector_palette_controls_line "$selector_controls" "$total_w"
      printf '\n'
      selector_palette_table_header "$total_w"
    )"
    fzf_header_line_count=0
    while IFS= read -r fzf_header_line; do
      fzf_header_line_count=$((fzf_header_line_count + 1))
    done <<<"$fzf_header"
    (( fzf_header_line_count < 1 )) && fzf_header_line_count=1
    fzf_height=$((${#rows_ref[@]} + fzf_header_line_count + 1))
    if [[ "$term_lines" =~ ^[0-9]+$ ]]; then
      max_height=$((term_lines - 2))
      max_height=$(( max_height < 6 ? 6 : max_height ))
      if (( fzf_height + 2 <= max_height )); then
        fzf_height=$((fzf_height + 2))
        fzf_vertical_padding=1
      fi
      fzf_height=$(( fzf_height > max_height ? max_height : fzf_height ))
    elif (( fzf_height < 22 )); then
      fzf_height=$((fzf_height + 2))
      fzf_vertical_padding=1
    fi
    if (( fzf_vertical_padding )); then
      fzf_padding_args+=(--padding=1,0,1,0)
    fi
    if [[ "${CODEX_AUTH_SELECTOR_CENTER:-0}" == "1" && "$term_lines" =~ ^[0-9]+$ ]] && (( term_lines > fzf_height + 1 )); then
      fzf_outer_top_padding=$(((term_lines - fzf_height) / 2))
    fi
    fzf_height_arg="~$fzf_height"
    fzf_header_args+=(--header-lines="$fzf_header_line_count" --header-first)
  else
    action_label="action"
    if (( role_w <= 1 )); then
      action_label=" "
    elif (( role_w < 6 )); then
      action_label="act"
    fi
    fzf_header="$(
      IFS=$'\037' read -r first active_part pool_part <<<"$(usage_summary_parts "$summary_text" "$total_w" 1)"
      label_w=5
      show_active=0
      show_pool=0
      blank_after=0
      if (( total_w >= 64 )); then
        label_w=7
        show_active=1
        show_pool=1
        blank_after=1
      elif (( total_w >= 40 )); then
        label_w=6
        show_active=1
        blank_after=1
      fi
      selector_header_meta_line "" "$first" "$total_w" "$label_w"
      if (( show_active )) && [[ -n "$active_part" ]]; then
        selector_header_meta_line "" "$active_part" "$total_w" "$label_w"
      fi
      if (( show_pool )) && [[ -n "$pool_part" ]]; then
        selector_header_meta_line "stats" "$pool_part" "$total_w" "$label_w"
      fi
      (( blank_after )) && printf '\n'
      print_usage_render_header "$action_label" "$role_w" "$profile_w" "$cell_w" "$status_w" "$mode"
      repeat_glyph "$(usage_glyph '─' '-')" "$total_w"
      printf '\n'
      fit_text_rtrim "$selector_controls" "$total_w"
    )"
    fzf_header_args+=(--header="$fzf_header")
  fi

  for ((fzf_pad_i = 0; fzf_pad_i < fzf_outer_top_padding; fzf_pad_i++)); do
    printf '\n'
  done

  fzf_term="${TERM:-}"
  [[ -n "$fzf_term" && "$fzf_term" != "dumb" ]] || fzf_term="xterm-256color"

  choice="$(
    {
      if (( fzf_opencode_theme )); then
        while IFS= read -r fzf_header_line; do
          printf 'header\tnoop\t-\t%s\n' "$fzf_header_line"
        done <<<"$fzf_header"
      fi
      printf '%s\n' "${rows_ref[@]}"
    } | TERM="$fzf_term" fzf \
      --ansi \
      --no-sort \
      --layout=reverse \
      --height="$fzf_height_arg" \
      "${fzf_border_args[@]}" \
      "${fzf_margin_args[@]}" \
      "${fzf_padding_args[@]}" \
      --prompt="$fzf_prompt" \
      --pointer="$fzf_pointer" \
      --marker=' ' \
      --info=hidden \
      --no-scrollbar \
      --no-separator \
      --ellipsis='' \
      "${fzf_header_args[@]}" \
      --delimiter=$'\t' \
      --with-nth=4.. \
      --bind='esc:abort,ctrl-q:abort' \
      --no-multi \
      --cycle \
      --tiebreak=index \
      "${fzf_color_args[@]}"
  )" || {
    MENU_ACTION="skip"
    MENU_PROFILE=""
    return 0
  }

  IFS=$'\t' read -r kind action profile_choice display <<<"$choice"
  [[ "$profile_choice" == "-" ]] && profile_choice=""
  if [[ "$action" == "switch" || "$action" == "login" || "$action" == "skip" ]]; then
    MENU_ACTION="$action"
    MENU_PROFILE="$profile_choice"
  else
    MENU_ACTION="blocked"
    MENU_PROFILE=""
  fi
}

selector_numbered_menu() {
  local -n rows_ref="$1"
  local summary_text="$2"
  local total_w="$3"
  local choice i action_count=0 cols
  local kind action profile_choice display line_w prefix plain
  local term_lines fallback_height fallback_top_padding=0 fallback_pad_i
  local selector_controls sep
  local selected=0
  local fallback_actions=()
  local fallback_profiles=()

  cols="$(terminal_width)"
  term_lines="${LINES:-}"
  [[ "$term_lines" =~ ^[0-9]+$ ]] || term_lines="$(tput lines 2>/dev/null || true)"
  sep="$(usage_separator)"
  if (( cols < 36 )); then
    selector_controls="1-${#rows_ref[@]}${sep}q stay"
  else
    selector_controls="1-${#rows_ref[@]} select${sep}q stay"
  fi
  if [[ "${CODEX_AUTH_SELECTOR_CENTER:-0}" == "1" && "$term_lines" =~ ^[0-9]+$ ]]; then
    fallback_height=$((3 + ${#rows_ref[@]} + 1))
    if (( term_lines > fallback_height + 1 )); then
      fallback_top_padding=$(((term_lines - fallback_height) / 2))
    fi
  fi
  for ((fallback_pad_i = 0; fallback_pad_i < fallback_top_padding; fallback_pad_i++)); do
    printf '\n'
  done

  printf '%*s' 4 ''
  selector_palette_controls_line "$selector_controls" "$total_w"
  printf '\n'
  printf '%*s' 4 ''
  selector_palette_table_header "$total_w"
  for i in "${!rows_ref[@]}"; do
    IFS=$'\t' read -r kind action profile_choice display <<<"${rows_ref[$i]}"
    [[ "$profile_choice" == "-" ]] && profile_choice=""
    if [[ "$kind" == "action" ]]; then
      fallback_actions+=("$action")
      fallback_profiles+=("$profile_choice")
      action_count=$((action_count + 1))
      prefix="$(printf '%2d. ' "$action_count")"
      line_w=$((cols - ${#prefix}))
    else
      prefix=''
      line_w="$cols"
    fi
    (( line_w < 1 )) && line_w=1
    printf '%s' "$prefix"
    if [[ "$display" == *$'\033'* ]]; then
      plain="$(LC_ALL=C sed $'s/\033\\[[0-9;]*m//g' <<<"$display")"
      if (( ${#plain} <= line_w )); then
        printf '%s' "$display"
      else
        fit_text_rtrim "$plain" "$line_w"
      fi
    else
      fit_text_rtrim "$display" "$line_w"
    fi
    printf '\n'
  done
  if usage_unicode_enabled; then
    printf '› '
  else
    printf '> '
  fi
  IFS= read -r choice < /dev/tty || return 0
  if [[ -z "$choice" ]]; then
    selected=0
  elif [[ "$choice" == "q" || "$choice" == "Q" ]]; then
    MENU_ACTION="skip"
    MENU_PROFILE=""
    return 0
  elif [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#fallback_actions[@]} )); then
    selected=$((choice - 1))
  else
    MENU_ACTION="skip"
    MENU_PROFILE=""
    return 0
  fi

  MENU_ACTION="${fallback_actions[$selected]}"
  MENU_PROFILE="${fallback_profiles[$selected]}"
}

selector_menu_row_for_record() {
  local default_profile="$1"
  local selector_palette_mode="$2"
  local mode="$3"
  local role_w="$4"
  local profile_w="$5"
  local cell_w="$6"
  local status_w="$7"
  local bar_width="$8"
  local total_w="$9"
  local record="${10}"
  local valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age
  local display display_status palette_profile detail action_role row_action row_profile_field active_row=0
  local selector_profile_w="$profile_w" action_w=5
  (( selector_profile_w < 10 )) && selector_profile_w=10

  IFS=$'\t' read -r valid weekly_used short_used mark profile _plan weekly short status short_label weekly_reset short_reset _cache_age <<<"$record"
  [[ -n "$profile" ]] || return 1
  row_action="switch"
  row_profile_field="$profile"
  if (( selector_palette_mode )); then
    if (( total_w <= 30 )); then
      palette_profile="$(usage_display_profile_name "$profile" "" 6)"
    else
      palette_profile="$profile"
    fi
  fi

  if [[ "$valid" != "0" && "$status" == "login" ]]; then
    if (( selector_palette_mode )); then
      display="$(print_selector_palette_table_row "login $palette_profile" "-" "-" "login needed" "$status" "$valid" "$total_w")"
    else
      detail="needed"
      display="$(print_selector_row "login" "$(usage_display_profile_name "$profile" "" "$selector_profile_w")" "$detail" "$action_w" "$selector_profile_w" "$total_w")"
    fi
    row_action="login"
  elif [[ "$valid" == "0" ]]; then
    if (( selector_palette_mode )); then
      display_status="$(usage_display_status "$status" "normal")"
      if [[ "$mark" == "*" ]]; then
        action_role="stay"
      elif [[ "$mark" == "=" ]]; then
        action_role="same"
      else
        case "$display_status" in
          ready|ok)
            if [[ -n "$default_profile" && "$profile" == "$default_profile" ]]; then
              action_role="best"
            else
              action_role="use"
            fi
            ;;
          cap|old\ cap|both\ cap)
            action_role="cap"
            ;;
          *)
            action_role="warn"
            ;;
        esac
      fi
      display="$(print_selector_palette_table_row "$action_role $palette_profile" "$weekly" "$short" "$display_status" "$status" "$valid" "$total_w")"
    else
      display_status="$(usage_display_status "$status" "$mode")"
      if [[ "$mark" == "*" ]]; then
        action_role="$(selector_action_role "stay" "$role_w")"
      elif [[ "$mark" == "=" ]]; then
        action_role="$(selector_action_role "same" "$role_w")"
      elif [[ "$display_status" == "cap" || "$display_status" == "old cap" || "$display_status" == "both cap" ]]; then
        action_role="$(selector_action_role "cap" "$role_w")"
      elif [[ -n "$default_profile" && "$profile" == "$default_profile" ]]; then
        action_role="$(selector_action_role "best" "$role_w")"
      else
        action_role="$(selector_action_role "switch" "$role_w")"
      fi
      display="$(print_usage_render_data_line "$action_role" "$profile" "$weekly" "$weekly_reset" "$short" "$short_reset" \
        "$display_status" "$status" "$valid" "$weekly_used" "$short_used" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width" "$mode")"
    fi
  else
    if (( selector_palette_mode )); then
      display_status="$(usage_display_status "$status" "normal")"
      case "$mark" in
        "*") action_role="stay" ;;
        "=") action_role="same" ;;
        *) action_role="use" ;;
      esac
      display="$(print_selector_palette_table_row "$action_role $palette_profile" "-" "-" "$display_status" "$status" "$valid" "$total_w")"
    else
      display_status="$(usage_display_status "$status" "$mode")"
      if [[ "$mark" == "=" ]]; then
        action_role="same"
      else
        action_role="use"
      fi
      display="$(print_selector_row "$action_role" "$(usage_display_profile_name "$profile" "" "$selector_profile_w")" "$display_status" "$action_w" "$selector_profile_w" "$total_w")"
    fi
  fi
  if [[ "$row_action" == "switch" && ( "$mark" == "*" || "$mark" == "=" ) ]]; then
    active_row=1
    row_action="skip"
    row_profile_field="-"
  fi

  printf '%s\037action\037%s\037%s\037%s\n' "$active_row" "$row_action" "$row_profile_field" "$display"
}

arrow_action_menu() {
  local default_profile="${1:-}"
  shift
  local records=("$@")

  MENU_ACTION="skip"
  MENU_PROFILE=""

  selector_prompt_available || return 0

  local mode role_w profile_w cell_w status_w bar_width total_w
  local rows=()
  local summary_text
  local has_active_row=0
  local use_fzf=0
  local selector_palette_mode=0
  local selector_backend="${CODEX_AUTH_SELECTOR:-auto}"
  local render_cols
  local display palette_profile
  local record row active_row row_kind row_action row_profile_field row_display

  if [[ "${CODEX_AUTH_USE_FZF:-0}" == "1" ]]; then
    selector_backend="fzf"
  fi
  case "$selector_backend" in
    fzf|fzf-palette)
      use_fzf=1
      ;;
    auto)
      if command -v fzf >/dev/null 2>&1; then
        use_fzf=1
      fi
      ;;
    numbered|fallback|simple|"")
      use_fzf=0
      ;;
    *)
      use_fzf=0
      ;;
  esac
  if (( use_fzf )) && { [[ "${CODEX_AUTH_NO_FZF:-}" == "1" ]] || ! command -v fzf >/dev/null 2>&1; }; then
    use_fzf=0
  fi
  render_cols="$(terminal_width)"
  if (( render_cols < 32 )); then
    use_fzf=0
  fi

  if (( ! use_fzf )); then
    selector_palette_mode=1
  else
    case "${CODEX_AUTH_FZF_THEME:-}" in
      codex|1|'') selector_palette_mode=1 ;;
      *) selector_palette_mode=0 ;;
    esac
  fi
  USAGE_COLOR_ENABLED=0
  if (( use_fzf || selector_palette_mode )) && color_enabled; then
    USAGE_COLOR_ENABLED=1
  fi
  if (( use_fzf && selector_palette_mode )); then
    render_cols=$((render_cols - 3))
    (( render_cols < 20 )) && render_cols=20
  elif (( ! use_fzf )); then
    render_cols=$((render_cols - 4))
    (( render_cols < 16 )) && render_cols=16
  fi
  IFS=$'\t' read -r mode role_w profile_w cell_w status_w bar_width <<<"$(usage_render_widths "$render_cols")"
  total_w=$((role_w + 1 + (role_w > 1) + profile_w + 1 + cell_w + 1 + cell_w))
  (( status_w > 0 )) && total_w=$((total_w + 1 + (role_w > 1) + status_w))
  total_w="$(clamp_int_between "$total_w" 0 "$render_cols")"
  summary_text="$(usage_metadata_summary_line "$total_w" "$default_profile" "${records[@]}")"
  for record in "${records[@]}"; do
    if (( selector_palette_mode )) && [[ "${CODEX_AUTH_FAST_SELECTOR_ROWS:-1}" != "0" ]]; then
      selector_menu_row_for_record_into row "$default_profile" "$selector_palette_mode" "$mode" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width" "$total_w" "$record" || continue
    else
      row="$(selector_menu_row_for_record "$default_profile" "$selector_palette_mode" "$mode" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width" "$total_w" "$record")" || continue
    fi
    IFS=$'\037' read -r active_row row_kind row_action row_profile_field row_display <<<"$row"
    (( active_row )) && has_active_row=1
    rows+=("$row_kind"$'\t'"$row_action"$'\t'"$row_profile_field"$'\t'"$row_display")
  done
  if (( ! has_active_row )) && [[ -f "$AUTH_FILE" ]]; then
    if (( selector_palette_mode )) && [[ "${CODEX_AUTH_FAST_SELECTOR_ROWS:-1}" != "0" ]]; then
      if (( total_w <= 30 )); then
        selector_usage_display_profile_name_into palette_profile "current" "" 6
      else
        palette_profile="current"
      fi
      selector_palette_row_into display "stay $palette_profile" "-" "-" "same" "ok" "1" "$total_w"
    else
      if (( total_w <= 30 )); then
        palette_profile="$(usage_display_profile_name "current" "" 6)"
      else
        palette_profile="current"
      fi
      display="$(print_selector_palette_table_row "stay $palette_profile" "-" "-" "same" "ok" "1" "$total_w")"
    fi
    rows+=("action"$'\t'"skip"$'\t'"-"$'\t'"$display")
  fi

  if (( use_fzf )); then
    selector_fzf_menu rows "$summary_text" "$total_w" "$role_w" "$profile_w" "$cell_w" "$status_w" "$mode" "$selector_palette_mode"
    return 0
  fi

  selector_numbered_menu rows "$summary_text" "$total_w"
}
