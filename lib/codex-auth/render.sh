# shellcheck shell=bash

now_epoch() {
  date +%s
}

color_enabled() {
  [[ -t 1 && -z "${NO_COLOR:-}" ]]
}

usage_color_active() {
  [[ "${USAGE_COLOR_ENABLED:-0}" == "1" ]]
}

terminal_width() {
  local cols
  cols="${COLUMNS:-}"
  if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
    cols="$(tput cols 2>/dev/null || true)"
  fi
  [[ "$cols" =~ ^[0-9]+$ ]] || cols=100
  (( cols < 20 )) && cols=20
  printf '%s\n' "$cols"
}

repeat_glyph() {
  local glyph="$1"
  local width="${2:-0}"
  local i

  for ((i = 0; i < width; i++)); do
    printf '%s' "$glyph"
  done
}

usage_unicode_enabled() {
  [[ "${CODEX_AUTH_ASCII:-0}" != "1" ]]
}

usage_glyph() {
  local unicode="$1"
  local ascii="${2:-}"

  if usage_unicode_enabled; then
    printf '%s' "$unicode"
  else
    printf '%s' "$ascii"
  fi
}

usage_separator() {
  usage_glyph ' · ' ' | '
}

fit_text() {
  local text="$1"
  local width="$2"
  local length=${#text}
  local trunc_glyph

  if (( width <= 0 )); then
    return 0
  fi
  trunc_glyph="$(usage_glyph '…' '~')"
  if (( length <= width )); then
    printf '%-*s' "$width" "$text"
  elif (( width == 1 )); then
    printf '%s' "$trunc_glyph"
  else
    printf '%s%s' "${text:0:width-1}" "$trunc_glyph"
  fi
}

fit_text_rtrim() {
  local rendered

  rendered="$(fit_text "$1" "$2")"
  printf '%s' "${rendered%"${rendered##*[! ]}"}"
}

fit_text_center() {
  local text="$1"
  local width="$2"
  local rendered left right

  if (( width <= 0 )); then
    return 0
  fi

  rendered="$(fit_text_rtrim "$text" "$width")"
  left=$(((width - ${#rendered} + 1) / 2))
  right=$((width - ${#rendered} - left))
  (( left > 0 )) && printf '%*s' "$left" ''
  printf '%s' "$rendered"
  (( right > 0 )) && printf '%*s' "$right" ''
  return 0
}

fit_profile_text() {
  local text="$1"
  local width="$2"
  local length=${#text}
  local trunc_glyph left right rendered pad

  if (( width <= 0 )); then
    return 0
  fi
  if (( length <= width || width < 3 )); then
    fit_text "$text" "$width"
    return 0
  fi

  trunc_glyph="$(usage_glyph '…' '~')"
  if (( width <= 5 )); then
    left=2
  elif (( width <= 8 )); then
    left=3
  else
    left=$(((width - 1) / 2))
  fi
  right=$((width - left - 1))
  (( right < 1 )) && right=1
  (( left + right + 1 > width )) && left=$((width - right - 1))

  rendered="${text:0:left}${trunc_glyph}${text:length-right:right}"
  printf '%s' "$rendered"
  pad=$((width - ${#rendered}))
  (( pad > 0 )) && printf '%*s' "$pad" ''
  return 0
}

fit_profile_text_rtrim() {
  local rendered

  rendered="$(fit_profile_text "$1" "$2")"
  printf '%s' "${rendered%"${rendered##*[! ]}"}"
}

usage_tone_code() {
  local mode="$1"
  local tone="${2:-}"
  local color=""

  usage_color_active || return 0
  case "$tone" in
    good) color="166;227;161" ;;
    warn|accent) color="250;178;131" ;;
    active) color="157;124;216" ;;
    bad) color="224;108;117" ;;
    track_edge) color="16;16;16" ;;
  esac
  case "$mode:$tone" in
    38:muted) color="128;128;128" ;;
    48:track) color="35;35;35" ;;
  esac
  [[ -n "$color" ]] && printf '\033[%s;2;%sm' "$mode" "$color"
  return 0
}

usage_tone_color() {
  usage_tone_code 38 "${1:-}"
}

usage_tone_reset() {
  usage_color_active && printf '\033[0m'
  return 0
}

usage_limit_tone() {
  local percent="${1:-}"
  local value

  percent="${percent%\%}"
  if [[ ! "$percent" =~ ^-?[0-9]+$ ]]; then
    printf 'muted'
    return 0
  fi

  value="$percent"
  if (( value < 25 )); then
    printf 'bad'
  elif (( value < 50 )); then
    printf 'warn'
  else
    printf 'good'
  fi
}

usage_role_tone() {
  case "${1:-}" in
    best|b|◆|+)
      printf 'accent'
      ;;
    active|stay|s|●|\*)
      printf 'active'
      ;;
    use|u)
      printf 'good'
      ;;
    cap|c)
      printf 'bad'
      ;;
    login|l)
      printf 'warn'
      ;;
    *)
      printf 'muted'
      ;;
  esac
}

usage_status_tone() {
  local status="${1:-}"
  local valid="${2:-0}"

  if [[ "$status" == "offline" || "$status" == "refresh timeout" || "$status" == "refresh unavailable" ]]; then
    printf 'warn'
  elif [[ "$valid" != "0" || "$status" == "login" ]]; then
    printf 'muted'
  elif [[ "$status" == stale* ]]; then
    printf 'warn'
  elif [[ "$status" == "ok" ]]; then
    printf 'good'
  else
    printf 'bad'
  fi
}

print_toned_fit() {
  local text="$1"
  local width="$2"
  local tone="${3:-}"

  usage_tone_color "$tone"
  fit_text "$text" "$width"
  usage_tone_reset
}

print_toned_fit_rtrim() {
  local text="$1"
  local width="$2"
  local tone="${3:-}"

  usage_tone_color "$tone"
  fit_text_rtrim "$text" "$width"
  usage_tone_reset
}

print_toned_fit_center() {
  local text="$1"
  local width="$2"
  local tone="${3:-}"

  usage_tone_color "$tone"
  fit_text_center "$text" "$width"
  usage_tone_reset
}

print_usage_section_rule() {
  local width="$1"
  local label="${2:-}"
  local tone="muted" text

  case "$label" in
    limited|cap) tone="bad" ;;
    login|offline) tone="warn" ;;
    ready) tone="good" ;;
  esac
  usage_tone_color "$tone"
  if [[ -n "$label" ]]; then
    case "$label" in
      limited) text="limits" ;;
      login) text="auth" ;;
      stale) text="stale cache" ;;
      unavailable) text="no data" ;;
      *) text="$label" ;;
    esac
    printf '%s' "$text"
  else
    repeat_glyph "$(usage_glyph '─' '-')" "$width"
  fi
  usage_tone_reset
  printf '\n'
}

usage_clamped_percent() {
  local percent="$1"
  local value

  percent="${percent%\%}"
  [[ "$percent" =~ ^-?[0-9]+$ ]] || return 1
  value="$percent"
  (( value < 0 )) && value=0
  (( value > 100 )) && value=100
  printf '%s' "$value"
}

usage_bar() {
  local percent="${1:-}"
  local width="${2:-8}"
  local value units max_units full partial empty_count
  local filled_glyph="█"
  local empty_glyph="░"
  local partial_glyphs=("" "▏" "▎" "▍" "▌" "▋" "▊" "▉")
  local ascii_single_glyphs=("." "+" "#")

  [[ "${CODEX_AUTH_ASCII:-0}" == "1" ]] && empty_glyph="."
  if ! value="$(usage_clamped_percent "$percent")"; then
    repeat_glyph "$empty_glyph" "$width"
    return 0
  fi

  if [[ "${CODEX_AUTH_ASCII:-0}" == "1" ]]; then
    if (( width == 1 )); then
      printf '%s' "${ascii_single_glyphs[$(( value <= 0 ? 0 : value >= 100 ? 2 : 1 ))]}"
      return 0
    fi
    full=$(((value * width + 50) / 100))
    full="$(clamp_int_between "$full" 0 "$width")"
    repeat_glyph "#" "$full"
    repeat_glyph "$empty_glyph" "$((width - full))"
    return 0
  fi

  units=$(((value * width * 8 + 50) / 100))
  max_units=$((width * 8))
  units="$(clamp_int_between "$units" 0 "$max_units")"
  full=$((units / 8))
  partial=$((units % 8))
  empty_count=$((width - full))
  (( partial > 0 && empty_count > 0 )) && empty_count=$((empty_count - 1))

  repeat_glyph "$filled_glyph" "$full"
  printf '%s' "${partial_glyphs[$partial]}"
  repeat_glyph "$empty_glyph" "$empty_count"
}

clamp_int_between() {
  local value="$1"
  local min="$2"
  local max="$3"

  if (( value < min )); then
    printf '%s' "$min"
  elif (( value > max )); then
    printf '%s' "$max"
  else
    printf '%s' "$value"
  fi
}

usage_profile_width_hint() {
  local cols="$1"
  local wanted="$2"
  local verbose="${3:-0}"
  local row row_verbose threshold min_w max_w
  local rows=(
    "1 112 18 28"
    "1 94 14 24"
    "1 0 12 24"
    "0 112 20 30"
    "0 94 18 28"
    "0 72 14 24"
    "0 0 12 24"
  )

  if [[ ! "$wanted" =~ ^[0-9]+$ ]]; then
    wanted=12
  fi

  for row in "${rows[@]}"; do
    read -r row_verbose threshold min_w max_w <<<"$row"
    if (( verbose == row_verbose && cols >= threshold )); then
      clamp_int_between "$wanted" "$min_w" "$max_w"
      return 0
    fi
  done
}

print_usage_limit_cell() {
  local percent="$1"
  local mode="$3"
  local bar_width="$4"
  local cell_w="$5"
  local used_percent="${6:-}"
  local reset_label="$2"
  local percent_label="$percent"
  local reset_prefix=""
  local label_w=4
  local tone
  local visible pad inner_w left_rail right_rail
  local reset_text="" reset_visible=0

  if [[ "$mode" == "micro" || "$mode" == "nano" ]]; then
    reset_label=""
  elif [[ ( "$mode" == "compact" || "$mode" == "tight" || "$mode" == "tiny" ) && "$reset_label" == *" "* ]]; then
    reset_label="${reset_label##* }"
  fi
  (( USAGE_VERBOSE )) || reset_label=""
  if [[ "$percent" == "-" ]]; then
    percent_label="$(usage_glyph '·' '.')"
    [[ "$mode" == "micro" || "$mode" == "nano" ]] || reset_label="$(usage_glyph '·' '.')"
  elif (( USAGE_VERBOSE )) && [[ ! "$mode" =~ ^(pico|nano|micro|tiny|tight)$ && "$used_percent" =~ ^[0-9]+$ ]]; then
    percent_label="${percent%\%}/${used_percent}%"
    label_w=6
  elif (( ! USAGE_VERBOSE )); then
    percent_label="${percent%\%}"
  fi
  if [[ -n "$reset_label" && "$percent" != "-" ]]; then
    reset_prefix="$(usage_glyph '↺')"
  fi
  if [[ -n "$reset_label" ]]; then
    reset_text="${reset_prefix}${reset_label}"
    reset_visible=$((1 + ${#reset_text}))
  fi
  tone="$(usage_limit_tone "$percent")"
  if [[ "$mode" == "pico" || "$mode" == "nano" ]]; then
    [[ "$percent" == "-" ]] && percent_label="$(usage_glyph '·' '.')"
    usage_tone_color "$tone"
    fit_text_center "$percent_label" "$cell_w"
    usage_tone_reset
    return 0
  fi

  if [[ "$percent" == "-" ]]; then
    usage_tone_color "$tone"
    printf "%${label_w}s" "$percent_label"
    usage_tone_reset
    visible="$label_w"
    if [[ -n "$reset_text" ]]; then
      usage_tone_color muted
      printf ' %s' "$reset_text"
      usage_tone_reset
      visible=$((visible + reset_visible))
    fi
    pad=$((cell_w - visible))
    (( pad > 0 )) && printf '%*s' "$pad" ''
    return 0
  fi

  usage_tone_color "$tone"
  printf "%${label_w}s " "$percent_label"
  usage_tone_reset
  if (( bar_width < 3 )); then
    usage_tone_color "$tone"
    usage_bar "$percent" "$bar_width"
    usage_tone_reset
  else
    inner_w=$((bar_width - 2))
    if usage_unicode_enabled; then
      left_rail="▕"
      right_rail="▐"
    else
      left_rail="["
      right_rail="]"
    fi
    usage_tone_color muted
    printf '%s' "$left_rail"
    usage_tone_reset
    usage_tone_color "$tone"
    usage_bar "$percent" "$inner_w"
    usage_tone_reset
    usage_tone_color muted
    printf '%s' "$right_rail"
    usage_tone_reset
  fi
  visible=$((label_w + 1 + bar_width))
  if [[ -n "$reset_text" ]]; then
    usage_tone_color muted
    printf ' %s' "$reset_text"
    usage_tone_reset
    visible=$((visible + reset_visible))
  fi
  pad=$((cell_w - visible))
  (( pad > 0 )) && printf '%*s' "$pad" ''
  return 0
}

usage_render_widths() {
  local cols="$1"
  local mode role_w
  local show_status="${CODEX_AUTH_USAGE_STATUS:-0}"
  local profile_w
  local wanted_profile_w="${USAGE_PROFILE_WIDTH_HINT:-12}"
  local profile_min status_min reset_w label_w min_bar_w max_bar_w
  local cell_overhead reset_prefix_w=0
  local cell_w status_w status_max bar_width available max_profile_w
  local role_profile_gap=1 status_gap=1 gap_w=4
  local row row_min row_max row_verbose threshold max_w
  local width_rows=(
    "0 25 -1 pico 1 4 3 0 4 0 0"
    "26 39 -1 nano 1 5 3 0 4 0 0"
    "40 49 -1 micro 1 8 5 0 4 3 8"
    "50 59 -1 tiny 1 8 5 5 4 3 8"
    "60 71 -1 tight 6 8 7 5 4 4 8"
    "72 93 1 compact 6 8 12 5 4 5 12"
    "72 93 0 normal 6 8 12 11 4 4 16"
    "94 111 1 normal 7 8 12 11 4 4 18"
    "94 111 0 normal 7 8 12 11 4 4 20"
    "112 9999 1 wide 7 8 12 11 4 4 18"
    "112 9999 0 wide 7 8 12 11 4 4 22"
  )

  wanted_profile_w="$(usage_profile_width_hint "$cols" "$wanted_profile_w" "$USAGE_VERBOSE")"
  for row in "${width_rows[@]}"; do
    read -r row_min row_max row_verbose mode role_w profile_min status_min reset_w label_w min_bar_w max_bar_w <<<"$row"
    (( cols >= row_min && cols <= row_max )) || continue
    (( row_verbose < 0 || row_verbose == USAGE_VERBOSE )) || continue
    break
  done
  if (( USAGE_VERBOSE && cols >= 68 )) && [[ "$mode" == "tight" ]]; then
    status_min=12
  fi
  if (( ! USAGE_VERBOSE )); then
    if (( cols >= 61 )); then
      role_w=5
      status_min=12
    else
      role_w=1
    fi
  elif [[ "$mode" != "pico" && "$mode" != "nano" && "$mode" != "micro" && "$mode" != "tiny" && "$mode" != "tight" ]]; then
    label_w=6
    max_bar_w=12
    if (( cols >= 112 )); then
      max_bar_w=20
    elif (( cols >= 94 )); then
      max_bar_w=14
    fi
  fi
  role_profile_gap=$((1 + (role_w > 1)))
  status_gap="$role_profile_gap"
  if [[ "$show_status" != "1" ]]; then
    status_min=0
    status_gap=0
  fi
  gap_w=$((role_profile_gap + 2 + status_gap))
  if (( ! USAGE_VERBOSE )); then
    reset_w=0
  fi
  if (( reset_w > 0 )) && usage_unicode_enabled; then
    reset_prefix_w=1
  else
    reset_prefix_w=0
  fi
  if [[ "$mode" == "pico" ]]; then
    cell_overhead="$label_w"
  elif (( reset_w > 0 )); then
    cell_overhead=$((label_w + 2 + reset_w + reset_prefix_w))
  else
    cell_overhead=$((label_w + 1))
  fi

  max_profile_w=$(( cols - role_w - status_min - (2 * (cell_overhead + min_bar_w)) - gap_w ))
  if (( max_profile_w < 12 && reset_w > 5 )); then
    mode="tight"
    reset_w=5
    label_w=4
    if usage_unicode_enabled; then
      reset_prefix_w=1
    else
      reset_prefix_w=0
    fi
    cell_overhead=$((label_w + 2 + reset_w + reset_prefix_w))
    max_profile_w=$(( cols - role_w - status_min - (2 * (cell_overhead + min_bar_w)) - gap_w ))
  fi

  profile_w="$(clamp_int_between "$wanted_profile_w" "$profile_min" "$max_profile_w")"
  available=$(( cols - role_w - profile_w - status_min - gap_w ))
  cell_w=$(( available / 2 ))
  bar_width=$(( cell_w - cell_overhead ))
  bar_width="$(clamp_int_between "$bar_width" "$min_bar_w" "$max_bar_w")"
  cell_w=$(( bar_width + cell_overhead ))
  status_w=$(( cols - role_w - profile_w - cell_w - cell_w - gap_w ))
  while (( status_w < status_min && bar_width > min_bar_w )); do
    bar_width=$((bar_width - 1))
    cell_w=$(( bar_width + cell_overhead ))
    status_w=$(( cols - role_w - profile_w - cell_w - cell_w - gap_w ))
  done
  while (( status_w < status_min && profile_w > profile_min )); do
    profile_w=$((profile_w - 1))
    status_w=$(( cols - role_w - profile_w - cell_w - cell_w - gap_w ))
  done
  (( status_w < status_min )) && status_w="$status_min"
  if [[ "$show_status" != "1" ]]; then
    status_w=0
  else
    status_max=0
    for row in "1 94 16" "1 72 14" "0 60 13" "0 50 9"; do
      read -r row_verbose threshold max_w <<<"$row"
      if (( USAGE_VERBOSE == row_verbose && cols >= threshold )); then
        status_max="$max_w"
        break
      fi
    done
    if (( status_max > 0 && status_w > status_max )); then
      status_w="$status_max"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$mode" "$role_w" "$profile_w" "$cell_w" "$status_w" "$bar_width"
}

usage_display_status() {
  local status="$1"
  local mode="${2:-normal}"
  local stale_status=0
  local stale_age=""
  local exact_cap=0

  if [[ "$status" == stale\ * ]]; then
    stale_status=1
    status="${status#stale }"
    if [[ "$status" =~ ^(now|[0-9]+[mhd])[[:space:]]+(.+)$ ]]; then
      stale_age="${BASH_REMATCH[1]}"
      status="${BASH_REMATCH[2]}"
    fi
  fi
  [[ "$status" == "week+5h cap" || "$status" == "week cap" || "$status" == "5h cap" ]] && exact_cap=1

  if (( stale_status )); then
    if [[ "$mode" == "pico" || "$mode" == "nano" ]]; then
      if [[ "$status" == *cap ]]; then
        printf 'cap'
      else
        printf 'old'
      fi
    elif [[ "$mode" == "micro" || "$mode" == "tiny" ]]; then
      if [[ "$status" == "ok" ]]; then
        if [[ -n "$stale_age" && "$stale_age" != "now" ]]; then
          printf 'old'
        else
          printf 'stale'
        fi
      elif (( exact_cap )); then
        printf 'cap'
      else
        printf 'stale'
      fi
    elif [[ "$status" == "ok" ]]; then
      if [[ -n "$stale_age" && "$stale_age" != "now" ]]; then
        printf 'old %s' "$stale_age"
      else
        printf 'stale'
      fi
    elif (( exact_cap )); then
      printf 'old cap'
    else
      printf 'stale'
    fi
    return 0
  fi

  if (( exact_cap )); then
    printf 'cap'
    return 0
  fi

  if [[ "$mode" == "pico" || "$mode" == "nano" ]]; then
    case "$status" in
      ok)
        printf 'ok'
        ;;
      stale\ *\ cap)
        printf 'old'
        ;;
      login)
        printf 'auth'
        ;;
      no\ usage|no\ data)
        printf 'n/a'
        ;;
      *)
        printf '%s' "$status"
        ;;
    esac
    return 0
  fi

  if [[ "$mode" == "micro" || "$mode" == "tiny" ]]; then
    case "$status" in
      ok)
        printf 'ready'
        ;;
      stale\ *\ cap)
        printf 'stale'
        ;;
      login)
        printf 'auth'
        ;;
      *)
        printf '%s' "$status"
        ;;
    esac
    return 0
  fi

  case "$status" in
    ok)
      printf 'ready'
      ;;
    offline)
      printf 'offline'
      ;;
    login)
      printf 'login'
      ;;
    *)
      printf '%s' "$status"
      ;;
  esac
}

usage_display_profile_name() {
  local profile="$1"
  local role="${2:-}"
  local width="${3:-0}"
  local suffix compact

  if [[ "$profile" == "current" && "$role" != "active" && "$role" != "●" && "$role" != "*" ]]; then
    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && "$width" -lt 7 ]]; then
      printf 'cur'
    else
      printf 'current'
    fi
  elif [[ "$profile" == "Layth" && "$width" =~ ^[0-9]+$ && "$width" -gt 0 && "$width" -lt 5 ]]; then
    printf 'Lay'
  elif [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#profile} -gt width ]]; then
    if [[ "$profile" =~ ^Layth([0-9]+)$ ]]; then
      suffix="${BASH_REMATCH[1]}"
      compact="L$suffix"
      if (( ${#compact} <= width )); then
        printf '%s' "$compact"
      else
        printf '%s' "${suffix:0:width}"
      fi
    elif [[ "$profile" == Layth.* ]]; then
      suffix="${profile#Layth.}"
      if (( ${#suffix} <= width )); then
        printf '%s' "$suffix"
      elif (( width <= 5 )); then
        printf '%s' "${suffix:0:width}"
      else
        printf '%s' "$profile"
      fi
    elif (( width <= 5 )); then
      fit_profile_text "$profile" "$width"
    else
      printf '%s' "$profile"
    fi
  else
    printf '%s' "$profile"
  fi
}

usage_header_limit_label() {
  local mode="$1"
  local label="$2"
  local nano_label="$3"
  local reset_glyph

  if (( ! USAGE_VERBOSE )); then
    if [[ "$mode" == "pico" || "$mode" == "nano" ]]; then
      printf '%s%%' "$nano_label"
    else
      printf '%s%%' "$label"
    fi
    return 0
  fi

  reset_glyph="$(usage_glyph '↺')"
  case "$mode" in
    pico|nano)
      printf '%s%%' "$nano_label"
      ;;
    micro)
      printf '%s%%' "$label"
      ;;
    tiny)
      if [[ -n "$reset_glyph" ]]; then
        printf '%s%%%s' "$label" "$reset_glyph"
      else
        printf '%s%% reset' "$label"
      fi
      ;;
    tight)
      if [[ -n "$reset_glyph" ]]; then
        printf '%s left%s' "$label" "$reset_glyph"
      else
        printf '%s left reset' "$label"
      fi
      ;;
    compact)
      if [[ -n "$reset_glyph" ]]; then
        printf '%s left/used%s' "$label" "$reset_glyph"
      else
        printf '%s used/reset' "$label"
      fi
      ;;
    *)
      if [[ -n "$reset_glyph" ]]; then
        printf '%s left/used %s reset' "$label" "$reset_glyph"
      else
        printf '%s left/used reset' "$label"
      fi
      ;;
  esac
}

usage_metric_header_cell() {
  local text="$1"
  local width="$2"
  local force_compact="${3:-0}"
  local display="$text" compact="$text"

  if (( USAGE_VERBOSE > force_compact )); then
    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#text} -gt width ]]; then
      case "$text" in
        "weekly left/used ↺ reset")
          compact="week left/used ↺ reset"
          ;;
        "weekly left/used reset")
          compact="week left/used reset"
          ;;
        "weekly left/used "*)
          compact="${text/weekly/week}"
          ;;
      esac
    fi
    if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#compact} -le width ]]; then
      printf '%s' "$compact"
    else
      printf '%s' "$text"
    fi
    return 0
  fi

  [[ "$display" == "week%" ]] && display="wk%"
  if (( ${#display} > width )); then
    if (( width <= 1 )); then
      display="${display:0:width}"
    elif [[ "$display" == *% ]]; then
      display="${display:0:width-1}%"
    else
      display="${display:0:width}"
    fi
  fi

  fit_text_center "$display" "$width"
}

print_usage_render_header() {
  local role="$1"
  local role_w="$2"
  local profile_w="$3"
  local cell_w="$4"
  local status_w="$5"
  local mode="${6:-normal}"
  local reset=""
  local role_profile_gap profile weekly_cell short_cell status
  local short_label="${USAGE_SHORT_LABEL:-5h}"
  local short_nano_label

  if [[ "$mode" == "pico" || "$mode" == "nano" ]]; then
    profile="name"
    status="st"
    [[ "$short_label" == "short" ]] && short_label="5h"
  else
    profile="profile"
    if [[ "$mode" == "micro" || "$mode" == "tiny" ]]; then
      status="state"
    else
      status="status"
    fi
  fi
  short_nano_label="${short_label:0:2}"
  weekly_cell="$(usage_header_limit_label "$mode" "week" "wk")"
  short_cell="$(usage_header_limit_label "$mode" "$short_label" "$short_nano_label")"
  weekly_cell="$(usage_metric_header_cell "$weekly_cell" "$cell_w")"
  short_cell="$(usage_metric_header_cell "$short_cell" "$cell_w")"
  if (( status_w > 0 )); then
    status="$(fit_text_center "$status" "$status_w")"
  else
    status=""
  fi
  usage_color_active && reset=$'\033[0m'
  usage_tone_color muted
  role_profile_gap=$((1 + (role_w > 1)))
  fit_text "$role" "$role_w"
  printf '%*s' "$role_profile_gap" ''
  fit_text "$profile" "$profile_w"
  printf ' '
  fit_text "$weekly_cell" "$cell_w"
  printf ' '
  fit_text "$short_cell" "$cell_w"
  if (( status_w > 0 )); then
    printf '%*s' "$role_profile_gap" ''
    fit_text "$status" "$status_w"
  fi
  printf '%s\n' "$reset"
}

print_usage_render_data_line() {
  local role="$1"
  local profile="$2"
  local weekly="$3"
  local weekly_reset="$4"
  local short="$5"
  local short_reset="$6"
  local display_status="$7"
  local raw_status="$8"
  local valid="$9"
  local weekly_used="${10}"
  local short_used="${11}"
  local role_w="${12}"
  local profile_w="${13}"
  local cell_w="${14}"
  local status_w="${15}"
  local bar_width="${16}"
  local mode="${17}"
  local unavailable_text role_profile_gap status_gap status cutoff text placeholder_label_w placeholder_pad placeholder_center placeholder_i

  print_toned_fit "$role" "$role_w" "$(usage_role_tone "$role")"
  role_profile_gap=$((1 + (role_w > 1)))
  status_gap="$role_profile_gap"
  printf '%*s' "$role_profile_gap" ''
  fit_profile_text "$(usage_display_profile_name "$profile" "$role" "$profile_w")" "$profile_w"
  printf ' '
  if [[ "$valid" != "0" ]]; then
    unavailable_text="$display_status"
    while IFS=$'\t' read -r status cutoff text; do
      [[ "$raw_status" == "$status" ]] || continue
      (( status_w < cutoff )) || continue
      unavailable_text="$text"
      break
    done <<'EOF'
login	4	log
login	6	auth
login	12	login
login	100000	login needed
no data	3	na
no data	7	n/a
no data	100000	no data
no usage	3	na
no usage	8	n/a
no usage	100000	no usage
offline	3	of
offline	7	off
offline	100000	offline
EOF
    placeholder_label_w=4
    if [[ "$mode" == "pico" ]]; then
      placeholder_label_w="$cell_w"
    elif (( USAGE_VERBOSE )) && [[ ! "$mode" =~ ^(pico|nano|micro|tiny|tight)$ ]]; then
      placeholder_label_w=6
    fi
    (( placeholder_label_w > cell_w )) && placeholder_label_w="$cell_w"
    placeholder_center=0
    [[ "$mode" == "pico" || "$mode" == "nano" ]] && placeholder_center=1
    for placeholder_i in 0 1; do
      (( placeholder_i > 0 )) && printf ' '
      (( cell_w <= 0 )) && continue
      usage_tone_color muted
      if (( placeholder_center )); then
        fit_text_center "-" "$cell_w"
        usage_tone_reset
        continue
      fi
      printf "%${placeholder_label_w}s" "-"
      usage_tone_reset
      placeholder_pad=$((cell_w - placeholder_label_w))
      (( placeholder_pad > 0 )) && printf '%*s' "$placeholder_pad" ''
    done
    if (( status_w > 0 )); then
      printf '%*s' "$status_gap" ''
      print_toned_fit_center "$unavailable_text" "$status_w" "$(usage_status_tone "$raw_status" "$valid")"
    fi
    printf '\n'
    return 0
  fi

  print_usage_limit_cell "$weekly" "$weekly_reset" "$mode" "$bar_width" "$cell_w" "$weekly_used"
  printf ' '
  print_usage_limit_cell "$short" "$short_reset" "$mode" "$bar_width" "$cell_w" "$short_used"
  if (( status_w > 0 )); then
    printf '%*s' "$status_gap" ''
    print_toned_fit_center "$display_status" "$status_w" "$(usage_status_tone "$raw_status" "$valid")"
  fi
  printf '\n'
}

print_usage_summary_line() {
  local width="$1"
  local best_profile="${2:-}"
  shift 2
  local record valid weekly_used short_used mark profile plan weekly short status short_label weekly_reset short_reset cache_age
  local active_profile="" active_short="" active_weekly="" active_label="5h"
  local has_best=0 has_active=0 active_has_usage=0 old_summary=0
  local caps=0 login=0 unavailable=0 offline=0 stale=0 ready=0
  local cache_age_max=-1 cache_age_label=""
  local show_cache=0
  local line show_week=0 show_login=0 show_unavailable=0 show_offline=0 show_ready=0 show_caps=0 show_stale=0
  local part
  local cap_label="capped"
  local fallback_used=0
  local sep
  sep="$(usage_separator)"

  for record in "$@"; do
    IFS=$'\t' read -r valid weekly_used short_used mark profile plan weekly short status short_label weekly_reset short_reset cache_age <<<"$record"
    [[ -n "$profile" ]] || continue
    if [[ "$cache_age" =~ ^[0-9]+$ ]] && (( cache_age > cache_age_max )); then
      cache_age_max="$cache_age"
    fi
    if [[ "$mark" == "*" ]]; then
      active_profile="$profile"
      active_short="$short"
      active_weekly="$weekly"
      if [[ "$valid" == "0" && -n "$short" && "$short" != "-" ]]; then
        [[ -n "$short_label" ]] && active_label="$short_label"
        active_has_usage=1
      elif [[ "$valid" == "0" && -n "$weekly" && "$weekly" != "-" ]]; then
        active_short="$weekly"
        active_label="wk"
        active_has_usage=1
      fi
    fi
    [[ -z "$best_profile" && "$status" == "ok" ]] && best_profile="$profile"
    [[ "$status" == stale* ]] && stale=$((stale + 1))
    if [[ "$status" == "offline" ]]; then
      offline=$((offline + 1))
    elif [[ "$status" == "login" ]]; then
      login=$((login + 1))
    elif [[ "$valid" != "0" || "$status" == "no data" || "$status" == "no usage" ]]; then
      unavailable=$((unavailable + 1))
    elif [[ "$status" == *cap* ]]; then
      caps=$((caps + 1))
    elif [[ "$status" == "ok" ]]; then
      ready=$((ready + 1))
    fi
  done

  [[ -n "$best_profile" ]] && has_best=1
  if [[ -n "$active_profile" ]]; then
    has_active=1
  else
    active_profile="none"
  fi
  [[ -n "$active_short" && "$active_short" != "-" ]] || active_short="n/a"
  [[ -n "$active_weekly" && "$active_weekly" != "-" ]] || active_weekly="n/a"
  if (( cache_age_max >= 0 )); then
    cache_age_label="$(format_cache_age "$cache_age_max")"
  fi
  (( stale > 0 && ready == 0 && has_active )) && old_summary=1

  (( width >= 70 && login > 0 )) && show_login=1
  (( width >= 70 && unavailable > 0 )) && show_unavailable=1
  (( width >= 70 && offline > 0 )) && show_offline=1
  if (( ready > 0 && (width >= 70 || caps == 0) )); then
    show_ready=1
  fi
  (( caps > 0 )) && show_caps=1

  if (( width < 40 )); then
    local compact_active_profile
    local compact_lines=()

    compact_active_profile="$(usage_display_profile_name "$active_profile" "" 6)"
    if (( old_summary )); then
      compact_lines+=(
        "old $compact_active_profile ${active_label} $active_short"
        "old $active_profile ${active_label} $active_short"
        "old $compact_active_profile"
        "old $active_profile"
      )
    fi
    if (( has_active )); then
      if (( active_has_usage )); then
        if (( caps > 0 )); then
          compact_lines+=(
            "active $compact_active_profile ${active_label} $active_short${sep}cap $caps"
            "act $compact_active_profile ${active_label} $active_short${sep}cap $caps"
          )
        fi
        compact_lines+=(
          "active $compact_active_profile ${active_label} $active_short"
          "act $compact_active_profile ${active_label} $active_short"
          "active $active_profile ${active_label} $active_short"
          "active $compact_active_profile"
          "active $active_profile"
          "${active_label} $active_short"
        )
      else
        compact_lines+=(
          "no fresh ready${sep}active $compact_active_profile"
          "no fresh ready${sep}active $active_profile"
          "active $compact_active_profile"
          "active $active_profile"
          "no fresh ready"
        )
      fi
    elif (( has_best )); then
      compact_lines+=(
        "ready $ready${sep}no active"
        "ready $ready"
        "no active"
      )
    else
      compact_lines+=(
        "no fresh ready${sep}no active"
        "no active"
      )
    fi
    for line in "${compact_lines[@]}"; do
      if (( ${#line} <= width )); then
        printf '%s\n' "$line"
        return 0
      fi
    done
    fit_text_rtrim "${compact_lines[-1]}" "$width"
    printf '\n'
    return 0
  fi

  if (( old_summary )); then
    line="old active $active_profile ${active_label} $active_short"
  elif (( has_active )); then
    line="active $active_profile"
    (( active_has_usage )) && line+=" ${active_label} $active_short"
  elif (( has_best )); then
    if (( ready > 0 )); then
      line="ready $ready${sep}no active"
    else
      line="no active"
    fi
  else
    line="no fresh ready${sep}no active"
  fi
  if (( ! has_active && has_best )); then
    show_ready=0
  fi
  part=" wk $active_weekly"
  if (( show_week && ${#line} + ${#part} <= width )); then line+="$part"; else show_week=0; fi
  part="${sep}ready $ready"
  if (( show_ready && ${#line} + ${#part} <= width )); then line+="$part"; else show_ready=0; fi
  part="${sep}$cap_label $caps"
  if (( show_caps && ${#line} + ${#part} <= width )); then line+="$part"; else show_caps=0; fi
  part="${sep}login $login"
  if (( show_login && ${#line} + ${#part} <= width )); then line+="$part"; else show_login=0; fi
  part="${sep}no data $unavailable"
  if (( show_unavailable && ${#line} + ${#part} <= width )); then line+="$part"; else show_unavailable=0; fi
  part="${sep}offline $offline"
  if (( show_offline && ${#line} + ${#part} <= width )); then line+="$part"; else show_offline=0; fi
  if (( stale > 0 )); then
    part="${sep}stale $stale"
    if (( ${#line} + ${#part} <= width )); then line+="$part"; show_stale=1; fi
  fi
  if [[ -n "$cache_age_label" ]]; then
    part="${sep}cache $cache_age_label"
    if (( ${#line} + ${#part} <= width )); then line+="$part"; show_cache=1; fi
  fi

  if (( ${#line} > width )); then
    show_ready=0
    show_caps=0
    cap_label="capped"
    if (( old_summary )); then
      line="old active $active_profile ${active_label} $active_short"
    elif (( has_active )); then
      if (( active_has_usage )); then
        line="active $active_profile ${active_label} $active_short"
      else
        line="active $active_profile"
      fi
    elif (( has_best )); then
      if (( ready > 0 )); then
        line="ready $ready${sep}no active"
      else
        line="no active"
      fi
    else
      line="no active"
    fi
    if (( caps > 0 && ${#line} + 8 <= width )); then
      cap_label="cap"
      line+="${sep}$cap_label $caps"
      show_caps=1
    elif (( ready > 0 && ${#line} + 10 <= width )); then
      line+="${sep}ready $ready"
      show_ready=1
    fi
    fallback_used=1
  fi
  if (( fallback_used )); then
    show_week=0
    show_login=0
    show_unavailable=0
    show_offline=0
    show_stale=0
    show_cache=0
  fi

  if (( ${#line} > width )); then
    fit_text_rtrim "$line" "$width"
    printf '\n'
  elif usage_color_active; then
    if (( old_summary )); then
      usage_tone_color muted; printf 'old active '; usage_tone_reset
      usage_tone_color active; printf '%s' "$active_profile"; usage_tone_reset
    elif (( has_active )); then
      usage_tone_color muted; printf 'active '; usage_tone_reset
      usage_tone_color active; printf '%s' "$active_profile"; usage_tone_reset
    elif (( has_best )); then
      if (( ready > 0 )); then
        usage_tone_color good; printf 'ready '; usage_tone_reset
        usage_tone_color good; printf '%s' "$ready"; usage_tone_reset
        usage_tone_color muted; printf '%sno active' "$sep"; usage_tone_reset
      else
        usage_tone_color muted; printf 'no active'; usage_tone_reset
      fi
    else
      usage_tone_color muted; printf 'no fresh ready'; usage_tone_reset
      usage_tone_color muted; printf '%sno active' "$sep"; usage_tone_reset
    fi
    if (( has_active * active_has_usage )); then
      usage_tone_color muted; printf ' %s ' "$active_label"; usage_tone_reset
      usage_tone_color "$(usage_limit_tone "$active_short")"; printf '%s' "$active_short"; usage_tone_reset
    fi
    if (( show_week )); then
      usage_tone_color muted; printf ' wk '; usage_tone_reset
      usage_tone_color "$(usage_limit_tone "$active_weekly")"; printf '%s' "$active_weekly"; usage_tone_reset
    fi
    if (( show_ready )); then
      usage_tone_color muted; printf '%sready ' "$sep"; usage_tone_reset
      usage_tone_color good; printf '%s' "$ready"; usage_tone_reset
    fi
    if (( show_caps )); then
      usage_tone_color muted; printf '%s%s ' "$sep" "$cap_label"; usage_tone_reset
      usage_tone_color bad; printf '%s' "$caps"; usage_tone_reset
    fi
    if (( show_login )); then
      usage_tone_color muted; printf '%slogin ' "$sep"; usage_tone_reset
      usage_tone_color muted; printf '%s' "$login"; usage_tone_reset
    fi
    if (( show_unavailable )); then
      usage_tone_color muted; printf '%sno data ' "$sep"; usage_tone_reset
      usage_tone_color muted; printf '%s' "$unavailable"; usage_tone_reset
    fi
    if (( show_offline )); then
      usage_tone_color muted; printf '%soffline ' "$sep"; usage_tone_reset
      usage_tone_color warn; printf '%s' "$offline"; usage_tone_reset
    fi
    if (( show_stale )); then
      usage_tone_color muted; printf '%sstale ' "$sep"; usage_tone_reset
      usage_tone_color warn; printf '%s' "$stale"; usage_tone_reset
    fi
    if (( show_cache )); then
      usage_tone_color muted; printf '%s' "${sep}cache $cache_age_label"; usage_tone_reset
    fi
    printf '\n'
  else
    printf '%s\n' "$line"
  fi
}

