# shellcheck shell=bash

usage() {
  local width path path_w
  width="$(terminal_width)"
  USAGE_COLOR_ENABLED=0
  color_enabled && USAGE_COLOR_ENABLED=1
  print_palette_title_line "Commands" "" "$width"
  if (( width >= 32 )); then
    path_w=$((width - 9))
    (( path_w < 1 )) && path_w=1
    path="$(compact_display_path "$PROFILE_DIR" "$path_w")"
    print_flat_context_line "profiles $path" "$width"
  elif (( width >= 22 )); then
    print_flat_context_line "profiles auth-profiles" "$width"
  fi
  print_help_section "daily" "$width"
  print_help_item "usage --refresh --select" "Refresh and select" "$width"
  print_help_item "usage --cached" "Cached usage" "$width"
  print_help_item "usage --refresh -v" "Wide usage" "$width"
  print_help_item "add <name>" "Browser login" "$width"
  print_help_section "lookup" "$width"
  print_help_item "current" "Active auth" "$width"
  print_help_item "list [-v]" "Saved profiles" "$width"
  print_help_item "paths" "Auth paths" "$width"
  print_help_section "switch" "$width"
  print_help_item "use <name>" "Select profile" "$width"
  print_help_item "add <name> --current" "Save current auth" "$width"
  print_help_item "add <name> --file <file>" "Import auth file" "$width"
  print_help_item "login <name>" "Login profile" "$width"
  print_help_section "maintenance" "$width"
  print_help_item "refresh" "Refresh usage" "$width"
  print_help_item "auto" "Select best profile" "$width"
  print_help_item "patch-codex" "Build patched Codex" "$width"
  print_help_item "recover [session]" "Resume with best" "$width"
  print_help_item "run -- <args>" "Rolling session" "$width"
  print_help_item "remove <name> --yes" "Delete profile" "$width"
  print_help_item "doctor" "Process audit" "$width"
  print_help_section "advanced" "$width"
  print_help_item "save <name> [file]" "Save auth file" "$width"
  print_help_item "import <name> <file>" "Import profile" "$width"
  print_help_item "export <name> <file>" "Export auth file" "$width"
  printf '\n'
}

print_help_section() {
  local label="$1"
  local width="$2"
  printf '\n'
  print_toned_fit_rtrim "$label" "$width" muted
  printf '\n'
}

print_help_item() {
  local cmd="$1"
  local desc="$2"
  local width="$3"
  local action action_tone action_w command_w desc_w line gap row pattern token first
  local tokens=()
  local action_rows=(
    "usage --refresh --select"$'\t'"select"
    "usage --cached"$'\t'"cache"
    "usage --refresh -v"$'\t'"wide"
    "add <name>"$'\t'"new"
    "current"$'\t'"view"
    "list*"$'\t'"view"
    "paths"$'\t'"view"
    "use <name>"$'\t'"use"
    "add <name> --current"$'\t'"save"
    "save*"$'\t'"copy"
    "add <name> --file <file>"$'\t'"import"
    "import*"$'\t'"load"
    "login <name>"$'\t'"auth"
    "refresh"$'\t'"sync"
    "auto"$'\t'"best"
    "patch-codex"$'\t'"patch"
    "recover*"$'\t'"resume"
    "run -- <args>"$'\t'"roll"
    "remove*"$'\t'"delete"
    "doctor"$'\t'"audit"
    "export*"$'\t'"write"
  )

  action="${desc%% *}"
  for row in "${action_rows[@]}"; do
    IFS=$'\t' read -r pattern action <<<"$row"
    if [[ "$cmd" == $pattern ]]; then
      break
    fi
    action="${desc%% *}"
  done
  case "$action" in
    select|best)
      action_tone="accent"
      ;;
    use|save|view|cache|export|new|copy|load|write)
      action_tone="good"
      ;;
    auth|login|import|wide|refresh|resume|roll|audit)
      action_tone="warn"
      ;;
    delete|remove)
      action_tone="bad"
      ;;
    *)
      action_tone="muted"
      ;;
  esac
  action_w=7
  (( width < 56 )) && action_w=6

  if (( width < 56 )); then
    command_w=$((width - action_w - 1))
    (( command_w < 1 )) && command_w=1
    read -r -a tokens <<<"$cmd"
    line=""
    first=1
    for token in "${tokens[@]}"; do
      if [[ -z "$line" ]]; then
        line="$token"
      elif (( ${#line} + 1 + ${#token} <= command_w )); then
        line+=" $token"
      else
        if (( first )); then
          print_toned_fit "$action" "$action_w" "$action_tone"
        else
          printf '%*s' "$action_w" ''
        fi
        printf ' '
        print_toned_fit_rtrim "$line" "$command_w" accent
        printf '\n'
        first=0
        line="$token"
      fi
    done
    if [[ -n "$line" ]]; then
      if (( first )); then
        print_toned_fit "$action" "$action_w" "$action_tone"
      else
        printf '%*s' "$action_w" ''
      fi
      printf ' '
      print_toned_fit_rtrim "$line" "$command_w" accent
      printf '\n'
    fi
    return 0
  fi

  command_w=27
  (( width >= 72 )) && command_w=31
  (( width >= 96 )) && command_w=34
  if (( command_w > width - action_w - 19 )); then
    command_w=$((width - action_w - 19))
  fi
  (( command_w < 14 )) && command_w=14
  desc_w=$((width - action_w - command_w - 3))
  (( desc_w < 1 )) && desc_w=1
  print_toned_fit "$action" "$action_w" "$action_tone"
  printf ' '
  print_toned_fit "$cmd" "$command_w" accent
  gap=2
  printf '%*s' "$gap" ''
  print_toned_fit_rtrim "$desc" "$desc_w" muted
  printf '\n'
}


