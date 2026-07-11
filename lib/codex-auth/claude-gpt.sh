# shellcheck shell=bash

claude_gpt_proxy_auth_json() {
  local source="$1"
  local proxy_expires_ms="$2"

  jq -e --argjson proxy_expires_ms "$proxy_expires_ms" '
    def jwt_payload:
      split(".") as $parts
      | if ($parts | length) < 2 then null
        else ($parts[1] | gsub("-"; "+") | gsub("_"; "/") | @base64d | fromjson?)
        end;
    . as $root
    | ($root.tokens.access_token // "") as $access
    | ($access | jwt_payload) as $access_claims
    | (($root.tokens.id_token // $access) | jwt_payload) as $identity_claims
    | ($identity_claims["https://api.openai.com/auth"] // {}) as $identity_auth
    | ($identity_auth.chatgpt_account_id
        // $root.tokens.account_id
        // $access_claims.chatgpt_account_id
        // $access_claims["https://api.openai.com/auth.chatgpt_account_id"]
        // "") as $account
    | ($access_claims.exp // 0) as $exp
    | select(($access | type) == "string" and ($access | length) > 0)
    | select(($account | type) == "string" and ($account | length) > 0)
    | select(($exp | type) == "number" and $exp > 0)
    | {
        access: $access,
        refresh: "",
        # This is a private, session-scoped lease file.  A deliberately distant
        # proxy expiry prevents claude-code-proxy from entering its OAuth refresh
        # path.  The real JWT expiry is returned separately below and renewed only
        # by codex-auth, which remains the sole owner of the refresh token.
        expires: $proxy_expires_ms,
        accountId: $account,
        realExpires: ($exp * 1000 | floor)
      }
  ' "$source"
}

cmd_claude_gpt_export() (
  local requested_name="${1:-}"
  local dest="${2:-}"
  local expected_identity="${3:-}"
  [[ -n "$requested_name" && -n "$dest" ]] \
    || die "usage: codex-auth claude-gpt-export <profile|--active> <dest> [expected-identity]"
  command -v jq >/dev/null 2>&1 || die "jq is required for Claude GPT auth export"

  ensure_dirs
  sync_active_profile_from_live
  acquire_mutation_lock

  local name="$requested_name"
  if [[ "$name" == "--active" ]]; then
    name="$(resolve_active_profile_for_auth "$AUTH_FILE" || true)"
    [[ -n "$name" ]] || die "no saved ChatGPT profile is currently active"
  else
    require_name "$name"
  fi

  local source kind identity revision fingerprint parent tmp proxy_expires_ms expires_ms
  source="$(profile_path "$name")"
  [[ -f "$source" ]] || die "profile not found: $name"
  require_auth_file "$source"
  kind="$(auth_file_kind "$source" || true)"
  [[ "$kind" == "chatgpt" ]] || die "Claude GPT only supports ChatGPT profiles"
  identity="$(auth_file_account_identity "$source" || true)"
  [[ -n "$identity" ]] || die "saved profile has no stable account identity: $name"
  if [[ -n "$expected_identity" && "$identity" != "$expected_identity" ]]; then
    die "saved profile identity changed during Claude GPT session: $name"
  fi
  revision="$(auth_file_revision "$source" || true)"
  fingerprint="$(credential_fingerprint "$source" || true)"
  [[ -n "$revision" && -n "$fingerprint" ]] || die "could not snapshot profile: $name"

  parent="${dest%/*}"
  [[ "$parent" != "$dest" ]] || parent="."
  if [[ ! -d "$parent" ]]; then
    mkdir -p "$parent"
    chmod 700 "$parent"
  fi
  tmp="$(mktemp "$parent/.claude-gpt-auth.XXXXXX")"
  proxy_expires_ms=4102444800000
  if ! claude_gpt_proxy_auth_json "$source" "$proxy_expires_ms" > "$tmp" \
    || ! chmod 600 "$tmp" \
    || ! mv -f "$tmp" "$dest"
  then
    rm -f "$tmp"
    die "could not create private Claude GPT auth export"
  fi
  expires_ms="$(jq -r '.realExpires' "$dest")"
  tmp="$(mktemp "$parent/.claude-gpt-auth.XXXXXX")"
  if ! jq 'del(.realExpires)' "$dest" > "$tmp" \
    || ! chmod 600 "$tmp" \
    || ! mv -f "$tmp" "$dest"
  then
    rm -f "$tmp"
    rm -f "$dest"
    die "could not seal private Claude GPT auth export"
  fi

  jq -cn \
    --arg profile "$name" \
    --arg account_identity "$identity" \
    --arg profile_revision "$revision" \
    --arg credential_fingerprint "$fingerprint" \
    --argjson expires "$expires_ms" \
    '{profile: $profile, account_identity: $account_identity,
      profile_revision: $profile_revision,
      credential_fingerprint: $credential_fingerprint, expires: $expires}'
)
