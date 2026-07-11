# shellcheck shell=bash

codex_auth_path_is_shim() {
  local path="$1"

  [[ -r "$path" ]] || return 1
  [[ "$(LC_ALL=C head -c 2 "$path" 2>/dev/null || true)" == '#!' ]] || return 1
  LC_ALL=C head -c 8192 "$path" 2>/dev/null | grep -aEq 'CODEX_AUTH_SHIM|codex-auth (run|auto)'
}

codex_auth_standalone_bin() {
  local candidate

  for candidate in \
    "$CODEX_HOME/packages/standalone/current/bin/codex" \
    "$CODEX_HOME/packages/standalone/current/codex"
  do
    [[ -x "$candidate" ]] && { printf '%s\n' "$candidate"; return 0; }
  done
  return 1
}

codex_auth_restore_shim_if_needed() {
  local stock_bin="$1"
  local template target target_real stock_real tmp

  template="${CODEX_AUTH_SHIM_TEMPLATE:-$CODEX_AUTH_LIB_DIR/codex-shim}"
  target="${CODEX_AUTH_SHIM_PATH:-$CODEX_AUTH_SCRIPT_DIR/codex}"
  [[ -r "$template" ]] || return 0
  codex_auth_path_is_shim "$target" && return 0

  # Only reclaim the command when the official standalone installer owns it.
  # A Homebrew/npm/custom Codex at this path is user intent, not drift.
  target_real="$(realpath "$target" 2>/dev/null || true)"
  stock_real="$(realpath "$stock_bin" 2>/dev/null || true)"
  [[ -n "$target_real" && "$target_real" == "$stock_real" ]] || return 0

  mkdir -p "${target%/*}"
  tmp="$(mktemp "${target%/*}/.codex-auth-maintain.XXXXXX")"
  if ! install -m 0755 "$template" "$tmp" \
    || ! mv -Tf "$tmp" "$target" 2>/dev/null
  then
    rm -f "$tmp"
    return 1
  fi
}

cmd_maintain() {
  local quiet=0 stock_bin standalone_root install_lock_fd

  while (( $# > 0 )); do
    case "$1" in
      --quiet|-q) quiet=1 ;;
      *) die "usage: codex-auth maintain [--quiet]" ;;
    esac
    shift
  done

  ensure_dirs
  stock_bin="$(codex_auth_standalone_bin || true)"
  [[ -n "$stock_bin" ]] || return 0
  standalone_root="$CODEX_HOME/packages/standalone"

  # The official installer uses either this flock or install.lock.d. Never
  # race its atomic current/visible-command publication.
  [[ ! -d "$standalone_root/install.lock.d" ]] || return 0
  mkdir -p "$standalone_root"
  exec {install_lock_fd}>"$standalone_root/install.lock"
  flock -n "$install_lock_fd" || return 0
  codex_auth_restore_shim_if_needed "$stock_bin" || true
  flock -u "$install_lock_fd" 2>/dev/null || true
  exec {install_lock_fd}>&-

  CODEX_AUTH_STOCK_CODEX_BIN="$stock_bin" cmd_patch_codex --background --quiet
  (( quiet )) || printf 'codex-auth maintenance queued for %s\n' "$stock_bin"
}
