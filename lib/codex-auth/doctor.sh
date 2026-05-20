# shellcheck shell=bash

cmd_doctor() {
  local kill_sidecars=0 yes=0
  while (( $# > 0 )); do
    case "$1" in
      --kill-sidecars)
        kill_sidecars=1
        ;;
      --yes)
        yes=1
        ;;
      *)
        die "usage: codex-auth doctor [--kill-sidecars --yes]"
        ;;
    esac
    shift
  done
  if (( kill_sidecars && ! yes )); then
    die "refusing to kill sidecars without --yes"
  fi

  local root_count=0 sidecar_count=0 kill_count=0 pid
  local row ppid pgid sid tty stat etime args sidecars sidecar_total
  local -A legacy_pid=()
  local -A sidecar_by_parent=()
  local -A sidecar_args_by_pid=()
  local -a rows=() sidecar_pids=()

  while read -r pid ppid pgid sid tty stat etime args; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    args="${args:-}"
    row="$pid"$'\t'"$ppid"$'\t'"$pgid"$'\t'"$tty"$'\t'"$etime"$'\t'"$args"
    rows+=("$row")
    if [[ "$args" == *"codex-auth run"* || "$args" == *"/.bun/bin/codex --yolo"* || "$args" == *"/codex/codex --yolo"* ]]; then
      legacy_pid["$pid"]=1
      root_count=$((root_count + 1))
    fi
  done < <(
    if [[ -n "${CODEX_AUTH_DOCTOR_PS_FILE:-}" ]]; then
      cat "$CODEX_AUTH_DOCTOR_PS_FILE"
    else
      ps -eo pid=,ppid=,pgid=,sid=,tty=,stat=,etime=,args=
    fi
  )

  for row in "${rows[@]}"; do
    IFS=$'\t' read -r pid ppid pgid tty etime args <<<"$row"
    [[ -n "${legacy_pid["$ppid"]:-}" ]] || continue
    case "$args" in
      *"/outlook-mcp/"*|*"/webex-mcp/"*|*"/drfirst-mcp/"*|*"/gemini_ui_mcp.mjs"*|*"/run_event_mcp.py"*|*"claude-runner-mcp"*|*"playwright-repl-mcp"*)
        sidecar_count=$((sidecar_count + 1))
        sidecar_by_parent["$ppid"]="${sidecar_by_parent["$ppid"]:-} $pid"
        sidecar_args_by_pid["$pid"]="$args"
        ;;
    esac
  done

  printf 'legacy codex processes: %s\n' "$root_count"
  printf 'direct sidecars under legacy codex: %s\n' "$sidecar_count"

  if (( root_count > 0 )); then
    printf '\n'
    printf 'pid\tppid\tpgid\ttty\tetime\tsidecars\tcommand\n'
    for row in "${rows[@]}"; do
      IFS=$'\t' read -r pid ppid pgid tty etime args <<<"$row"
      [[ -n "${legacy_pid["$pid"]:-}" ]] || continue
      sidecars="${sidecar_by_parent["$pid"]:-}"
      if [[ -n "$sidecars" ]]; then
        read -r -a sidecar_pids <<<"$sidecars"; sidecar_total="${#sidecar_pids[@]}"
      else
        sidecar_total=0
      fi
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$pid" "$ppid" "$pgid" "$tty" "$etime" "$sidecar_total" "$args"
    done
  fi
  if (( kill_sidecars )); then
    for pid in "${!sidecar_args_by_pid[@]}"; do
      if kill "$pid" 2>/dev/null; then
        kill_count=$((kill_count + 1))
      fi
    done
    printf '\nterminated sidecars: %s\n' "$kill_count"
  elif (( sidecar_count > 0 )); then
    printf '\nrun: codex-auth doctor --kill-sidecars --yes\n'
  fi
}


