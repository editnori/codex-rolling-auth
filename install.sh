#!/usr/bin/env bash
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
bindir="$prefix/bin"
libdir="$prefix/lib/codex-auth"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$bindir" "$libdir"
install -m 0755 "$repo_dir/bin/codex-auth" "$bindir/codex-auth"
install -m 0644 "$repo_dir/lib/codex-auth/"*.sh "$libdir/"

is_codex_auth_shim() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  grep -Eq 'CODEX_AUTH_SHIM|codex-auth (run|auto)' "$path" 2>/dev/null
}

write_codex_real_launcher() {
  local target="$1"
  local real="$2"

  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'exec %q "$@"\n' "$target"
  } > "$real"
  chmod 0755 "$real"
}

promote_real_candidate() {
  local current="$1"
  local real="$2"
  local candidate="$3"
  local target

  [[ -x "$candidate" ]] || return 1
  [[ "$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")" == "$(realpath "$current" 2>/dev/null || printf '%s' "$current")" ]] && return 1
  is_codex_auth_shim "$candidate" && return 1
  target="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
  write_codex_real_launcher "$target" "$real"
}

promote_real_backup() {
  local real="$1"
  local backup="$2"

  [[ -e "$backup" ]] || return 1
  is_codex_auth_shim "$backup" && return 1
  cp -P "$backup" "$real"
  chmod 0755 "$real" 2>/dev/null || true
}

promote_real_backups() {
  local real="$1"
  local backup

  for backup in "$bindir"/codex.backup.*; do
    promote_real_backup "$real" "$backup" && return 0
  done
  return 1
}

promote_listed_real_candidates() {
  local current="$1"
  local real="$2"
  local candidate
  shift 2

  for candidate in "$@"; do
    promote_real_candidate "$current" "$real" "$candidate" && return 0
  done
  return 1
}

promote_path_real_candidates() {
  local current="$1"
  local real="$2"
  local candidate path_dir
  local path_dirs=()

  IFS=':' read -r -a path_dirs <<<"${PATH:-}"
  for path_dir in "${path_dirs[@]}"; do
    [[ -n "$path_dir" ]] || path_dir='.'
    candidate="$path_dir/codex"
    promote_real_candidate "$current" "$real" "$candidate" && return 0
  done
  return 1
}

promote_real_codex() {
  local current="$bindir/codex"
  local real="$bindir/codex-real"

  [[ -x "$real" ]] && return 0

  promote_real_backup "$real" "$current" && return 0
  promote_real_backups "$real" && return 0
  promote_listed_real_candidates "$current" "$real" \
    "$HOME/.bun/bin/codex-real" \
    "$HOME/.bun/bin/codex" \
    "$HOME/.npm-global/bin/codex" && return 0
  promote_path_real_candidates "$current" "$real" && return 0
  promote_listed_real_candidates "$current" "$real" \
    /usr/local/bin/codex \
    /usr/bin/codex \
    /bin/codex && return 0
}

if [[ "${1:-}" == "--wrap-codex" ]]; then
  promote_real_codex
  if [[ -e "$bindir/codex" ]] && ! is_codex_auth_shim "$bindir/codex"; then
    cp -L "$bindir/codex" "$bindir/codex.backup.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0755 "$repo_dir/bin/codex" "$bindir/codex"
fi

printf 'installed %s\n' "$bindir/codex-auth"
if [[ "${1:-}" == "--wrap-codex" ]]; then
  printf 'installed %s\n' "$bindir/codex"
  if [[ -x "$bindir/codex-real" ]]; then
    printf 'real codex %s\n' "$bindir/codex-real"
  else
    printf 'warning: no existing codex binary was captured as %s\n' "$bindir/codex-real" >&2
  fi
else
  printf 'run with: codex-auth run -- resume --last\n'
fi
