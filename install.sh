#!/usr/bin/env bash
set -euo pipefail

prefix="${PREFIX:-$HOME/.local}"
bindir="$prefix/bin"
libdir="$prefix/lib/codex-auth"
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
codex_home="${CODEX_HOME:-$HOME/.codex}"
standalone_root="$codex_home/packages/standalone"
tui_source="$repo_dir/tui"
tui_dir="$libdir/tui"
claude_gpt_proxy_version="0.1.10-codex-auth.2"

mkdir -p "$bindir" "$libdir"
if [[ ! -f "$tui_source/pyproject.toml" || ! -f "$tui_source/uv.lock" || ! -d "$tui_source/src/codex_auth_tui" ]]; then
  printf 'codex-auth TUI project is missing from %s\n' "$tui_source" >&2
  exit 1
fi

# Stage the complete TUI, publish it at its final absolute path, and bootstrap
# there before publishing any shell files.  uv environments are not
# relocatable; the rollback trap restores the previous TUI if sync fails.
install_stage="$(mktemp -d "$libdir/.codex-auth-install.XXXXXX")"
tui_stage="$install_stage/tui"
tui_previous=""
tui_published=0
install_complete=0
mkdir -p "$tui_stage"

cleanup_install_stage() {
  if [[ "$install_complete" != "1" && "$tui_published" == "1" ]]; then
    rm -rf "$tui_dir"
    if [[ -n "$tui_previous" && -e "$tui_previous" ]]; then
      mv "$tui_previous" "$tui_dir" 2>/dev/null || true
    fi
  fi
  [[ ! -e "$install_stage" ]] || rm -rf "$install_stage"
}
trap cleanup_install_stage EXIT

for tui_file in README.md pyproject.toml uv.lock; do
  install -m 0644 "$tui_source/$tui_file" "$tui_stage/$tui_file"
done
while IFS= read -r -d '' tui_file; do
  tui_relative="${tui_file#$tui_source/}"
  mkdir -p "$tui_stage/${tui_relative%/*}"
  install -m 0644 "$tui_file" "$tui_stage/$tui_relative"
done < <(find "$tui_source/src" -type f \( -name '*.py' -o -name '*.tcss' \) -print0)

if [[ -e "$tui_dir" ]]; then
  tui_previous="$install_stage/tui.previous"
  mv "$tui_dir" "$tui_previous"
fi
mv "$tui_stage" "$tui_dir"
tui_published=1

if [[ "${CODEX_AUTH_TUI_SKIP_BOOTSTRAP:-0}" != "1" ]]; then
  if ! command -v uv >/dev/null 2>&1; then
    printf 'uv is required to create the private codex-auth TUI environment.\n' >&2
    printf 'Install uv and rerun ./install.sh. No Python packages are installed globally.\n' >&2
    exit 1
  fi
  if ! uv --native-tls sync --project "$tui_dir" --no-dev --locked; then
    exit 1
  fi
fi

install_claude_gpt_proxy() {
  local platform archive_name checksum_name release_base download_dir
  local archive checksum extracted staged_binary actual_version

  [[ "${CODEX_AUTH_INSTALL_CLAUDE_GPT_PROXY:-1}" != "0" ]] || return 0
  if [[ -x "$bindir/claude-code-proxy" ]] \
    && [[ "$("$bindir/claude-code-proxy" --version 2>/dev/null || true)" == "claude-code-proxy $claude_gpt_proxy_version" ]]; then
    return 0
  fi

  case "$(uname -s):$(uname -m)" in
    Linux:x86_64|Linux:amd64) platform="linux-amd64" ;;
    Linux:aarch64|Linux:arm64) platform="linux-arm64" ;;
    *)
      printf 'unsupported platform for claude-code-proxy: %s %s\n' "$(uname -s)" "$(uname -m)" >&2
      printf 'set CODEX_AUTH_INSTALL_CLAUDE_GPT_PROXY=0 to install codex-auth without claude-gpt support\n' >&2
      return 1
      ;;
  esac

  archive_name="claude-code-proxy-$platform.tar.gz"
  checksum_name="claude-code-proxy-$platform.sha256"
  release_base="https://github.com/editnori/claude-code-proxy/releases/download/v$claude_gpt_proxy_version"
  download_dir="$install_stage/claude-code-proxy"
  archive="$download_dir/$archive_name"
  checksum="$download_dir/$checksum_name"
  mkdir -p "$download_dir"

  if [[ -n "${CODEX_AUTH_CLAUDE_GPT_PROXY_ARCHIVE:-}" ]]; then
    [[ -f "$CODEX_AUTH_CLAUDE_GPT_PROXY_ARCHIVE" ]] || {
      printf 'claude-code-proxy archive not found: %s\n' "$CODEX_AUTH_CLAUDE_GPT_PROXY_ARCHIVE" >&2
      return 1
    }
    cp "$CODEX_AUTH_CLAUDE_GPT_PROXY_ARCHIVE" "$archive"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-connrefused --connect-timeout 10 --max-time 120 \
      "$release_base/$archive_name" -o "$archive"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=120 -qO "$archive" "$release_base/$archive_name"
  else
    printf 'curl or wget is required to install claude-code-proxy\n' >&2
    return 1
  fi

  if [[ -n "${CODEX_AUTH_CLAUDE_GPT_PROXY_CHECKSUM:-}" ]]; then
    [[ -f "$CODEX_AUTH_CLAUDE_GPT_PROXY_CHECKSUM" ]] || {
      printf 'claude-code-proxy checksum not found: %s\n' "$CODEX_AUTH_CLAUDE_GPT_PROXY_CHECKSUM" >&2
      return 1
    }
    cp "$CODEX_AUTH_CLAUDE_GPT_PROXY_CHECKSUM" "$checksum"
  elif command -v curl >/dev/null 2>&1; then
    curl -fsSL --retry 3 --retry-connrefused --connect-timeout 10 --max-time 30 \
      "$release_base/$checksum_name" -o "$checksum"
  elif command -v wget >/dev/null 2>&1; then
    wget --tries=3 --timeout=30 -qO "$checksum" "$release_base/$checksum_name"
  fi

  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$download_dir" && sha256sum -c "$checksum_name" >/dev/null)
  elif command -v shasum >/dev/null 2>&1; then
    (cd "$download_dir" && shasum -a 256 -c "$checksum_name" >/dev/null)
  else
    printf 'sha256sum or shasum is required to verify claude-code-proxy\n' >&2
    return 1
  fi

  tar -xzf "$archive" -C "$download_dir"
  extracted="$download_dir/claude-code-proxy"
  [[ -f "$extracted" ]] || {
    printf 'verified claude-code-proxy archive did not contain its binary\n' >&2
    return 1
  }
  chmod 0755 "$extracted"
  actual_version="$("$extracted" --version 2>/dev/null || true)"
  [[ "$actual_version" == "claude-code-proxy $claude_gpt_proxy_version" ]] || {
    printf 'verified proxy reported an unexpected version: %s\n' "${actual_version:-unknown}" >&2
    return 1
  }
  staged_binary="$(mktemp "$bindir/.claude-code-proxy.XXXXXX")"
  if ! install -m 0755 "$extracted" "$staged_binary" \
    || ! mv -f "$staged_binary" "$bindir/claude-code-proxy"
  then
    rm -f "$staged_binary"
    return 1
  fi
}

install_claude_gpt_proxy

install -m 0755 "$repo_dir/bin/codex-auth" "$bindir/codex-auth"
install -m 0755 "$repo_dir/bin/codex-auth-tui" "$bindir/codex-auth-tui"
install -m 0755 "$repo_dir/bin/claude-gpt" "$bindir/claude-gpt"
install -m 0755 "$repo_dir/bin/codex" "$libdir/codex-shim"
install -m 0644 "$repo_dir/lib/codex-auth/"*.sh "$libdir/"
shopt -s nullglob
codex_auth_patch_files=("$repo_dir/lib/codex-auth/"*.patch)
shopt -u nullglob
if (( ${#codex_auth_patch_files[@]} > 0 )); then
  install -m 0644 "${codex_auth_patch_files[@]}" "$libdir/"
fi
[[ -z "$tui_previous" ]] || rm -rf "$tui_previous"
install_complete=1
rm -rf "$install_stage"
trap - EXIT

is_codex_auth_shim() {
  local path="$1"
  [[ -r "$path" ]] || return 1
  [[ "$(LC_ALL=C head -c 2 "$path" 2>/dev/null || true)" == '#!' ]] || return 1
  LC_ALL=C head -c 8192 "$path" 2>/dev/null | grep -aEq 'CODEX_AUTH_SHIM|codex-auth (run|auto)'
}

write_codex_real_launcher() {
  local target="$1"
  local real="$2"
  local tmp

  tmp="$(mktemp "${real%/*}/.codex-real.XXXXXX")"
  if ! {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf 'exec %q "$@"\n' "$target"
  } > "$tmp" \
    || ! chmod 0755 "$tmp" \
    || ! mv -f "$tmp" "$real"
  then
    rm -f "$tmp"
    return 1
  fi
}

promote_real_candidate() {
  local current="$1"
  local real="$2"
  local candidate="$3"
  local target

  [[ -x "$candidate" ]] || return 1
  [[ "$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")" == "$(realpath "$current" 2>/dev/null || printf '%s' "$current")" ]] && return 1
  is_codex_auth_shim "$candidate" && return 1
  case "$candidate" in
    "$standalone_root/current/bin/codex"|"$standalone_root/current/codex")
      target="$candidate"
      ;;
    *)
      target="$(realpath "$candidate" 2>/dev/null || printf '%s' "$candidate")"
      ;;
  esac
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
  local backup index
  local backups=()

  shopt -s nullglob
  backups=("$bindir"/codex.backup.*)
  shopt -u nullglob
  for (( index=${#backups[@]} - 1; index >= 0; index-- )); do
    backup="${backups[index]}"
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

  promote_listed_real_candidates "$current" "$real" \
    "$standalone_root/current/bin/codex" \
    "$standalone_root/current/codex" && return 0
  promote_real_backup "$real" "$current" && return 0
  if [[ -x "$real" ]] && ! is_codex_auth_shim "$real"; then
    return 0
  fi
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

install_maintenance_cron() {
  local begin_marker='# BEGIN codex-auth maintain'
  local end_marker='# END codex-auth maintain'
  local current filtered updated cron_path cron_command

  [[ "${CODEX_AUTH_INSTALL_MAINTAIN_CRON:-1}" != "0" ]] || return 0
  if ! command -v crontab >/dev/null 2>&1; then
    printf 'warning: crontab is unavailable; automatic direct-curl recovery was not installed\n' >&2
    return 0
  fi
  current="$(mktemp "$libdir/.cron-current.XXXXXX")"
  filtered="$(mktemp "$libdir/.cron-filtered.XXXXXX")"
  updated="$(mktemp "$libdir/.cron-updated.XXXXXX")"
  crontab -l > "$current" 2>/dev/null || :
  awk -v begin="$begin_marker" -v end="$end_marker" '
    $0 == begin { skip = 1; next }
    $0 == end { skip = 0; next }
    !skip { print }
  ' "$current" > "$filtered"
  cron_path="$HOME/.cargo/bin:$bindir:/usr/local/bin:/usr/bin:/bin"
  cron_command="* * * * * PATH='$cron_path' '$bindir/codex-auth' maintain --quiet"
  {
    cat "$filtered"
    [[ ! -s "$filtered" ]] || printf '\n'
    printf '%s\n%s\n%s\n' "$begin_marker" "$cron_command" "$end_marker"
  } > "$updated"
  if ! crontab "$updated"; then
    printf 'warning: could not install codex-auth maintenance cron job\n' >&2
  fi
  rm -f "$current" "$filtered" "$updated"
}

if [[ "${1:-}" == "--wrap-codex" ]]; then
  promote_real_codex
  if [[ -e "$bindir/codex" ]] && ! is_codex_auth_shim "$bindir/codex"; then
    codex_backup="$bindir/codex.backup.$(date +%Y%m%d%H%M%S)"
    if [[ -L "$bindir/codex" ]]; then
      cp -P "$bindir/codex" "$codex_backup"
    else
      cp -L "$bindir/codex" "$codex_backup"
    fi
  fi
  rm -f "$bindir/codex"
  install -m 0755 "$repo_dir/bin/codex" "$bindir/codex"
  install_maintenance_cron
fi

printf 'installed %s\n' "$bindir/codex-auth"
printf 'installed %s\n' "$bindir/codex-auth-tui"
printf 'installed %s\n' "$bindir/claude-gpt"
if [[ -x "$bindir/claude-code-proxy" ]]; then
  printf 'installed %s\n' "$bindir/claude-code-proxy"
fi
if [[ "${1:-}" == "--wrap-codex" ]]; then
  printf 'installed %s\n' "$bindir/codex"
  if [[ -x "$bindir/codex-real" ]]; then
    printf 'real codex %s\n' "$bindir/codex-real"
  else
    printf 'warning: no existing codex binary was captured as %s\n' "$bindir/codex-real" >&2
  fi
  printf 'enable in-session switching with: codex-auth patch-codex\n'
else
  printf 'watch with: codex-auth watch\n'
  printf 'run with: codex-auth run -- resume --last\n'
fi
