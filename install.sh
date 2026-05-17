#!/usr/bin/env bash
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
bindir="$prefix/bin"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

mkdir -p "$bindir"
install -m 0755 "$repo_dir/bin/codex-auth" "$bindir/codex-auth"

if [[ "${1:-}" == "--wrap-codex" ]]; then
  if [[ -e "$bindir/codex" && ! -L "$bindir/codex" ]]; then
    cp "$bindir/codex" "$bindir/codex.backup.$(date +%Y%m%d%H%M%S)"
  fi
  install -m 0755 "$repo_dir/bin/codex" "$bindir/codex"
fi

printf 'installed %s\n' "$bindir/codex-auth"
if [[ "${1:-}" == "--wrap-codex" ]]; then
  printf 'installed %s\n' "$bindir/codex"
else
  printf 'run with: codex-auth run -- codex resume --last\n'
fi
