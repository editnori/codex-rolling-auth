# shellcheck shell=bash

display_path() {
  local path="$1"
  local home_prefix="${HOME%/}/"

  if [[ -n "${HOME:-}" && "$path" == "$HOME" ]]; then
    printf '~'
  elif [[ -n "${HOME:-}" && "$path" == "$home_prefix"* ]]; then
    printf '~/%s' "${path#$home_prefix}"
  else
    printf '%s' "$path"
  fi
}

compact_display_path() {
  local path="$1"
  local width="${2:-0}"
  local rendered base prefix candidate

  rendered="$(display_path "$path")"
  if [[ "$width" =~ ^[0-9]+$ && "$width" -gt 0 && ${#rendered} -gt width && "$rendered" == */* ]]; then
    base="${rendered##*/}"
    if usage_unicode_enabled; then
      prefix="…/"
    else
      prefix=".../"
    fi
    candidate="$prefix$base"
    fit_profile_text_rtrim "$candidate" "$width"
    return 0
  fi
  printf '%s' "$rendered"
}

die() {
  if declare -F print_error >/dev/null 2>&1; then
    print_error "$*"
  else
    printf '%s\n' "$*" >&2
  fi
  exit 1
}

require_arg_count_between() {
  local count="$1" min="$2" max="$3"
  shift 3
  (( count >= min && count <= max )) || die "$*"
}

codex_bin() {
  if [[ -n "$CODEX_BIN" && -x "$CODEX_BIN" ]]; then
    printf '%s\n' "$CODEX_BIN"
  elif [[ -x "$CODEX_HOME/packages/standalone/current/bin/codex" ]]; then
    printf '%s\n' "$CODEX_HOME/packages/standalone/current/bin/codex"
  elif [[ -x "$CODEX_HOME/packages/standalone/current/codex" ]]; then
    printf '%s\n' "$CODEX_HOME/packages/standalone/current/codex"
  elif [[ -n "${CODEX_AUTH_SCRIPT_DIR:-}" && -x "$CODEX_AUTH_SCRIPT_DIR/codex-real" ]]; then
    printf '%s\n' "$CODEX_AUTH_SCRIPT_DIR/codex-real"
  elif [[ -x "$HOME/.bun/bin/codex-real" ]]; then
    printf '%s\n' "$HOME/.bun/bin/codex-real"
  elif [[ -x "$HOME/.bun/bin/codex" ]]; then
    printf '%s\n' "$HOME/.bun/bin/codex"
  else
    command -v codex 2>/dev/null || return 1
  fi
}

codex_launcher_is_script() {
  local codex_cli="$1"

  [[ -r "$codex_cli" ]] || return 1
  [[ "$(LC_ALL=C head -c 2 "$codex_cli" 2>/dev/null || true)" == '#!' ]]
}

canonical_codex_bin() {
  local codex_cli="$1"
  local target

  if ! codex_launcher_is_script "$codex_cli"; then
    printf '%s\n' "$codex_cli"
    return 0
  fi

  target="$(sed -nE '1,32s/^[[:space:]]*exec[[:space:]]+"?([^" ]+)"?[[:space:]]+"\$@".*$/\1/p' "$codex_cli" 2>/dev/null | head -n 1 || true)"
  if [[ -n "$target" ]]; then
    if [[ "$target" != /* ]]; then
      target="$(cd "$(dirname "$codex_cli")" && realpath "$target" 2>/dev/null || printf '%s/%s\n' "$(pwd -P)" "$target")"
    fi
    if [[ -x "$target" ]]; then
      printf '%s\n' "$target"
      return 0
    fi
  fi

  printf '%s\n' "$codex_cli"
}

codex_launcher_needs_node() {
  local codex_cli="$1"
  local first_line=""

  codex_launcher_is_script "$codex_cli" || return 1
  IFS= read -r first_line < "$codex_cli" || return 1
  [[ "$first_line" == "#!"*"env node"* ]]
}

require_codex_launcher() {
  local codex_cli="$1"

  if codex_launcher_needs_node "$codex_cli" && ! command -v node >/dev/null 2>&1; then
    die "node needed for codex"
  fi
}

normalize_codex_status_text() {
  local text="$1" line normalized=""

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" == "WARNING: proceeding, even though we could not update PATH:"* ]] && continue
    line="${line//$'\t'/ }"
    normalized+=" $line"
  done <<<"$text"
  while [[ "$normalized" == *"  "* ]]; do normalized="${normalized//  / }"; done
  while [[ "$normalized" == " "* ]]; do normalized="${normalized# }"; done
  while [[ "$normalized" == *" " ]]; do normalized="${normalized% }"; done
  printf '%s\n' "$normalized"
}

ensure_dirs() {
  mkdir -p "$CODEX_HOME" "$PROFILE_DIR" "$BACKUP_DIR" "$CODEX_HOME/.tmp"
  chmod 700 "$CODEX_HOME" "$PROFILE_DIR" "$BACKUP_DIR" "$CODEX_HOME/.tmp" 2>/dev/null || true
}

selector_prompt_available() {
  [[ "${CODEX_AUTH_NO_PROMPT:-}" != "1" && -t 0 && -t 1 && -r /dev/tty ]] || return 1
  [[ "${TERM:-}" == "dumb" && "${CODEX_AUTH_DUMB_PROMPT:-0}" != "1" ]] && return 1
  return 0
}

acquire_mutation_lock() {
  local wait
  if (( MUTATION_LOCK_HELD )); then
    return 0
  fi

  ensure_dirs
  wait="${CODEX_AUTH_MUTATION_LOCK_WAIT:-30}"
  [[ "$wait" =~ ^[0-9]+$ ]] || wait=30
  exec {MUTATION_LOCK_FD}>"$CODEX_HOME/.tmp/codex-auth-mutation.lock"
  flock -w "$wait" "$MUTATION_LOCK_FD" || die "auth change already running"
  MUTATION_LOCK_HELD=1
}

require_name() {
  local name="${1:-}"
  [[ -n "$name" ]] || die "missing profile name"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || die "profile names may only use letters, numbers, dot, underscore, and dash"
}

profile_path() {
  local name="$1"
  printf '%s/%s.json\n' "$PROFILE_DIR" "$name"
}

active_profile_marker_read() {
  [[ -f "$ACTIVE_PROFILE_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -er '
    select(.version == 2)
    | .profile
    | select(type == "string" and test("^[A-Za-z0-9._-]+$"))
  ' "$ACTIVE_PROFILE_FILE" 2>/dev/null
}

active_profile_marker_write() {
  local name="$1" source="${2:-}" tmp kind identity fingerprint revision

  require_name "$name"
  ensure_dirs
  [[ -n "$source" ]] || source="$(profile_path "$name")"
  require_auth_file "$source"
  command -v jq >/dev/null 2>&1 || return 1
  kind="$(auth_file_kind "$source" || true)"
  identity="$(auth_file_account_identity "$source" || true)"
  fingerprint="$(credential_fingerprint "$source" || true)"
  revision="$(auth_file_revision "$source" || true)"
  [[ -n "$fingerprint" && -n "$revision" ]] || return 1
  tmp="$(mktemp "$CODEX_HOME/.tmp/auth-active-profile.XXXXXX")"
  if ! jq -n \
    --arg profile "$name" \
    --arg kind "$kind" \
    --arg account_identity "$identity" \
    --arg profile_fingerprint "$fingerprint" \
    --arg profile_revision "$revision" \
    '{version: 2, profile: $profile, kind: $kind, account_identity: $account_identity, profile_fingerprint: $profile_fingerprint, profile_revision: $profile_revision}' \
    > "$tmp" \
    || ! chmod 600 "$tmp" \
    || ! mv -f "$tmp" "$ACTIVE_PROFILE_FILE"
  then
    rm -f "$tmp"
    return 1
  fi
}

active_profile_marker_field() {
  local field="$1"

  [[ "$field" =~ ^(profile|kind|account_identity|profile_fingerprint|profile_revision)$ ]] || return 1
  [[ -f "$ACTIVE_PROFILE_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -er --arg field "$field" 'select(.version == 2) | .[$field] | select(type == "string")' "$ACTIVE_PROFILE_FILE" 2>/dev/null
}

active_profile_marker_clear() {
  local expected="${1:-}" current=""

  if [[ -n "$expected" ]]; then
    current="$(active_profile_marker_read || true)"
    [[ "$current" == "$expected" ]] || return 0
  fi
  rm -f "$ACTIVE_PROFILE_FILE"
}

require_auth_file() {
  local path="$1"
  [[ -f "$path" ]] || die "auth file not found: $path"
  [[ -s "$path" ]] || die "auth file is empty: $path"
  auth_file_is_valid "$path" || die "not a Codex auth.json with OPENAI_API_KEY or tokens: $path"
}

auth_file_is_valid() {
  local path="$1"
  [[ -f "$path" && -s "$path" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    jq -e 'has("OPENAI_API_KEY") or has("tokens")' "$path" >/dev/null 2>&1 || return 1
  fi
}

copy_auth_file_atomic() {
  local source="$1"
  local dest="$2"
  local dest_dir dest_base tmp

  dest_dir="$(dirname "$dest")"
  dest_base="$(basename "$dest")"
  tmp="$(mktemp "$dest_dir/.${dest_base}.tmp.XXXXXX")"
  if ! cp -p "$source" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! chmod 600 "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  if ! mv -f "$tmp" "$dest"; then
    rm -f "$tmp"
    return 1
  fi
}

restore_hidden_auth() {
  local hidden_auth="${1:-}"
  [[ -n "$hidden_auth" && -f "$hidden_auth" ]] || return 1
  rm -f "$AUTH_FILE"
  mv "$hidden_auth" "$AUTH_FILE"
  chmod 600 "$AUTH_FILE"
}

credential_fingerprint() {
  local path="$1" hash
  [[ -f "$path" ]] || return 1
  if command -v jq >/dev/null 2>&1; then
    hash="$(jq -r 'if .OPENAI_API_KEY then "api:" + .OPENAI_API_KEY elif .tokens.refresh_token then "chatgpt:" + .tokens.refresh_token elif .tokens.access_token then "chatgpt-access:" + .tokens.access_token else empty end' "$path" | sha256sum)"
  else
    hash="$(sha256sum "$path")"
  fi
  printf '%s\n' "${hash%% *}"
}

auth_file_revision() {
  local path="$1" hash

  [[ -f "$path" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -e . "$path" >/dev/null 2>&1 || return 1
  hash="$(jq -cS . "$path" 2>/dev/null | sha256sum)" || return 1
  printf '%s\n' "${hash%% *}"
}

auth_file_kind() {
  local path="$1"

  [[ -f "$path" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -r '
    if (((.OPENAI_API_KEY? // null) | type) == "string" and ((.OPENAI_API_KEY | length) > 0)) then "api_key"
    elif (.tokens | type == "object") then "chatgpt"
    else "unknown"
    end
  ' "$path" 2>/dev/null
}

auth_file_account_identity() {
  local path="$1" identity hash

  [[ -f "$path" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  identity="$(jq -r '
    def jwt_payload:
      split(".") as $parts
      | if ($parts | length) < 2 then null
        else ($parts[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson?)
        end;
    . as $root
    | ($root.tokens.id_token // $root.tokens.access_token // "") as $jwt
    | ($jwt | jwt_payload) as $claims
    | ($claims["https://api.openai.com/auth"] // {}) as $auth
    | [
        ($auth.chatgpt_account_id // $root.tokens.account_id // ""),
        ($auth.chatgpt_user_id // $auth.user_id // $claims.sub // "")
      ]
    | map(if type == "string" then gsub("[[:space:]]"; "") else "" end)
    | select(length == 2 and all(.[]; length > 0))
    | join("\u001f")
  ' "$path" 2>/dev/null || true)"
  [[ -n "$identity" ]] || return 1
  hash="$(printf '%s\n' "$identity" | sha256sum)"
  printf '%s\n' "${hash%% *}"
}

auth_metadata_records() {
  if (( $# == 0 )); then
    return 0
  fi

  if command -v jq >/dev/null 2>&1; then
    jq -r '
      def clean: tostring | gsub("[[:space:]]"; "");
      if .OPENAI_API_KEY then
        [input_filename, "api_key", "", ("api:" + .OPENAI_API_KEY)]
      elif .tokens then
        [input_filename,
         "chatgpt",
         ((.tokens.account_id // "") | clean),
         (if .tokens.refresh_token then
            "chatgpt:" + .tokens.refresh_token
          elif .tokens.access_token then
            "chatgpt-access:" + .tokens.access_token
          else
            ""
          end)]
      else
        [input_filename, "unknown", "", ""]
      end
      | join("\u001f")
    ' "$@" 2>/dev/null
  else
    local path hash
    for path in "$@"; do
      [[ -f "$path" ]] || continue
      hash="$(sha256sum "$path")"
      printf '%s\037unknown\037\037%s\n' "$path" "${hash%% *}"
    done
  fi
}

auth_record_fingerprint() {
  local secret="$1" hash

  if [[ -n "$secret" && ! "$secret" =~ ^[0-9a-f]{64}$ ]]; then
    hash="$(printf '%s\n' "$secret" | sha256sum)"; printf '%s\n' "${hash%% *}"
  elif [[ -n "$secret" ]]; then
    printf '%s' "$secret"
  else
    printf '%s\n' 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'
  fi
}

reserve_unique_backup_path() {
  local label="$1"
  local stamp base candidate suffix=0

  stamp="$(date +%Y%m%d_%H%M%S)"
  base="$BACKUP_DIR/auth.json.$stamp.$label"
  while true; do
    candidate="$base"
    (( suffix > 0 )) && candidate="$base.$suffix"
    if ( set -o noclobber; : > "$candidate" ) 2>/dev/null; then
      chmod 600 "$candidate"
      printf '%s\n' "$candidate"
      return 0
    fi
    suffix=$((suffix + 1))
  done
}

backup_current() {
  local label="${1:-switch}"
  ensure_dirs
  if [[ ! -f "$AUTH_FILE" ]]; then
    return 0
  fi
  local backup
  backup="$(reserve_unique_backup_path "$label")"
  if ! copy_auth_file_atomic "$AUTH_FILE" "$backup"; then
    rm -f "$backup"
    return 1
  fi
  printf '%s\n' "$backup"
}

short_account_hint() {
  local hint="$1"
  local width="${2:-13}"
  local length=${#hint}
  if [[ -z "$hint" ]]; then
    usage_glyph '·' '.'
  elif (( width < 13 && length > width )); then
    fit_profile_text "$hint" "$width"
  elif (( length > 13 )); then
    printf '%s%s%s' "${hint:0:8}" "$(usage_glyph '…' '~')" "${hint:length-4:4}"
  else
    printf '%s' "$hint"
  fi
}

auth_mode_display_label() {
  local mode="$1"

  case "$mode" in
    chatgpt)
      printf 'ChatGPT'
      ;;
    api_key)
      printf 'API key'
      ;;
    unknown|"")
      printf 'n/a'
      ;;
    *)
      printf '%s' "$mode"
      ;;
  esac
}
