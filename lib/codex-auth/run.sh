# shellcheck shell=bash

codex_run_limit_detected() {
  local log_file="$1"
  local scan_bytes="${CODEX_AUTH_ROLL_LOG_SCAN_BYTES:-1048576}"

  [[ -s "$log_file" ]] || return 1
  [[ "$scan_bytes" =~ ^[1-9][0-9]*$ ]] || scan_bytes=1048576
  if command -v tail >/dev/null 2>&1; then
    LC_ALL=C tail -c "$scan_bytes" "$log_file" 2>/dev/null | grep -aEiq \
      'usage limit|rate limit|rate.?limit reached|limit reached|reached[^[:alnum:]]+limit|exceeded[^[:alnum:]]+limit|too many requests|429|rateLimitReached|5h cap|weekly cap|week cap|quota'
  else
    LC_ALL=C grep -aEiq \
      'usage limit|rate limit|rate.?limit reached|limit reached|reached[^[:alnum:]]+limit|exceeded[^[:alnum:]]+limit|too many requests|429|rateLimitReached|5h cap|weekly cap|week cap|quota' \
      "$log_file"
  fi
}

codex_run_kill_script_for_log() {
  local parent_pid="$1"
  local run_file="$2"
  local log_file="$3"
  local signal="${4:-TERM}"
  local child grandchild killed_child cmd arg

  [[ "$parent_pid" =~ ^[0-9]+$ ]] || return 0
  if ! command -v pgrep >/dev/null 2>&1; then
    return 0
  fi

  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ && "$child" != "${BASHPID:-}" && -r "/proc/$child/cmdline" ]] || continue
    cmd=""
    while IFS= read -r -d '' arg; do
      cmd+="$arg "
    done <"/proc/$child/cmdline" 2>/dev/null || true
    [[ "$cmd" == *"script "* && "$cmd" == *"$run_file"* && "$cmd" == *"$log_file"* ]] || continue
    killed_child=0
    while IFS= read -r grandchild; do
      [[ "$grandchild" =~ ^[0-9]+$ ]] || continue
      usage_kill_process_tree "$grandchild" "$signal"
      killed_child=1
    done < <(pgrep -P "$child" 2>/dev/null)
    if (( killed_child == 0 )); then
      usage_kill_process_tree "$child" "$signal"
    fi
  done < <(pgrep -P "$parent_pid" 2>/dev/null)
}

codex_run_limit_monitor_loop() {
  local log_file="$1"
  local target_pid="$2"
  local parent_pid="${3:-}"
  local run_file="${4:-}"
  local interval="${CODEX_AUTH_ROLL_MONITOR_INTERVAL:-2}"
  local watched_pid="$target_pid"

  [[ "$interval" =~ ^[1-9][0-9]*$ ]] || interval=2
  [[ "$watched_pid" =~ ^[0-9]+$ ]] || watched_pid="$parent_pid"
  [[ "$watched_pid" =~ ^[0-9]+$ ]] || return 0

  while true; do
    kill -0 "$watched_pid" 2>/dev/null || return 0

    if codex_run_limit_detected "$log_file"; then
      if [[ "$target_pid" =~ ^[0-9]+$ ]]; then
        usage_kill_process_tree "$target_pid" TERM
      else
        codex_run_kill_script_for_log "$parent_pid" "$run_file" "$log_file" TERM
      fi
      sleep 1 || true
      if [[ "$target_pid" =~ ^[0-9]+$ ]]; then
        kill -0 "$target_pid" 2>/dev/null && usage_kill_process_tree "$target_pid" KILL
      else
        codex_run_kill_script_for_log "$parent_pid" "$run_file" "$log_file" KILL
      fi
      return 0
    fi
    sleep "$interval" || return 0
  done
}

codex_run_cleanup() {
  local watch_pid="${1:-}"
  local monitor_pid="${2:-}"
  local run_file="${3:-}"
  local log_file="${4:-}"
  local keep_log="${5:-0}"

  if [[ "$monitor_pid" =~ ^[0-9]+$ ]]; then
    kill "$monitor_pid" 2>/dev/null || true
    wait "$monitor_pid" 2>/dev/null || true
  fi
  if [[ "$watch_pid" =~ ^[0-9]+$ ]]; then
    kill "$watch_pid" 2>/dev/null || true
    wait "$watch_pid" 2>/dev/null || true
  fi
  [[ -n "$run_file" ]] && rm -f "$run_file" 2>/dev/null || true
  if [[ "$keep_log" != "1" && -n "$log_file" ]]; then
    rm -f "$log_file" 2>/dev/null || true
  fi
}

cmd_run() {
  ensure_dirs

  local max_attempts="${CODEX_AUTH_ROLL_ATTEMPTS:-5}"
  local auto_ttl="${CODEX_AUTH_ROLL_AUTO_TTL:-}"
  local run_auto="${CODEX_AUTH_RUN_AUTO:-1}"
  local watch_enabled="${CODEX_AUTH_ROLL_WATCH:-0}"
  local keep_log="${CODEX_AUTH_KEEP_RUN_LOG:-0}"
  local log_enabled="${CODEX_AUTH_ROLL_LOG:-1}"
  local args=()
  local auto_args=()
  local codex_cli attempt status log_file run_file watch_pid monitor_pid target_pid launcher_arg
  local stdout_fd stderr_fd stdout_tee_pid stderr_tee_pid

  [[ "$max_attempts" =~ ^[1-9][0-9]*$ ]] || max_attempts=5
  [[ -z "$auto_ttl" || "$auto_ttl" =~ ^[0-9]+$ ]] || auto_ttl=""

  while (( $# > 0 )); do
    case "$1" in
      --attempts)
        [[ "${2:-}" =~ ^[1-9][0-9]*$ ]] || die "usage: codex-auth run [--attempts n] -- <codex args>"
        max_attempts="$2"
        shift 2
        ;;
      --no-auto)
        run_auto=0
        shift
        ;;
      --no-log)
        log_enabled=0
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

  codex_cli="$(codex_bin)" || die "codex command not found"
  require_codex_launcher "$codex_cli"

  local run_args=("${args[@]}")
  attempt=1
  log_file=""
  run_file=""
  watch_pid=""
  monitor_pid=""
  target_pid=""
  trap 'codex_run_cleanup "${watch_pid:-}" "${monitor_pid:-}" "${run_file:-}" "${log_file:-}" "${keep_log:-0}"' EXIT
  trap 'codex_run_cleanup "${watch_pid:-}" "${monitor_pid:-}" "${run_file:-}" "${log_file:-}" "${keep_log:-0}"; exit 130' HUP INT TERM

  while true; do
    if [[ "$run_auto" != "0" && "${CODEX_AUTH_AUTO:-1}" != "0" ]]; then
      auto_args=(--quiet --no-background)
      [[ "$auto_ttl" =~ ^[0-9]+$ ]] && auto_args+=(--ttl "$auto_ttl")
      CODEX_AUTH_NO_BACKGROUND=1 cmd_auto "${auto_args[@]}" || true
    fi

    watch_pid=""
    if [[ "$run_auto" != "0" && "$watch_enabled" != "0" && "${CODEX_AUTH_AUTO:-1}" != "0" ]]; then
      (
        watch_interval="${CODEX_AUTH_ROLL_INTERVAL:-60}"
        [[ "$watch_interval" =~ ^[1-9][0-9]*$ ]] || watch_interval=60
        while true; do
          sleep "$watch_interval" || exit 0
          [[ "${CODEX_AUTH_AUTO:-1}" != "0" ]] || continue
          watch_auto_args=(--quiet --no-background)
          [[ "$auto_ttl" =~ ^[0-9]+$ ]] && watch_auto_args+=(--ttl "$auto_ttl")
          CODEX_AUTH_NO_BACKGROUND=1 cmd_auto "${watch_auto_args[@]}" || true
        done
      ) &
      watch_pid=$!
    fi

    log_file=""
    run_file=""
    monitor_pid=""
    if [[ "$log_enabled" != "0" ]]; then
      log_file="$(mktemp "$CODEX_HOME/.tmp/codex-run.XXXXXX.log")"
    fi

    status=0
    if [[ "$log_enabled" != "0" && -n "$log_file" && -t 0 && -t 1 && -r /dev/tty ]] && command -v script >/dev/null 2>&1; then
      run_file="$(mktemp "$CODEX_HOME/.tmp/codex-run.XXXXXX.sh")"
      {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'export CODEX_AUTH_RUNNER=1\n'
        printf 'exec %q' "$codex_cli"
        for launcher_arg in "${run_args[@]}"; do
          printf ' %q' "$launcher_arg"
        done
        printf '\n'
      } > "$run_file"
      chmod 700 "$run_file"
      set +e
      if [[ "${CODEX_AUTH_ROLL_LIVE_MONITOR:-1}" != "0" && -n "$log_file" ]]; then
        codex_run_limit_monitor_loop "$log_file" "" "$$" "$run_file" &
        monitor_pid=$!
      fi
      script -qefc "$run_file" "$log_file"
      status=$?
    elif [[ "$log_enabled" != "0" && -n "$log_file" && ! -t 1 ]]; then
      set +e
      # Truncate exactly once, then append from two owned tee processes.  Bash
      # process substitutions are asynchronous; keep their PIDs and wait for
      # both writers before scanning the log for a usage-limit retry.
      : > "$log_file"
      exec {stdout_fd}> >(tee -a "$log_file")
      stdout_tee_pid=$!
      exec {stderr_fd}> >(tee -a "$log_file" >&2)
      stderr_tee_pid=$!
      CODEX_AUTH_RUNNER=1 "$codex_cli" "${run_args[@]}" 1>&"$stdout_fd" 2>&"$stderr_fd" &
      target_pid=$!
      if [[ "${CODEX_AUTH_ROLL_LIVE_MONITOR:-1}" != "0" && -n "$log_file" ]]; then
        codex_run_limit_monitor_loop "$log_file" "$target_pid" &
        monitor_pid=$!
      fi
      wait "$target_pid"
      status=$?
      # The monitor was forked after these writer FDs opened, so stop it before
      # waiting for tee EOF; otherwise its inherited descriptors keep both
      # pipes alive forever.
      if [[ "$monitor_pid" =~ ^[0-9]+$ ]]; then
        kill "$monitor_pid" 2>/dev/null || true
        wait "$monitor_pid" 2>/dev/null || true
        monitor_pid=""
      fi
      exec {stdout_fd}>&-
      exec {stderr_fd}>&-
      wait "$stderr_tee_pid" 2>/dev/null || true
      wait "$stdout_tee_pid" 2>/dev/null || true
      stdout_fd=""
      stderr_fd=""
      stdout_tee_pid=""
      stderr_tee_pid=""
    else
      set +e
      CODEX_AUTH_RUNNER=1 "$codex_cli" "${run_args[@]}"
      status=$?
      [[ -n "$log_file" ]] && : > "$log_file"
    fi
    set -e
    codex_run_cleanup "$watch_pid" "$monitor_pid" "$run_file" "" 1
    watch_pid=""
    monitor_pid=""
    run_file=""

    if (( status != 0 && attempt < max_attempts )) && [[ -n "$log_file" ]] && codex_run_limit_detected "$log_file"; then
      local resume_args=()
      [[ "$keep_log" == "1" ]] || rm -f "$log_file" 2>/dev/null || true
      log_file=""
      print_status_note roll "usage limit, rotating" >&2
      set -- "${run_args[@]}"
      while (( $# > 0 )); do
        if [[ "$1" == "--" ]]; then
          shift
          break
        fi
        case "$1" in
          -c|--config|--enable|--disable|--remote|--remote-auth-token-env|-i|--image|-m|--model|-p|--profile|--profile-v2|-s|--sandbox|-a|--ask-for-approval|-C|--cd|--cwd)
            resume_args+=("$1")
            shift
            if (( $# > 0 )); then
              resume_args+=("$1")
              shift
            fi
            ;;
          --dangerously-bypass-approvals-and-sandbox|--yolo|--oss|--strict-config|--dangerously-auto-approve-everything|-*)
            resume_args+=("$1")
            shift
            ;;
          *)
            break
            ;;
        esac
      done
      if [[ "${1:-}" == "resume" ]]; then
        shift
        if [[ "${1:-}" == "--last" ]]; then
          resume_args+=(resume --last)
        elif [[ -n "${1:-}" && "${1:-}" != -* ]]; then
          resume_args+=(resume "$1")
        else
          resume_args+=(resume --last)
        fi
      else
        resume_args+=(resume --last)
      fi
      run_args=("${resume_args[@]}")
      attempt=$((attempt + 1))
      continue
    fi

    codex_run_cleanup "$watch_pid" "$monitor_pid" "$run_file" "$log_file" "$keep_log"
    trap - EXIT HUP INT TERM
    return "$status"
  done
}

cmd_recover() {
  ensure_dirs
  [[ -t 0 && -t 1 ]] || die "recover needs tty"
  command -v jq >/dev/null 2>&1 || die "jq is required for recovery"

  local codex_cli
  codex_cli="$(codex_bin)" || die "codex command not found"
  require_codex_launcher "$codex_cli"

  cmd_auto --quiet --no-background

  export CODEX_AUTH_RUNNER=1
  if (( $# == 0 )); then
    print_status_note recover "latest session"
    exec "$codex_cli" resume --last
  fi

  print_status_note recover "session $*"
  exec "$codex_cli" resume "$@"
}
