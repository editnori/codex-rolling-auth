# shellcheck shell=bash

PATCH_CODEX_PATCH_VERSION=1

patch_codex_root() {
  printf '%s\n' "${CODEX_AUTH_PATCH_CODEX_DIR:-$CODEX_HOME/patched-codex}"
}

patch_codex_marker_value() {
  local key="$1"
  local marker="${2:-$(patch_codex_root)/current.env}"
  local line

  [[ -f "$marker" ]] || return 1
  while IFS= read -r line; do
    [[ "$line" == "$key="* ]] && { printf '%s\n' "${line#*=}"; return 0; }
  done < "$marker"
  return 0
}

patch_codex_ready_for_key() {
  local stock_key="$1"
  local patched_bin marker_key marker_patch_version

  patched_bin="$(patch_codex_root)/bin/codex"
  [[ -x "$patched_bin" ]] || return 1
  marker_key="$(patch_codex_marker_value stock_key || true)"
  marker_patch_version="$(patch_codex_marker_value patch_version || true)"
  [[ "$marker_key" == "$stock_key" && "$marker_patch_version" == "$PATCH_CODEX_PATCH_VERSION" ]]
}

patch_codex_write_source_patch() {
  local patch_file="$1"

  cat > "$patch_file" <<'PATCH'
diff --git a/codex-rs/login/src/auth/manager.rs b/codex-rs/login/src/auth/manager.rs
index a2e4e8e..89327c2 100644
--- a/codex-rs/login/src/auth/manager.rs
+++ b/codex-rs/login/src/auth/manager.rs
@@ -14,6 +14,8 @@ use std::sync::Mutex;
 use std::sync::RwLock;
 use std::sync::atomic::AtomicU64;
 use std::sync::atomic::Ordering;
+use std::time::Duration;
+use std::time::Instant;
 use tokio::sync::Semaphore;
__PATCH_BLANK__
 use codex_agent_identity::decode_agent_identity_jwt;
@@ -95,6 +97,10 @@ const REFRESH_TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
 pub(super) const REVOKE_TOKEN_URL: &str = "https://auth.openai.com/oauth/revoke";
 pub const REFRESH_TOKEN_URL_OVERRIDE_ENV_VAR: &str = "CODEX_REFRESH_TOKEN_URL_OVERRIDE";
 pub const REVOKE_TOKEN_URL_OVERRIDE_ENV_VAR: &str = "CODEX_REVOKE_TOKEN_URL_OVERRIDE";
+const CODEX_AUTH_ROLLING_ENV_VAR: &str = "CODEX_AUTH_ROLLING";
+const CODEX_AUTH_ROLLING_INTERVAL_MS_ENV_VAR: &str = "CODEX_AUTH_ROLLING_INTERVAL_MS";
+const CODEX_AUTH_ROLLING_TTL_ENV_VAR: &str = "CODEX_AUTH_ROLLING_TTL";
+const DEFAULT_ROLLING_AUTH_INTERVAL_MS: u64 = 60_000;
 static NEXT_DUMMY_AUTH_ID: AtomicU64 = AtomicU64::new(1);
__PATCH_BLANK__
 #[derive(Debug, Error)]
@@ -1258,6 +1264,7 @@ pub struct AuthManager {
     chatgpt_base_url: Option<String>,
     refresh_lock: Semaphore,
     external_auth: RwLock<Option<Arc<dyn ExternalAuth>>>,
+    rolling_auth_last_check: Mutex<Option<Instant>>,
 }
__PATCH_BLANK__
 /// Configuration view required to construct a shared [`AuthManager`].
@@ -1332,6 +1339,7 @@ impl AuthManager {
             chatgpt_base_url,
             refresh_lock: Semaphore::new(/*permits*/ 1),
             external_auth: RwLock::new(None),
+            rolling_auth_last_check: Mutex::new(None),
         }
     }
__PATCH_BLANK__
@@ -1351,6 +1359,7 @@ impl AuthManager {
             chatgpt_base_url: None,
             refresh_lock: Semaphore::new(/*permits*/ 1),
             external_auth: RwLock::new(None),
+            rolling_auth_last_check: Mutex::new(None),
         })
     }
__PATCH_BLANK__
@@ -1369,6 +1378,7 @@ impl AuthManager {
             chatgpt_base_url: None,
             refresh_lock: Semaphore::new(/*permits*/ 1),
             external_auth: RwLock::new(None),
+            rolling_auth_last_check: Mutex::new(None),
         })
     }
__PATCH_BLANK__
@@ -1387,6 +1397,7 @@ impl AuthManager {
             external_auth: RwLock::new(Some(
                 Arc::new(BearerTokenRefresher::new(config)) as Arc<dyn ExternalAuth>
             )),
+            rolling_auth_last_check: Mutex::new(None),
         })
     }
__PATCH_BLANK__
@@ -1413,6 +1424,8 @@ impl AuthManager {
             return Some(auth);
         }
__PATCH_BLANK__
+        self.maybe_run_rolling_auth_hook().await;
+
         let auth = self.auth_cached()?;
         if Self::is_stale_for_proactive_refresh(&auth)
             && let Err(err) = self.refresh_token().await
@@ -1423,6 +1436,80 @@ impl AuthManager {
         self.auth_cached()
     }
__PATCH_BLANK__
+    fn rolling_auth_enabled() -> bool {
+        env::var(CODEX_AUTH_ROLLING_ENV_VAR)
+            .ok()
+            .map(|value| {
+                matches!(
+                    value.trim().to_ascii_lowercase().as_str(),
+                    "1" | "true" | "yes" | "on"
+                )
+            })
+            .unwrap_or(false)
+    }
+
+    fn rolling_auth_interval() -> Duration {
+        env::var(CODEX_AUTH_ROLLING_INTERVAL_MS_ENV_VAR)
+            .ok()
+            .and_then(|value| value.trim().parse::<u64>().ok())
+            .map(Duration::from_millis)
+            .unwrap_or(Duration::from_millis(DEFAULT_ROLLING_AUTH_INTERVAL_MS))
+    }
+
+    fn rolling_auth_ttl_secs() -> Option<String> {
+        env::var(CODEX_AUTH_ROLLING_TTL_ENV_VAR)
+            .ok()
+            .and_then(|value| value.trim().parse::<u64>().ok())
+            .map(|value| value.to_string())
+    }
+
+    fn should_run_rolling_auth_hook(&self) -> bool {
+        if !Self::rolling_auth_enabled() {
+            return false;
+        }
+
+        let interval = Self::rolling_auth_interval();
+        let now = Instant::now();
+        let Ok(mut last_check) = self.rolling_auth_last_check.lock() else {
+            return true;
+        };
+
+        if let Some(last) = *last_check
+            && now.duration_since(last) < interval
+        {
+            return false;
+        }
+
+        *last_check = Some(now);
+        true
+    }
+
+    async fn maybe_run_rolling_auth_hook(&self) {
+        if !self.should_run_rolling_auth_hook() {
+            return;
+        }
+
+        let mut command = tokio::process::Command::new("codex-auth");
+        command.arg("auto").arg("--quiet").arg("--no-background");
+        if let Some(ttl) = Self::rolling_auth_ttl_secs() {
+            command.arg("--ttl").arg(ttl);
+        }
+        command.env("CODEX_AUTH_NO_BACKGROUND", "1");
+        command.env("CODEX_HOME", &self.codex_home);
+
+        match command.status().await {
+            Ok(status) if status.success() => {
+                self.reload().await;
+            }
+            Ok(status) => {
+                tracing::warn!("rolling auth hook exited with status {status}");
+            }
+            Err(err) => {
+                tracing::warn!("failed to run rolling auth hook: {err}");
+            }
+        }
+    }
+
     /// Force a reload of the auth information from auth.json. Returns
     /// whether the auth value changed.
     pub async fn reload(&self) -> bool {
PATCH
  sed -i 's/^__PATCH_BLANK__$/ /' "$patch_file"
}

patch_codex_status() {
  local stock_bin="$1"
  local stock_version="$2"
  local stock_hash="$3"
  local stock_key="$4"
  local marker_key marker_version package_version source_commit state

  marker_key="$(patch_codex_marker_value stock_key || true)"
  marker_version="$(patch_codex_marker_value stock_version || true)"
  package_version="$(patch_codex_marker_value package_version || true)"
  source_commit="$(patch_codex_marker_value source_commit || true)"
  state="stale"
  patch_codex_ready_for_key "$stock_key" && state="ready"

  printf 'patched codex: %s\n' "$state"
  printf 'stock bin: %s\n' "$stock_bin"
  printf 'stock version: %s\n' "$stock_version"
  printf 'stock hash: %s\n' "$stock_hash"
  printf 'patched bin: %s/bin/codex\n' "$(patch_codex_root)"
  [[ -n "$marker_version" ]] && printf 'patched stock version: %s\n' "$marker_version"
  [[ -n "$package_version" ]] && printf 'patched package version: %s\n' "$package_version"
  [[ -n "$source_commit" ]] && printf 'source commit: %s\n' "$source_commit"
  [[ -n "$marker_key" && "$marker_key" != "$stock_key" ]] && printf 'reason: stock key changed\n'
  return 0
}

cmd_patch_codex() {
  ensure_dirs

  local background=0 quiet=0 status=0 print_bin=0 print_key=0 force=0 no_fetch=0 check_login=0
  local profile="${CODEX_AUTH_PATCH_PROFILE:-release}"
  local ref="${CODEX_AUTH_PATCH_REF:-origin/main}"
  local source_dir=""
  while (( $# > 0 )); do
    case "$1" in
      --background)
        background=1
        ;;
      --foreground)
        background=0
        ;;
      --quiet|-q)
        quiet=1
        ;;
      --status)
        status=1
        ;;
      --print-bin)
        print_bin=1
        ;;
      --print-key)
        print_key=1
        ;;
      --force)
        force=1
        ;;
      --no-fetch)
        no_fetch=1
        ;;
      --check-login)
        check_login=1
        ;;
      --debug)
        profile=debug
        ;;
      --release)
        profile=release
        ;;
      --ref)
        [[ -n "${2:-}" ]] || die "usage: codex-auth patch-codex --ref <git-ref>"
        ref="$2"
        shift
        ;;
      --source-dir)
        [[ -n "${2:-}" ]] || die "usage: codex-auth patch-codex --source-dir <dir>"
        source_dir="$2"
        shift
        ;;
      *)
        die "usage: codex-auth patch-codex [--background|--status|--force|--debug|--release]"
        ;;
    esac
    shift
  done
  [[ "$profile" == "release" || "$profile" == "debug" ]] || profile=release

  local stock_bin stock_version stock_hash stock_key hash_line checksum size
  local self log
  if [[ -n "${CODEX_AUTH_STOCK_CODEX_BIN:-}" && -x "${CODEX_AUTH_STOCK_CODEX_BIN:-}" ]]; then
    stock_bin="$CODEX_AUTH_STOCK_CODEX_BIN"
  else
    stock_bin="$(codex_bin)" || die "codex command not found"
  fi
  stock_bin="$(canonical_codex_bin "$stock_bin")"
  require_codex_launcher "$stock_bin"
  stock_version="$("$stock_bin" --version 2>/dev/null || true)"
  stock_version="${stock_version%%$'\n'*}"
  stock_version="${stock_version%"${stock_version##*[![:space:]]}"}"
  [[ -n "$stock_version" ]] || stock_version="unknown"
  if command -v sha256sum >/dev/null 2>&1 && [[ -f "$stock_bin" ]]; then
    hash_line="$(sha256sum "$stock_bin")"; stock_hash="${hash_line%% *}"
  else
    read -r checksum size _ <<<"$(printf '%s' "$stock_bin" | cksum)"; stock_hash="$checksum-$size"
  fi
  if command -v sha256sum >/dev/null 2>&1; then
    hash_line="$(printf '%s\037%s\n' "$stock_version" "$stock_hash" | sha256sum)"; stock_key="${hash_line%% *}"
  else
    read -r checksum size _ <<<"$(printf '%s\037%s\n' "$stock_version" "$stock_hash" | cksum)"; stock_key="$checksum-$size"
  fi

  if (( print_key )); then
    printf '%s\n' "$stock_key"
    return 0
  fi
  if (( print_bin )); then
    patch_codex_ready_for_key "$stock_key" || return 1
    printf '%s/bin/codex\n' "$(patch_codex_root)"
    return 0
  fi
  if (( status )); then
    patch_codex_status "$stock_bin" "$stock_version" "$stock_hash" "$stock_key"
    return 0
  fi
  if (( ! force )) && patch_codex_ready_for_key "$stock_key"; then
    [[ "$quiet" == "1" ]] || patch_codex_status "$stock_bin" "$stock_version" "$stock_hash" "$stock_key"
    return 0
  fi
  if (( background )); then
    self="$(realpath "$CODEX_AUTH_SELF" 2>/dev/null || printf '%s\n' "$CODEX_AUTH_SELF")"
    log="$(patch_codex_root)/build.log"
    mkdir -p "$(dirname "$log")" "$(patch_codex_root)/.tmp"
    nohup env CODEX_AUTH_STOCK_CODEX_BIN="$stock_bin" CODEX_AUTH_PATCH_BACKGROUND_CHILD=1 "$self" patch-codex --quiet --foreground >"$log" 2>&1 &
    [[ "$quiet" == "1" ]] || print_status_note patch "background build started"
    return 0
  fi

  command -v git >/dev/null 2>&1 || die "git is required for patch-codex"
  command -v cargo >/dev/null 2>&1 || die "cargo is required for patch-codex"

  local lock_wait lock_fd source_commit package_base package_version package_suffix repo_url clone_tmp manager_file patch_file cargo_toml built_bin target_dir target_bin tmp_bin marker tmp
  local cargo_line in_workspace_package package_version_written
  local build_args=()
  lock_wait="${CODEX_AUTH_PATCH_LOCK_WAIT:-0}"
  [[ "$lock_wait" =~ ^[0-9]+$ ]] || lock_wait=0
  exec {lock_fd}>"$(patch_codex_root)/build.lock"
  if [[ "${CODEX_AUTH_PATCH_BACKGROUND_CHILD:-}" == "1" || "$lock_wait" == "0" ]]; then
    flock -n "$lock_fd" || return 0
  else
    flock -w "$lock_wait" "$lock_fd" || die "patched Codex build already running"
  fi

  if (( ! force )) && patch_codex_ready_for_key "$stock_key"; then
    return 0
  fi

  [[ -n "$source_dir" ]] || source_dir="$(patch_codex_root)/sources/$stock_key/source"
  package_base="${stock_version##* }"
  if [[ ! "$package_base" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$ ]]; then
    package_base="0.0.0"
  fi
  package_suffix="${CODEX_AUTH_PATCH_VERSION_SUFFIX:-local}"
  if [[ -z "$package_suffix" || "$package_suffix" == "0" ]]; then
    package_version="$package_base"
  elif [[ "$package_base" == *+* ]]; then
    package_version="$package_base.$package_suffix"
  else
    package_version="$package_base+$package_suffix"
  fi

  [[ "$quiet" == "1" ]] || print_status_note patch "source $ref"
  repo_url="${CODEX_AUTH_PATCH_REPO_URL:-https://github.com/openai/codex.git}"
  if [[ -d "$source_dir/.git" ]] \
    && ! git -C "$source_dir" rev-parse --verify HEAD >/dev/null 2>&1 \
    && [[ ! -f "$source_dir/codex-rs/login/src/auth/manager.rs" ]]; then
    rm -rf "$source_dir"
  fi
  if [[ ! -d "$source_dir/.git" ]]; then
    if [[ -e "$source_dir" ]]; then
      die "source exists but is not a git repo: $source_dir"
    fi
    mkdir -p "$(dirname "$source_dir")"
    clone_tmp="$(mktemp -d "$(dirname "$source_dir")/.clone.XXXXXX")"
    git clone "$repo_url" "$clone_tmp"
    mv "$clone_tmp" "$source_dir"
  fi
  if [[ ! -f "$source_dir/codex-rs/login/src/auth/manager.rs" ]] \
    || ! grep -Fq 'CODEX_AUTH_ROLLING_ENV_VAR' "$source_dir/codex-rs/login/src/auth/manager.rs"; then
    if [[ "$no_fetch" != "1" ]]; then
      git -C "$source_dir" fetch origin
    fi
    git -C "$source_dir" checkout --detach "$ref"
  fi
  source_commit="$(git -C "$source_dir" rev-parse HEAD)"
  manager_file="$source_dir/codex-rs/login/src/auth/manager.rs"
  [[ -f "$manager_file" ]] || die "missing $manager_file"
  if ! grep -Fq 'CODEX_AUTH_ROLLING_ENV_VAR' "$manager_file"; then
    patch_file="$(mktemp "$(patch_codex_root)/.tmp/codex-source.XXXXXX.patch")"
    patch_codex_write_source_patch "$patch_file"
    git -C "$source_dir" apply "$patch_file"
    rm -f "$patch_file"
  fi
  cargo_toml="$source_dir/codex-rs/Cargo.toml"
  [[ -f "$cargo_toml" ]] || die "missing $cargo_toml"
  tmp="$(mktemp "$(patch_codex_root)/.tmp/Cargo.toml.XXXXXX")"
  in_workspace_package=0
  package_version_written=0
  while IFS= read -r cargo_line || [[ -n "$cargo_line" ]]; do
    if [[ "$cargo_line" == "[workspace.package]" ]]; then
      in_workspace_package=1
    elif [[ "$cargo_line" == "["* ]]; then
      in_workspace_package=0
    fi
    if (( in_workspace_package && ! package_version_written )) && [[ "$cargo_line" == 'version = "'* ]]; then
      printf 'version = "%s"\n' "$package_version"
      package_version_written=1
      continue
    fi
    printf '%s\n' "$cargo_line"
  done < "$cargo_toml" > "$tmp"
  if (( ! package_version_written )); then
    rm -f "$tmp"
    die "could not set Codex package version"
  fi
  mv "$tmp" "$cargo_toml"

  [[ "$quiet" == "1" ]] || print_status_note patch "build $profile"
  [[ "$profile" == "release" ]] && build_args=(--release)
  if [[ "$check_login" == "1" ]]; then
    (cd "$source_dir/codex-rs" && cargo check -p codex-login)
  fi
  (cd "$source_dir/codex-rs" && cargo build -p codex-cli --bin codex "${build_args[@]}")
  target_dir="${CARGO_TARGET_DIR:-$source_dir/codex-rs/target}"
  if [[ "$profile" == "release" ]]; then
    built_bin="$target_dir/release/codex"
  else
    built_bin="$target_dir/debug/codex"
  fi
  [[ -x "$built_bin" ]] || die "build did not produce $built_bin"
  target_bin="$(patch_codex_root)/bin/codex"
  mkdir -p "$(dirname "$target_bin")"
  tmp_bin="$(mktemp "$(patch_codex_root)/.tmp/codex.XXXXXX")"
  install -m 0755 "$built_bin" "$tmp_bin"
  "$tmp_bin" --version >/dev/null 2>&1 || die "patched codex smoke failed"
  mv "$tmp_bin" "$target_bin"

  marker="$(patch_codex_root)/current.env"
  tmp="$(mktemp "$(patch_codex_root)/.tmp/current.env.XXXXXX")"
  {
    printf 'patch_version=%s\n' "$PATCH_CODEX_PATCH_VERSION"
    printf 'stock_key=%s\n' "$stock_key"
    printf 'stock_version=%s\n' "$stock_version"
    printf 'stock_hash=%s\n' "$stock_hash"
    printf 'source_commit=%s\n' "$source_commit"
    printf 'package_version=%s\n' "$package_version"
    printf 'profile=%s\n' "$profile"
    printf 'built_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } > "$tmp"
  mv "$tmp" "$marker"

  [[ "$quiet" == "1" ]] || patch_codex_status "$stock_bin" "$stock_version" "$stock_hash" "$stock_key"
}

