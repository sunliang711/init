#!/usr/bin/env bash
set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

DEFAULT_VAULT_VERSION="2.0.0"
VAULT_USER="vault"
VAULT_GROUP="vault"
BIN_PATH="/usr/local/bin/vault"
CONFIG_DIR="/etc/vault.d"
CONFIG_FILE="${CONFIG_DIR}/config.hcl"
DATA_DIR="/opt/vault/data"
STATE_DIR="/opt/vault"
INIT_DIR="${STATE_DIR}/init"
SYSTEMD_SERVICE="/etc/systemd/system/vault.service"
TOOL_DIR="/usr/local/lib/vault-init-tools"
TOOL_STATE_DIR="/var/lib/vault-init-tools"
TOOL_LOG_DIR="/var/log/vault-init-tools"
TOOL_ENTRY="/usr/local/sbin/vault-manager"
TOOL_VERSION_FILE="${TOOL_DIR}/VERSION"
TOOL_MANIFEST_FILE="${TOOL_DIR}/MANIFEST.sha256"
INSTALL_METADATA_FILE="${TOOL_STATE_DIR}/install.json"
AUDIT_LOG_FILE="${TOOL_LOG_DIR}/manager.audit.log"
STATE_POINTER_FILE="${STATE_DIR}/.managed-by-vault-init-tools"
RELEASE_INDEX_URL="https://releases.hashicorp.com/vault/"
MANAGED_MARKER="# Managed by tools/vault/manager.sh"
LEGACY_MANAGED_MARKER="# Managed by vault.sh"
DEFAULT_VAULT_ADDR="http://127.0.0.1:8200"
TMPDIR_TO_CLEAN=""
AUDIT_ACTIVE=0
AUDIT_FINALIZED=0
AUDIT_ERROR=""
AUDIT_DISABLE_AFTER_PURGE=0
AUDIT_ARGS=()

VC_ADDR="$DEFAULT_VAULT_ADDR"
VC_CACERT=""
VC_NAMESPACE=""
VC_TOKEN_FILE=""

cleanup() {
  if [ -n "${TMPDIR_TO_CLEAN:-}" ] && [ -d "$TMPDIR_TO_CLEAN" ]; then
    rm -rf "$TMPDIR_TO_CLEAN"
  fi
}

log_info() {
  printf '[INFO] %s\n' "$*" >&2
}

log_warn() {
  printf '[WARN] %s\n' "$*" >&2
}

log_error() {
  printf '[ERROR] %s\n' "$*" >&2
}

fatal() {
  log_error "$*"
  AUDIT_ERROR="$*"
  audit_failure_from_fatal
  exit 1
}

json_escape() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '%s' "$value"
}

json_string() {
  printf '"%s"' "$(json_escape "$1")"
}

is_sensitive_option() {
  case "$1" in
    --token | --token-file | --key-file | --keys-file | --tls-key-file | --password | --client-secret)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

redacted_args_json() {
  local first=1
  local redact_next=0
  local arg
  local item

  printf '['
  for arg in "$@"; do
    if [ "$redact_next" -eq 1 ]; then
      item="<redacted>"
      redact_next=0
    else
      case "$arg" in
        --token=* | --token-file=* | --key-file=* | --keys-file=* | --tls-key-file=* | --password=* | --client-secret=*)
          item="${arg%%=*}=<redacted>"
          ;;
        *)
          item="$arg"
          if is_sensitive_option "$arg"; then
            redact_next=1
          fi
          ;;
      esac
    fi

    if [ "$first" -eq 0 ]; then
      printf ','
    fi
    json_string "$item"
    first=0
  done
  printf ']'
}

redacted_command_line() {
  local arg
  local item
  local output=""
  local redact_next=0

  for arg in "$@"; do
    if [ "$redact_next" -eq 1 ]; then
      item="<redacted>"
      redact_next=0
    else
      case "$arg" in
        --token=* | --token-file=* | --key-file=* | --keys-file=* | --tls-key-file=* | --password=* | --client-secret=*)
          item="${arg%%=*}=<redacted>"
          ;;
        *)
          item="$arg"
          if is_sensitive_option "$arg"; then
            redact_next=1
          fi
          ;;
      esac
    fi

    if [ -n "$output" ]; then
      output="${output} ${item}"
    else
      output="$item"
    fi
  done

  printf '%s\n' "${output:-help}"
}

append_audit_line() {
  local line="$1"

  if [ "$AUDIT_DISABLE_AFTER_PURGE" -eq 1 ]; then
    return 0
  fi

  if [ "$(id -u)" -eq 0 ]; then
    install -d -m 0750 -o root -g root "$TOOL_LOG_DIR" 2>/dev/null || return 0
    if [ ! -e "$AUDIT_LOG_FILE" ]; then
      install -m 0640 -o root -g root /dev/null "$AUDIT_LOG_FILE" 2>/dev/null || return 0
    fi
    printf '%s\n' "$line" >>"$AUDIT_LOG_FILE" 2>/dev/null || true
  elif command_exists sudo && sudo -n true 2>/dev/null; then
    sudo -n install -d -m 0750 -o root -g root "$TOOL_LOG_DIR" 2>/dev/null || return 0
    if ! sudo -n test -e "$AUDIT_LOG_FILE" 2>/dev/null; then
      sudo -n install -m 0640 -o root -g root /dev/null "$AUDIT_LOG_FILE" 2>/dev/null || return 0
    fi
    printf '%s\n' "$line" | sudo -n tee -a "$AUDIT_LOG_FILE" >/dev/null 2>&1 || true
  fi
}

audit_record() {
  local result="$1"
  local exit_code="$2"
  shift 2
  local now
  local user_name
  local host_name
  local cwd
  local script_path
  local command_line
  local args_json
  local error_json="null"

  now="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  user_name="$(id -un 2>/dev/null || printf 'unknown')"
  host_name="$(hostname 2>/dev/null || printf 'unknown')"
  cwd="$(pwd 2>/dev/null || printf 'unknown')"
  script_path="$(current_script_path 2>/dev/null || printf '%s' "$0")"
  command_line="$(redacted_command_line "$@")"
  args_json="$(redacted_args_json "$@")"
  if [ -n "$AUDIT_ERROR" ]; then
    error_json="$(json_string "$AUDIT_ERROR")"
  fi

  append_audit_line "$(printf '{"time":%s,"tool":"vault-manager","result":%s,"exit_code":%s,"user":%s,"sudo_user":%s,"host":%s,"cwd":%s,"script":%s,"tool_dir":%s,"command":%s,"args":%s,"error":%s}' \
    "$(json_string "$now")" \
    "$(json_string "$result")" \
    "$exit_code" \
    "$(json_string "$user_name")" \
    "$(json_string "${SUDO_USER:-}")" \
    "$(json_string "$host_name")" \
    "$(json_string "$cwd")" \
    "$(json_string "$script_path")" \
    "$(json_string "$TOOL_DIR")" \
    "$(json_string "$command_line")" \
    "$args_json" \
    "$error_json")"
}

audit_failure_from_fatal() {
  if [ "${AUDIT_ACTIVE:-0}" -eq 1 ] && [ "${AUDIT_FINALIZED:-0}" -eq 0 ]; then
    audit_record "failed" 1 "${AUDIT_ARGS[@]}"
    AUDIT_FINALIZED=1
  fi
}

usage() {
  cat <<EOF
Vault manager

Usage:
  $(basename "$0") install [--version VERSION|VERSION] [options]
  $(basename "$0") uninstall [--purge-data] [--remove-tools|--purge]
  $(basename "$0") status [vault options]
  $(basename "$0") doctor [vault options]
  $(basename "$0") init [--key-shares N --key-threshold N --out FILE] [--force] [vault options]
  $(basename "$0") unseal --keys-file FILE [vault options]
  $(basename "$0") auth list [vault options]
  $(basename "$0") auth enable TYPE [--path PATH] [vault options]
  $(basename "$0") auth disable PATH [vault options]
  $(basename "$0") auth read PATH [vault options]
  $(basename "$0") auth write PATH KEY=VALUE... [vault options]
  $(basename "$0") policy list [vault options]
  $(basename "$0") policy read NAME [vault options]
  $(basename "$0") policy write NAME FILE [vault options]
  $(basename "$0") policy delete NAME [vault options]
  $(basename "$0") tutor [topic]
  $(basename "$0") help

Command groups:
  Lifecycle:
    install, uninstall, status, doctor
  Cluster bootstrap:
    init, unseal
  Vault administration:
    auth, policy
  Scenario tutorials:
    tutor

Install options:
  --version VERSION          Vault version, default resolves latest then falls back to ${DEFAULT_VAULT_VERSION}
  --listen-address ADDR      Listener address, default: 0.0.0.0:8200
  --cluster-address ADDR     Listener cluster address, default: 0.0.0.0:8201
  --api-addr URL             Vault api_addr, default: ${DEFAULT_VAULT_ADDR}
  --cluster-addr URL         Vault cluster_addr, default: http://127.0.0.1:8201
  --tls-disable true|false   Disable listener TLS, default: true
  --tls-cert-file FILE       Listener TLS certificate file
  --tls-key-file FILE        Listener TLS key file

Uninstall options:
  --purge-data              Also remove ${STATE_DIR}, including raft data and init output.
  --remove-tools            Also remove ${TOOL_ENTRY} and ${TOOL_DIR}.
  --purge                   Remove runtime, Vault state, installed tools, metadata and audit logs.

Vault options:
  --addr URL                 Vault address, default: ${DEFAULT_VAULT_ADDR}
  --ca-cert FILE             Vault CA certificate file
  --namespace NAME           Vault Enterprise namespace
  --token-file FILE          Read token from plain text or init JSON file

Common workflows:
  $(basename "$0") install
  $(basename "$0") install --version 2.0.0
  $(basename "$0") install --api-addr http://10.2.37.64:8200 --cluster-addr http://10.2.37.64:8201
  http_proxy=http://10.2.1.107:7190 https_proxy=http://10.2.1.107:7190 $(basename "$0") install

  $(basename "$0") init --key-shares 1 --key-threshold 1 --out /opt/vault/init/vault-init.json
  $(basename "$0") unseal --keys-file /opt/vault/init/vault-init.json
  $(basename "$0") status --token-file /opt/vault/init/vault-init.json
  $(basename "$0") doctor --addr http://127.0.0.1:8200

  $(basename "$0") auth enable userpass --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth enable jwt --path jwt-nomad --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth write jwt-nomad/config jwks_url=http://127.0.0.1:4646/.well-known/jwks.json --token-file /opt/vault/init/vault-init.json
  $(basename "$0") policy write app-read ./policy.hcl --token-file /opt/vault/init/vault-init.json
  $(basename "$0") policy read app-read --token-file /opt/vault/init/vault-init.json

Installed tool snapshot:
  ${TOOL_DIR}
  ${TOOL_ENTRY} -> ${TOOL_DIR}/manager.sh
  ${INSTALL_METADATA_FILE}
  ${AUDIT_LOG_FILE}

Token handling:
  Commands can use VAULT_TOKEN from the environment, or --token-file.
  --token-file accepts either a plain token file or the JSON written by init.
  Tokens and unseal keys are never printed by this manager except through Vault CLI output.

Init and unseal:
  init refuses to run when Vault is already initialized.
  init refuses to overwrite the output file unless --force is provided.
  unseal reads all unseal keys from the JSON file and stops once Vault becomes unsealed.

Safety:
  install manages ${CONFIG_FILE} only when it is absent or starts with:
    ${MANAGED_MARKER}
  install configures single-node raft storage under ${DATA_DIR}.
  install copies this Vault manager to ${TOOL_DIR} so future management can use
  the script version that was installed with this node.
  uninstall removes service, binary and ${CONFIG_DIR}.
  uninstall preserves ${STATE_DIR}, installed tools, metadata and audit logs by default.
  uninstall --remove-tools removes installed tools but preserves metadata and audit logs.
  uninstall --purge removes Vault state, installed tools, metadata and audit logs.
  init output contains unseal keys and root token and is written with mode 0600.
  Every manager execution writes an audit record to:
    ${AUDIT_LOG_FILE}
  Token, key and password-like arguments are redacted in audit logs.

More help:
  $(basename "$0") tutor
  $(basename "$0") auth --help
  $(basename "$0") policy --help
EOF
}

tutor_usage() {
  local topic="${1:-overview}"

  case "$topic" in
    overview | help | -h | --help)
      cat <<EOF
Vault manager tutor

Usage:
  $(basename "$0") tutor [topic]

Topics:
  install        Install a single-node Vault server.
  init           Initialize, unseal and use token files.
  auth           Manage auth methods.
  policy         Manage policies.
  nomad-jwt      Prepare Vault JWT Auth for Nomad workload identity.
  uninstall      Choose the right uninstall level.
  troubleshoot   Common diagnostics.

Example:
  $(basename "$0") tutor install
  $(basename "$0") tutor nomad-jwt
EOF
      ;;
    install)
      cat <<EOF
Scenario: install Vault single node

1. Install latest Vault:
   $(basename "$0") install

2. Install through an HTTP proxy:
   http_proxy=http://10.2.1.107:7190 https_proxy=http://10.2.1.107:7190 $(basename "$0") install

3. Install with an address reachable by other nodes:
   $(basename "$0") install --api-addr http://10.2.37.64:8200 --cluster-addr http://10.2.37.64:8201

4. Check service and metadata:
   systemctl status vault
   $(basename "$0") status
   cat ${INSTALL_METADATA_FILE}

Notes:
  The install command configures single-node raft storage under ${DATA_DIR}.
  Future management can use ${TOOL_ENTRY}, which points to the installed script snapshot.
EOF
      ;;
    init)
      cat <<EOF
Scenario: initialize and unseal Vault

1. Initialize Vault and save the init JSON:
   $(basename "$0") init --key-shares 1 --key-threshold 1 --out ${INIT_DIR}/vault-init.json

2. Unseal Vault from the init JSON:
   $(basename "$0") unseal --keys-file ${INIT_DIR}/vault-init.json

3. Use the init JSON as a token file:
   $(basename "$0") status --token-file ${INIT_DIR}/vault-init.json

4. Check health:
   $(basename "$0") doctor --addr ${DEFAULT_VAULT_ADDR}

Safety:
  The init JSON contains unseal keys and the root token.
  Keep it readable only by trusted administrators.
EOF
      ;;
    auth)
      cat <<EOF
Scenario: manage Vault auth methods

1. List enabled auth methods:
   $(basename "$0") auth list --token-file ${INIT_DIR}/vault-init.json

2. Enable userpass auth:
   $(basename "$0") auth enable userpass --token-file ${INIT_DIR}/vault-init.json

3. Enable JWT auth at a custom path:
   $(basename "$0") auth enable jwt --path jwt-nomad --description "Nomad workload identity" --token-file ${INIT_DIR}/vault-init.json

4. Write an auth config:
   $(basename "$0") auth write jwt-nomad/config jwks_url=http://127.0.0.1:4646/.well-known/jwks.json default_role=nomad-workloads --token-file ${INIT_DIR}/vault-init.json

5. Disable an auth method:
   $(basename "$0") auth disable userpass --token-file ${INIT_DIR}/vault-init.json
EOF
      ;;
    policy)
      cat <<EOF
Scenario: manage Vault policies

1. Create a policy file:
   cat > app-read.hcl <<'HCL'
   path "kv/data/app/*" {
     capabilities = ["read"]
   }

   path "kv/metadata/app/*" {
     capabilities = ["read", "list"]
   }
HCL

2. Write the policy:
   $(basename "$0") policy write app-read ./app-read.hcl --token-file ${INIT_DIR}/vault-init.json

3. Read the policy:
   $(basename "$0") policy read app-read --token-file ${INIT_DIR}/vault-init.json

4. Delete the policy:
   $(basename "$0") policy delete app-read --token-file ${INIT_DIR}/vault-init.json
EOF
      ;;
    nomad-jwt)
      cat <<EOF
Scenario: prepare Vault for Nomad workload identity

Recommended path:
  Use nomad-manager vault-jwt apply because it configures both Nomad and Vault in one linked workflow.

1. Initialize and unseal Vault first:
   $(basename "$0") tutor init

2. Export a Vault token or use --token-file:
   export VAULT_TOKEN=<redacted>

3. Run the linked Nomad workflow:
   nomad-manager vault-jwt plan --profile default --vault-addr ${DEFAULT_VAULT_ADDR} --nomad-addr http://10.2.37.64:4646
   nomad-manager vault-jwt apply --profile default --vault-addr ${DEFAULT_VAULT_ADDR} --nomad-addr http://10.2.37.64:4646 --secret-path kv/data/app

4. Check Vault pieces manually when needed:
   $(basename "$0") auth read jwt-nomad/config --token-file ${INIT_DIR}/vault-init.json
   $(basename "$0") policy read nomad-workloads --token-file ${INIT_DIR}/vault-init.json
   VAULT_ADDR=${DEFAULT_VAULT_ADDR} vault read auth/jwt-nomad/role/nomad-workloads
EOF
      ;;
    uninstall)
      cat <<EOF
Scenario: uninstall Vault safely

1. Remove service, binary and config. Keep Vault state, tools, metadata and audit logs:
   $(basename "$0") uninstall

2. Also remove Vault state under ${STATE_DIR}:
   $(basename "$0") uninstall --purge-data

3. Remove runtime and installed management scripts. Keep metadata and audit logs:
   $(basename "$0") uninstall --remove-tools

4. Remove runtime, Vault state, tools, metadata and audit logs:
   $(basename "$0") uninstall --purge

Notes:
  Default uninstall keeps ${STATE_DIR} because it can contain raft data and init output.
EOF
      ;;
    troubleshoot)
      cat <<EOF
Scenario: Vault troubleshooting

1. Check service logs:
   systemctl status vault
   journalctl -u vault -n 100 --no-pager

2. Check Vault status and health:
   $(basename "$0") status
   $(basename "$0") doctor --addr ${DEFAULT_VAULT_ADDR}
   curl --noproxy '*' ${DEFAULT_VAULT_ADDR}/v1/sys/health

3. Check seal state and unseal when needed:
   $(basename "$0") status
   $(basename "$0") unseal --keys-file ${INIT_DIR}/vault-init.json

4. Check auth and policy state:
   $(basename "$0") auth list --token-file ${INIT_DIR}/vault-init.json
   $(basename "$0") policy list --token-file ${INIT_DIR}/vault-init.json

5. Check management metadata and audit history:
   cat ${INSTALL_METADATA_FILE}
   tail -n 50 ${AUDIT_LOG_FILE}
EOF
      ;;
    *)
      return 1
      ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

require_command() {
  if ! command_exists "$1"; then
    fatal "Required command not found: $1"
  fi
}

require_any_checksum_command() {
  if ! command_exists sha256sum && ! command_exists shasum; then
    fatal "Required command not found: sha256sum or shasum"
  fi
}

require_zip_extractor() {
  if ! command_exists unzip && ! command_exists python3; then
    fatal "Required command not found: unzip or python3"
  fi
}

require_linux() {
  if [ "$(uname -s)" != "Linux" ]; then
    fatal "This script only supports Linux"
  fi
}

run_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
  elif command_exists sudo; then
    sudo "$@"
  else
    fatal "Root privilege is required. Please install sudo or run as root"
  fi
}

detect_arch() {
  case "$(uname -m)" in
    x86_64 | amd64)
      printf 'amd64\n'
      ;;
    aarch64 | arm64)
      printf 'arm64\n'
      ;;
    i386 | i686)
      printf '386\n'
      ;;
    *)
      fatal "Unsupported architecture: $(uname -m)"
      ;;
  esac
}

normalize_version() {
  local version="$1"

  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    fatal "Invalid Vault version: $1"
  fi

  printf '%s\n' "$version"
}

curl_stdout() {
  local url="$1"

  curl --fail --location --show-error --silent --connect-timeout 10 --max-time 60 "$url"
}

curl_download() {
  local url="$1"
  local output="$2"

  curl --fail --location --show-error --silent --retry 3 --connect-timeout 10 --max-time 300 --output "$output" "$url"
}

fetch_latest_version() {
  local latest

  latest="$(
    curl_stdout "$RELEASE_INDEX_URL" |
      sed -n 's#.*href="/vault/\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\)/".*#\1#p' |
      head -n 1
  )"

  if [ -z "$latest" ]; then
    return 1
  fi

  normalize_version "$latest"
}

resolve_version() {
  local requested="$1"
  local latest

  if [ -n "$requested" ] && [ "$requested" != "latest" ]; then
    normalize_version "$requested"
    return
  fi

  if latest="$(fetch_latest_version)"; then
    log_info "Resolved latest Vault version: ${latest}" >&2
    printf '%s\n' "$latest"
    return
  fi

  log_warn "Failed to resolve latest Vault version, fallback to ${DEFAULT_VAULT_VERSION}"
  printf '%s\n' "$DEFAULT_VAULT_VERSION"
}

checksum_file() {
  local file="$1"

  if command_exists sha256sum; then
    sha256sum "$file" | awk '{print $1}'
  else
    shasum -a 256 "$file" | awk '{print $1}'
  fi
}

verify_checksum() {
  local zip_file="$1"
  local sums_file="$2"
  local zip_name
  local expected
  local actual

  zip_name="$(basename "$zip_file")"
  expected="$(awk -v file="$zip_name" '$2 == file {print $1; exit}' "$sums_file")"
  if [ -z "$expected" ]; then
    fatal "Checksum entry not found for ${zip_name}"
  fi

  actual="$(checksum_file "$zip_file")"
  if [ "$expected" != "$actual" ]; then
    fatal "Checksum mismatch for ${zip_name}"
  fi

  log_info "Checksum verified: ${zip_name}"
}

extract_zip() {
  local zip_file="$1"
  local output_dir="$2"

  if command_exists unzip; then
    unzip -q "$zip_file" -d "$output_dir"
    return
  fi

  python3 -m zipfile -e "$zip_file" "$output_dir"
}

hcl_string() {
  local value="$1"

  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  printf '"%s"' "$value"
}

validate_bool() {
  local value="$1"

  case "$value" in
    true | false)
      printf '%s\n' "$value"
      ;;
    *)
      fatal "Invalid boolean value: ${value}"
      ;;
  esac
}

is_managed_file() {
  local path="$1"
  local first_line

  [ -f "$path" ] || return 1
  first_line="$(sed -n '1p' "$path")"
  [ "$first_line" = "$MANAGED_MARKER" ] || [ "$first_line" = "$LEGACY_MANAGED_MARKER" ]
}

ensure_managed_or_absent() {
  local path="$1"

  if [ -e "$path" ] && ! is_managed_file "$path"; then
    fatal "Refuse to manage non-managed file: ${path}"
  fi
}

safe_remove_path() {
  local path="$1"

  case "$path" in
    "" | "/" | "/usr" | "/usr/local" | "/usr/local/bin" | "/etc" | "/opt")
      fatal "Refuse to remove unsafe path: ${path}"
      ;;
  esac

  if [ -e "$path" ] || [ -L "$path" ]; then
    run_root rm -rf -- "$path"
  fi
}

current_script_path() {
  local source="${BASH_SOURCE[0]}"
  local dir

  while [ -L "$source" ]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    case "$source" in
      /*)
        ;;
      *)
        source="${dir}/${source}"
        ;;
    esac
  done

  dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$source")"
}

write_tool_manifest() {
  local tmpdir="$1"
  local manifest_file="${tmpdir}/MANIFEST.sha256"
  local path
  local name

  : >"$manifest_file"
  for name in manager.sh VERSION; do
    path="${TOOL_DIR}/${name}"
    if [ -f "$path" ]; then
      printf '%s  %s\n' "$(checksum_file "$path")" "$name" >>"$manifest_file"
    fi
  done

  run_root install -m 0644 -o root -g root "$manifest_file" "$TOOL_MANIFEST_FILE"
}

write_install_metadata() {
  local version="$1"
  local tmpdir="$2"
  local metadata_file="${tmpdir}/install.json"
  local installed_at
  local manifest_sha=""

  installed_at="$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
  if [ -f "$TOOL_MANIFEST_FILE" ]; then
    manifest_sha="$(checksum_file "$TOOL_MANIFEST_FILE")"
  fi

  {
    printf '{\n'
    printf '  "tool": "vault-manager",\n'
    printf '  "tool_dir": %s,\n' "$(json_string "$TOOL_DIR")"
    printf '  "manager_entry": %s,\n' "$(json_string "$TOOL_ENTRY")"
    printf '  "vault_binary": %s,\n' "$(json_string "$BIN_PATH")"
    printf '  "config_file": %s,\n' "$(json_string "$CONFIG_FILE")"
    printf '  "data_dir": %s,\n' "$(json_string "$DATA_DIR")"
    printf '  "state_dir": %s,\n' "$(json_string "$STATE_DIR")"
    printf '  "service": %s,\n' "$(json_string "$SYSTEMD_SERVICE")"
    printf '  "vault_version": %s,\n' "$(json_string "$version")"
    printf '  "installed_at": %s,\n' "$(json_string "$installed_at")"
    printf '  "manifest_file": %s,\n' "$(json_string "$TOOL_MANIFEST_FILE")"
    printf '  "manifest_sha256": %s,\n' "$(json_string "$manifest_sha")"
    printf '  "audit_log": %s\n' "$(json_string "$AUDIT_LOG_FILE")"
    printf '}\n'
  } >"$metadata_file"

  run_root install -d -m 0750 -o root -g root "$TOOL_STATE_DIR"
  run_root install -m 0644 -o root -g root "$metadata_file" "$INSTALL_METADATA_FILE"
}

write_state_pointer() {
  local tmpdir="$1"
  local pointer_file="${tmpdir}/managed-by-vault-init-tools"

  {
    printf 'Managed by vault-manager\n'
    printf 'Install metadata: %s\n' "$INSTALL_METADATA_FILE"
    printf 'Tool dir: %s\n' "$TOOL_DIR"
    printf 'Config file: %s\n' "$CONFIG_FILE"
    printf 'Audit log: %s\n' "$AUDIT_LOG_FILE"
  } >"$pointer_file"

  run_root install -m 0644 -o root -g root "$pointer_file" "$STATE_POINTER_FILE"
}

install_tool_snapshot() {
  local version="$1"
  local tmpdir="$2"
  local manager_src
  local snapshot_dir="${tmpdir}/tool-snapshot"
  local version_file="${snapshot_dir}/VERSION"

  manager_src="$(current_script_path)"

  log_info "Installing Vault init tools snapshot: ${TOOL_DIR}"
  install -d -m 0755 "$snapshot_dir"
  install -m 0755 "$manager_src" "${snapshot_dir}/manager.sh"

  {
    printf 'tool=vault-manager\n'
    printf 'vault_version=%s\n' "$version"
    printf 'installed_at=%s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date)"
    printf 'source=%s\n' "$manager_src"
  } >"$version_file"

  run_root install -d -m 0755 -o root -g root "$TOOL_DIR"
  run_root install -m 0755 -o root -g root "${snapshot_dir}/manager.sh" "${TOOL_DIR}/manager.sh"
  run_root install -m 0644 -o root -g root "$version_file" "$TOOL_VERSION_FILE"

  write_tool_manifest "$tmpdir"
  write_install_metadata "$version" "$tmpdir"
  write_state_pointer "$tmpdir"

  run_root install -d -m 0755 -o root -g root "$(dirname "$TOOL_ENTRY")"
  run_root ln -sfn "${TOOL_DIR}/manager.sh" "$TOOL_ENTRY"

  log_info "Vault manager entry installed: ${TOOL_ENTRY}"
  log_info "Vault install metadata written: ${INSTALL_METADATA_FILE}"
}

remove_tool_snapshot() {
  log_info "Removing Vault init tools"
  safe_remove_path "$TOOL_ENTRY"
  safe_remove_path "$TOOL_DIR"
}

purge_tool_state() {
  log_warn "Purging Vault init tool metadata and audit logs"
  safe_remove_path "$TOOL_STATE_DIR"
  safe_remove_path "$TOOL_LOG_DIR"
  AUDIT_DISABLE_AFTER_PURGE=1
}

ensure_vault_user() {
  local shell_path="/usr/sbin/nologin"

  if ! getent group "$VAULT_GROUP" >/dev/null 2>&1; then
    log_info "Creating system group: ${VAULT_GROUP}"
    run_root groupadd --system "$VAULT_GROUP"
  fi

  if id "$VAULT_USER" >/dev/null 2>&1; then
    return
  fi

  if [ ! -x "$shell_path" ]; then
    shell_path="/bin/false"
  fi

  log_info "Creating system user: ${VAULT_USER}"
  run_root useradd --system --gid "$VAULT_GROUP" --home "$STATE_DIR" --shell "$shell_path" "$VAULT_USER"
}

install_directories() {
  log_info "Creating Vault directories"
  run_root install -d -m 0755 -o root -g root "$CONFIG_DIR"
  run_root install -d -m 0750 -o "$VAULT_USER" -g "$VAULT_GROUP" "$STATE_DIR"
  run_root install -d -m 0750 -o "$VAULT_USER" -g "$VAULT_GROUP" "$DATA_DIR"
  run_root install -d -m 0700 -o root -g root "$INIT_DIR"
}

download_vault() {
  local version="$1"
  local arch="$2"
  local tmpdir="$3"
  local zip_name="vault_${version}_linux_${arch}.zip"
  local sums_name="vault_${version}_SHA256SUMS"
  local base_url="https://releases.hashicorp.com/vault/${version}"
  local zip_file="${tmpdir}/${zip_name}"
  local sums_file="${tmpdir}/${sums_name}"

  log_info "Downloading Vault ${version} for linux_${arch}"
  curl_download "${base_url}/${zip_name}" "$zip_file"
  curl_download "${base_url}/${sums_name}" "$sums_file"
  verify_checksum "$zip_file" "$sums_file"

  extract_zip "$zip_file" "${tmpdir}/extract"
  if [ ! -f "${tmpdir}/extract/vault" ]; then
    fatal "Vault binary not found in archive"
  fi
}

install_binary() {
  local tmpdir="$1"

  log_info "Installing binary: ${BIN_PATH}"
  run_root install -m 0755 -o root -g root "${tmpdir}/extract/vault" "$BIN_PATH"
  "$BIN_PATH" version
}

write_vault_config() {
  local tmpdir="$1"
  local listen_address="$2"
  local cluster_address="$3"
  local api_addr="$4"
  local cluster_addr="$5"
  local tls_disable="$6"
  local tls_cert_file="$7"
  local tls_key_file="$8"
  local config_file="${tmpdir}/config.hcl"
  local node_id

  ensure_managed_or_absent "$CONFIG_FILE"
  node_id="vault-$(hostname | tr -cd 'A-Za-z0-9_.-' | cut -c 1-48)"
  [ -n "$node_id" ] || node_id="vault-node"

  if [ "$tls_disable" = "false" ]; then
    [ -n "$tls_cert_file" ] || fatal "install requires --tls-cert-file when --tls-disable false"
    [ -n "$tls_key_file" ] || fatal "install requires --tls-key-file when --tls-disable false"
  fi

  {
    printf '%s\n' "$MANAGED_MARKER"
    printf 'ui = true\n'
    printf 'disable_mlock = true\n'
    printf 'api_addr = %s\n' "$(hcl_string "$api_addr")"
    printf 'cluster_addr = %s\n' "$(hcl_string "$cluster_addr")"
    printf '\n'
    printf 'storage "raft" {\n'
    printf '  path    = %s\n' "$(hcl_string "$DATA_DIR")"
    printf '  node_id = %s\n' "$(hcl_string "$node_id")"
    printf '}\n'
    printf '\n'
    printf 'listener "tcp" {\n'
    printf '  address         = %s\n' "$(hcl_string "$listen_address")"
    printf '  cluster_address = %s\n' "$(hcl_string "$cluster_address")"
    printf '  tls_disable     = %s\n' "$tls_disable"
    [ -z "$tls_cert_file" ] || printf '  tls_cert_file   = %s\n' "$(hcl_string "$tls_cert_file")"
    [ -z "$tls_key_file" ] || printf '  tls_key_file    = %s\n' "$(hcl_string "$tls_key_file")"
    printf '}\n'
  } >"$config_file"

  log_info "Installing Vault config: ${CONFIG_FILE}"
  run_root install -m 0640 -o root -g "$VAULT_GROUP" "$config_file" "$CONFIG_FILE"
}

write_systemd_service() {
  local tmpdir="$1"
  local service_file="${tmpdir}/vault.service"

  cat >"$service_file" <<EOF
[Unit]
Description=Vault
Documentation=https://developer.hashicorp.com/vault/docs
Wants=network-online.target
After=network-online.target

[Service]
User=${VAULT_USER}
Group=${VAULT_GROUP}
ExecReload=/bin/kill -HUP \$MAINPID
ExecStart=${BIN_PATH} server -config=${CONFIG_FILE}
KillSignal=SIGINT
LimitNOFILE=65536
Restart=on-failure
RestartSec=2
TimeoutStopSec=30
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=full
ProtectHome=read-only
ReadWritePaths=${STATE_DIR}

[Install]
WantedBy=multi-user.target
EOF

  log_info "Installing systemd service: ${SYSTEMD_SERVICE}"
  run_root install -m 0644 -o root -g root "$service_file" "$SYSTEMD_SERVICE"
}

wait_for_vault_api() {
  local address="$1"
  local url="${address%/}/v1/sys/health"
  local attempt=1
  local code

  require_command curl
  log_info "Waiting for Vault HTTP API"
  while [ "$attempt" -le 60 ]; do
    code="$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 3 "$url" 2>/dev/null || true)"
    case "$code" in
      200 | 429 | 472 | 473 | 501 | 503)
        return
        ;;
    esac

    if command_exists systemctl && ! run_root systemctl is-active --quiet vault; then
      log_error "Vault service is not active"
      if command_exists journalctl; then
        run_root journalctl -u vault -n 80 --no-pager || true
      fi
      exit 1
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  if command_exists journalctl; then
    run_root journalctl -u vault -n 80 --no-pager || true
  fi
  fatal "Timed out waiting for Vault HTTP API: ${url}"
}

install_vault() {
  local requested_version=""
  local version
  local arch
  local tmpdir
  local listen_address="0.0.0.0:8200"
  local cluster_address="0.0.0.0:8201"
  local api_addr="$DEFAULT_VAULT_ADDR"
  local cluster_addr="http://127.0.0.1:8201"
  local tls_disable="true"
  local tls_cert_file=""
  local tls_key_file=""

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --version)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --version"
        requested_version="$1"
        ;;
      --listen-address)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --listen-address"
        listen_address="$1"
        ;;
      --cluster-address)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --cluster-address"
        cluster_address="$1"
        ;;
      --api-addr)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --api-addr"
        api_addr="$1"
        ;;
      --cluster-addr)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --cluster-addr"
        cluster_addr="$1"
        ;;
      --tls-disable)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --tls-disable"
        tls_disable="$(validate_bool "$1")"
        ;;
      --tls-cert-file)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --tls-cert-file"
        tls_cert_file="$1"
        ;;
      --tls-key-file)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --tls-key-file"
        tls_key_file="$1"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      -*)
        fatal "Unknown install option: $1"
        ;;
      *)
        if [ -n "$requested_version" ]; then
          fatal "Unexpected argument: $1"
        fi
        requested_version="$1"
        ;;
    esac
    shift
  done

  require_linux
  require_command curl
  require_command awk
  require_command sed
  require_command head
  require_command mktemp
  require_command install
  require_command readlink
  require_command systemctl
  require_command useradd
  require_command groupadd
  require_any_checksum_command
  require_zip_extractor

  version="$(resolve_version "$requested_version")"
  arch="$(detect_arch)"
  TMPDIR_TO_CLEAN="$(mktemp -d)"
  tmpdir="$TMPDIR_TO_CLEAN"
  trap cleanup EXIT

  download_vault "$version" "$arch" "$tmpdir"
  install_binary "$tmpdir"
  ensure_vault_user
  install_directories
  write_vault_config "$tmpdir" "$listen_address" "$cluster_address" "$api_addr" "$cluster_addr" "$tls_disable" "$tls_cert_file" "$tls_key_file"
  write_systemd_service "$tmpdir"
  install_tool_snapshot "$version" "$tmpdir"

  log_info "Enabling Vault service"
  run_root systemctl daemon-reload
  run_root systemctl enable vault
  run_root systemctl restart vault
  wait_for_vault_api "$api_addr"

  log_info "Vault installation completed"
}

uninstall_vault() {
  local purge_data=0
  local remove_tools=0
  local purge=0

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --purge-data)
        purge_data=1
        ;;
      --remove-tools)
        remove_tools=1
        ;;
      --purge)
        purge_data=1
        remove_tools=1
        purge=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        fatal "Unknown uninstall option: $1"
        ;;
    esac
    shift
  done

  require_linux
  require_command systemctl
  require_command getent

  log_info "Stopping Vault service"
  run_root systemctl stop vault 2>/dev/null || true
  run_root systemctl disable vault 2>/dev/null || true

  log_info "Removing Vault service, binary and config"
  safe_remove_path "$SYSTEMD_SERVICE"
  safe_remove_path "$BIN_PATH"
  safe_remove_path "$CONFIG_DIR"

  if [ "$purge_data" -eq 1 ]; then
    log_warn "Purging Vault state directory: ${STATE_DIR}"
    safe_remove_path "$STATE_DIR"
    if id "$VAULT_USER" >/dev/null 2>&1; then
      log_info "Removing system user: ${VAULT_USER}"
      run_root userdel "$VAULT_USER" || log_warn "Failed to remove user: ${VAULT_USER}"
    fi
    if getent group "$VAULT_GROUP" >/dev/null 2>&1; then
      log_info "Removing system group: ${VAULT_GROUP}"
      run_root groupdel "$VAULT_GROUP" || log_warn "Failed to remove group: ${VAULT_GROUP}"
    fi
  else
    log_warn "Vault state preserved: ${STATE_DIR}. Use --purge-data to remove it"
  fi

  if [ "$remove_tools" -eq 1 ]; then
    remove_tool_snapshot
  else
    log_warn "Vault init tools preserved: ${TOOL_DIR}. Use --remove-tools to remove them"
  fi

  if [ "$purge" -eq 1 ]; then
    purge_tool_state
  else
    log_warn "Vault init tool metadata preserved: ${TOOL_STATE_DIR}"
    log_warn "Vault init tool audit logs preserved: ${TOOL_LOG_DIR}"
  fi

  run_root systemctl daemon-reload
  run_root systemctl reset-failed vault 2>/dev/null || true
  log_info "Vault uninstallation completed"
}

reset_vault_cli_opts() {
  VC_ADDR="${VAULT_ADDR:-$DEFAULT_VAULT_ADDR}"
  VC_CACERT="${VAULT_CACERT:-}"
  VC_NAMESPACE="${VAULT_NAMESPACE:-}"
  VC_TOKEN_FILE=""
}

read_vault_token_file() {
  local path="$1"

  [ -f "$path" ] || fatal "Token file not found: ${path}"
  require_command python3
  python3 - "$path" <<'PY'
import json
import sys

path = sys.argv[1]
raw = open(path, "r", encoding="utf-8").read().strip()
try:
    data = json.loads(raw)
except json.JSONDecodeError:
    print(raw.splitlines()[0] if raw else "")
    raise SystemExit

for key in ("root_token", "initial_root_token", "token"):
    value = data.get(key)
    if value:
        print(value)
        raise SystemExit
print("")
PY
}

vault_cli() {
  local token=""
  local -a env_vars

  [ -x "$BIN_PATH" ] || fatal "Vault binary not found: ${BIN_PATH}. Please run install first"
  if [ -n "$VC_TOKEN_FILE" ]; then
    token="$(read_vault_token_file "$VC_TOKEN_FILE")"
    [ -n "$token" ] || fatal "Token file does not contain a token: ${VC_TOKEN_FILE}"
  fi

  env_vars=("VAULT_ADDR=${VC_ADDR}")
  [ -z "$VC_CACERT" ] || env_vars+=("VAULT_CACERT=${VC_CACERT}")
  [ -z "$VC_NAMESPACE" ] || env_vars+=("VAULT_NAMESPACE=${VC_NAMESPACE}")
  [ -z "$token" ] || env_vars+=("VAULT_TOKEN=${token}")
  env "${env_vars[@]}" "$BIN_PATH" "$@"
}

parse_common_vault_option() {
  case "$1" in
    --addr)
      printf 'addr\n'
      ;;
    --ca-cert)
      printf 'ca-cert\n'
      ;;
    --namespace)
      printf 'namespace\n'
      ;;
    --token-file)
      printf 'token-file\n'
      ;;
    *)
      return 1
      ;;
  esac
}

set_common_vault_option() {
  local name="$1"
  local value="$2"

  case "$name" in
    addr)
      VC_ADDR="$value"
      ;;
    ca-cert)
      VC_CACERT="$value"
      ;;
    namespace)
      VC_NAMESPACE="$value"
      ;;
    token-file)
      VC_TOKEN_FILE="$value"
      ;;
  esac
}

vault_status_json() {
  vault_cli status -format=json 2>/dev/null || true
}

vault_status_field() {
  local field="$1"
  local json

  json="$(vault_status_json)"
  [ -n "$json" ] || return 1
  python3 - "$field" "$json" <<'PY'
import json
import sys

data = json.loads(sys.argv[2])
value = data.get(sys.argv[1])
if isinstance(value, bool):
    print("true" if value else "false")
elif value is not None:
    print(value)
PY
}

status_vault() {
  local opt

  reset_vault_cli_opts
  while [ "$#" -gt 0 ]; do
    if opt="$(parse_common_vault_option "$1")"; then
      shift
      [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
      set_common_vault_option "$opt" "$1"
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      usage
      exit 0
    else
      fatal "Unknown status option: $1"
    fi
    shift
  done

  vault_cli status
}

doctor_check_print() {
  local status="$1"
  local message="$2"

  printf '%-5s %s\n' "$status" "$message"
}

doctor_vault() {
  local failures=0
  local code
  local url
  local opt

  reset_vault_cli_opts
  while [ "$#" -gt 0 ]; do
    if opt="$(parse_common_vault_option "$1")"; then
      shift
      [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
      set_common_vault_option "$opt" "$1"
    elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
      usage
      exit 0
    else
      fatal "Unknown doctor option: $1"
    fi
    shift
  done

  if [ -x "$BIN_PATH" ]; then
    doctor_check_print "OK" "Vault binary found: ${BIN_PATH}"
  else
    doctor_check_print "FAIL" "Vault binary missing: ${BIN_PATH}"
    failures=$((failures + 1))
  fi

  if [ -f "$CONFIG_FILE" ]; then
    if is_managed_file "$CONFIG_FILE"; then
      doctor_check_print "OK" "Vault config managed: ${CONFIG_FILE}"
    else
      doctor_check_print "WARN" "Vault config exists but is not managed: ${CONFIG_FILE}"
    fi
  else
    doctor_check_print "WARN" "Vault config missing: ${CONFIG_FILE}"
  fi

  if command_exists systemctl && systemctl is-active --quiet vault; then
    doctor_check_print "OK" "vault.service is active"
  else
    doctor_check_print "WARN" "vault.service is not active"
  fi

  if command_exists curl; then
    url="${VC_ADDR%/}/v1/sys/health"
    code="$(curl --noproxy '*' --silent --output /dev/null --write-out '%{http_code}' --max-time 5 "$url" 2>/dev/null || true)"
    case "$code" in
      200 | 429 | 472 | 473)
        doctor_check_print "OK" "Vault health endpoint reachable: ${url} (${code})"
        ;;
      501 | 503)
        doctor_check_print "WARN" "Vault health endpoint reachable but not ready: ${url} (${code})"
        ;;
      *)
        doctor_check_print "FAIL" "Vault health endpoint not reachable: ${url} (${code:-curl failed})"
        failures=$((failures + 1))
        ;;
    esac
  else
    doctor_check_print "FAIL" "curl command not found"
    failures=$((failures + 1))
  fi

  return "$failures"
}

init_vault() {
  local key_shares=5
  local key_threshold=3
  local out="${INIT_DIR}/vault-init.json"
  local force=0
  local initialized
  local opt
  local tmp

  reset_vault_cli_opts
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --key-shares)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --key-shares"
        key_shares="$1"
        ;;
      --key-threshold)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --key-threshold"
        key_threshold="$1"
        ;;
      --out)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --out"
        out="$1"
        ;;
      --force)
        force=1
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        if opt="$(parse_common_vault_option "$1")"; then
          shift
          [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
          set_common_vault_option "$opt" "$1"
        else
          fatal "Unknown init option: $1"
        fi
        ;;
    esac
    shift
  done

  initialized="$(vault_status_field initialized || true)"
  if [ "$initialized" = "true" ]; then
    fatal "Vault is already initialized"
  fi

  if [ -e "$out" ] && [ "$force" -ne 1 ]; then
    fatal "Output exists, use --force to overwrite: ${out}"
  fi

  tmp="$(mktemp)"
  umask 077
  vault_cli operator init -format=json -key-shares="$key_shares" -key-threshold="$key_threshold" >"$tmp"

  run_root install -d -m 0700 "$(dirname "$out")"
  run_root install -m 0600 "$tmp" "$out"
  rm -f "$tmp"
  log_info "Vault init output saved: ${out}"
}

unseal_keys_from_file() {
  local path="$1"

  [ -f "$path" ] || fatal "Keys file not found: ${path}"
  require_command python3
  python3 - "$path" <<'PY'
import json
import sys

data = json.load(open(sys.argv[1], "r", encoding="utf-8"))
keys = data.get("unseal_keys_b64") or data.get("unseal_keys_hex") or []
for key in keys:
    print(key)
PY
}

unseal_vault() {
  local keys_file=""
  local sealed
  local opt
  local key

  reset_vault_cli_opts
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --keys-file)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --keys-file"
        keys_file="$1"
        ;;
      -h | --help)
        usage
        exit 0
        ;;
      *)
        if opt="$(parse_common_vault_option "$1")"; then
          shift
          [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
          set_common_vault_option "$opt" "$1"
        else
          fatal "Unknown unseal option: $1"
        fi
        ;;
    esac
    shift
  done

  [ -n "$keys_file" ] || fatal "unseal requires --keys-file"
  sealed="$(vault_status_field sealed || true)"
  if [ "$sealed" = "false" ]; then
    log_info "Vault is already unsealed"
    return
  fi

  while IFS= read -r key; do
    [ -n "$key" ] || continue
    vault_cli operator unseal "$key" >/dev/null
    sealed="$(vault_status_field sealed || true)"
    if [ "$sealed" = "false" ]; then
      log_info "Vault unsealed"
      return
    fi
  done < <(unseal_keys_from_file "$keys_file")

  fatal "Vault is still sealed after applying keys"
}

auth_usage() {
  cat <<EOF
Vault auth method management

Usage:
  $(basename "$0") auth list [vault options]
  $(basename "$0") auth enable TYPE [--path PATH] [--description TEXT] [--default-lease-ttl DURATION] [--max-lease-ttl DURATION] [vault options]
  $(basename "$0") auth disable PATH [vault options]
  $(basename "$0") auth read PATH [vault options]
  $(basename "$0") auth write PATH KEY=VALUE... [vault options]

Auth commands:
  list                    Show enabled auth methods.
  enable TYPE             Enable auth method TYPE at --path, default path is TYPE.
  disable PATH            Disable auth method at PATH.
  read PATH               Read auth/<PATH>.
  write PATH KEY=VALUE    Write KEY=VALUE pairs to auth/<PATH>.

Options for enable:
  --path PATH                 Mount path, default: TYPE
  --description TEXT          Auth method description
  --default-lease-ttl DURATION
  --max-lease-ttl DURATION

Vault options:
  --addr URL                  Vault address, default: ${DEFAULT_VAULT_ADDR}
  --ca-cert FILE              Vault CA certificate file
  --namespace NAME            Vault Enterprise namespace
  --token-file FILE           Read token from plain text or init JSON file

Behavior:
  enable is idempotent when PATH already exists with the same TYPE.
  enable fails when PATH already exists with a different TYPE.
  disable is idempotent when PATH is already absent.
  read/write map directly to vault read/write under auth/<PATH>.

Examples:
  $(basename "$0") auth list --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth enable userpass --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth enable jwt --path jwt-nomad --description "Nomad workload identity" --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth write jwt-nomad/config jwks_url=http://127.0.0.1:4646/.well-known/jwks.json default_role=nomad-workloads --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth read jwt-nomad/config --token-file /opt/vault/init/vault-init.json
  $(basename "$0") auth disable userpass --token-file /opt/vault/init/vault-init.json
EOF
}

policy_usage() {
  cat <<EOF
Vault policy management

Usage:
  $(basename "$0") policy list [vault options]
  $(basename "$0") policy read NAME [vault options]
  $(basename "$0") policy write NAME FILE [vault options]
  $(basename "$0") policy delete NAME [vault options]

Policy commands:
  list              Show policy names.
  read NAME         Print policy HCL.
  write NAME FILE   Create or update policy NAME from FILE.
  delete NAME       Delete policy NAME.

Vault options:
  --addr URL        Vault address, default: ${DEFAULT_VAULT_ADDR}
  --ca-cert FILE    Vault CA certificate file
  --namespace NAME  Vault Enterprise namespace
  --token-file FILE Read token from plain text or init JSON file

Policy file example:
  path "kv/data/app/*" {
    capabilities = ["read"]
  }

  path "kv/metadata/app/*" {
    capabilities = ["read", "list"]
  }

Behavior:
  write is idempotent for the same policy content.
  delete maps to "vault policy delete" and fails if Vault rejects the operation.
  The manager checks that FILE exists before writing a policy.

Examples:
  $(basename "$0") policy list --token-file /opt/vault/init/vault-init.json
  $(basename "$0") policy write app-read ./policy.hcl --token-file /opt/vault/init/vault-init.json
  $(basename "$0") policy read app-read --token-file /opt/vault/init/vault-init.json
  $(basename "$0") policy delete app-read --token-file /opt/vault/init/vault-init.json
EOF
}

auth_type_at_path() {
  local path="$1"
  local json

  json="$(vault_cli auth list -format=json 2>/dev/null)" || return 2
  python3 - "$path" "$json" <<'PY'
import json
import sys

path = sys.argv[1].strip("/")
if path:
    path = path + "/"
data = json.loads(sys.argv[2])
print(data.get(path, {}).get("type", ""))
PY
}

auth_list() {
  vault_cli auth list
}

auth_enable() {
  local type="${1:-}"
  local path=""
  local description=""
  local default_ttl=""
  local max_ttl=""
  local existing_type
  local opt
  local -a args

  [ -n "$type" ] || fatal "auth enable requires TYPE"
  shift || true
  path="$type"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --path)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --path"
        path="$1"
        ;;
      --description)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --description"
        description="$1"
        ;;
      --default-lease-ttl)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --default-lease-ttl"
        default_ttl="$1"
        ;;
      --max-lease-ttl)
        shift
        [ "$#" -gt 0 ] || fatal "Missing value for --max-lease-ttl"
        max_ttl="$1"
        ;;
      *)
        if opt="$(parse_common_vault_option "$1")"; then
          shift
          [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
          set_common_vault_option "$opt" "$1"
        else
          fatal "Unknown auth enable option: $1"
        fi
        ;;
    esac
    shift
  done

  existing_type="$(auth_type_at_path "$path" || true)"
  if [ -n "$existing_type" ]; then
    if [ "$existing_type" = "$type" ]; then
      log_info "Auth method already enabled: ${path} (${type})"
      return
    fi
    fatal "Auth path ${path} already exists with type ${existing_type}"
  fi

  args=("auth" "enable" "-path=${path}")
  [ -z "$description" ] || args+=("-description=${description}")
  [ -z "$default_ttl" ] || args+=("-default-lease-ttl=${default_ttl}")
  [ -z "$max_ttl" ] || args+=("-max-lease-ttl=${max_ttl}")
  args+=("$type")
  vault_cli "${args[@]}"
}

auth_disable() {
  local path="${1:-}"
  local existing_type

  [ -n "$path" ] || fatal "auth disable requires PATH"
  shift || true
  parse_trailing_vault_options "$@" || fatal "auth disable accepts only vault options after PATH"

  existing_type="$(auth_type_at_path "$path" || true)"
  if [ -z "$existing_type" ]; then
    log_info "Auth method already absent: ${path}"
    return
  fi

  vault_cli auth disable "$path"
}

auth_read() {
  local path="${1:-}"

  [ -n "$path" ] || fatal "auth read requires PATH"
  shift || true
  parse_trailing_vault_options "$@" || fatal "auth read accepts only vault options after PATH"
  vault_cli read "auth/${path}"
}

auth_write() {
  local path="${1:-}"

  [ -n "$path" ] || fatal "auth write requires PATH"
  shift || true
  parse_key_values_and_vault_options "$@"
  [ "${#KV_ARGS[@]}" -gt 0 ] || fatal "auth write requires KEY=VALUE arguments"
  vault_cli write "auth/${path}" "${KV_ARGS[@]}"
}

parse_trailing_vault_options() {
  local opt

  while [ "$#" -gt 0 ]; do
    if opt="$(parse_common_vault_option "$1")"; then
      shift
      [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
      set_common_vault_option "$opt" "$1"
    else
      return 1
    fi
    shift
  done
}

KV_ARGS=()
parse_key_values_and_vault_options() {
  local opt

  KV_ARGS=()
  while [ "$#" -gt 0 ]; do
    if opt="$(parse_common_vault_option "$1")"; then
      shift
      [ "$#" -gt 0 ] || fatal "Missing value for --${opt}"
      set_common_vault_option "$opt" "$1"
    else
      KV_ARGS+=("$1")
    fi
    shift
  done
}

dispatch_auth() {
  local command="${1:-help}"

  reset_vault_cli_opts
  [ "$#" -eq 0 ] || shift
  case "$command" in
    list)
      parse_trailing_vault_options "$@" || fatal "auth list accepts only vault options"
      auth_list
      ;;
    enable)
      auth_enable "$@"
      ;;
    disable)
      auth_disable "$@"
      ;;
    read)
      auth_read "$@"
      ;;
    write)
      auth_write "$@"
      ;;
    help | -h | --help)
      auth_usage
      ;;
    *)
      auth_usage >&2
      fatal "Unknown auth command: ${command}"
      ;;
  esac
}

policy_list() {
  parse_trailing_vault_options "$@" || fatal "policy list accepts only vault options"
  vault_cli policy list
}

policy_read() {
  local name="${1:-}"

  [ -n "$name" ] || fatal "policy read requires NAME"
  shift || true
  parse_trailing_vault_options "$@" || fatal "policy read accepts only vault options after NAME"
  vault_cli policy read "$name"
}

policy_write() {
  local name="${1:-}"
  local file="${2:-}"

  [ -n "$name" ] || fatal "policy write requires NAME"
  [ -n "$file" ] || fatal "policy write requires FILE"
  [ -f "$file" ] || fatal "Policy file not found: ${file}"
  shift 2 || true
  parse_trailing_vault_options "$@" || fatal "policy write accepts only vault options after FILE"
  vault_cli policy write "$name" "$file"
}

policy_delete() {
  local name="${1:-}"

  [ -n "$name" ] || fatal "policy delete requires NAME"
  shift || true
  parse_trailing_vault_options "$@" || fatal "policy delete accepts only vault options after NAME"
  vault_cli policy delete "$name"
}

dispatch_policy() {
  local command="${1:-help}"

  reset_vault_cli_opts
  [ "$#" -eq 0 ] || shift
  case "$command" in
    list)
      policy_list "$@"
      ;;
    read)
      policy_read "$@"
      ;;
    write)
      policy_write "$@"
      ;;
    delete)
      policy_delete "$@"
      ;;
    help | -h | --help)
      policy_usage
      ;;
    *)
      policy_usage >&2
      fatal "Unknown policy command: ${command}"
      ;;
  esac
}

dispatch_tutor() {
  local topic="${1:-overview}"

  [ "$#" -le 1 ] || fatal "tutor accepts at most one topic"
  if ! tutor_usage "$topic"; then
    tutor_usage >&2
    fatal "Unknown tutor topic: ${topic}"
  fi
}

main() {
  local command="${1:-help}"

  if [ "$#" -gt 0 ]; then
    shift
  fi

  case "$command" in
    install)
      install_vault "$@"
      ;;
    uninstall)
      uninstall_vault "$@"
      ;;
    status)
      status_vault "$@"
      ;;
    doctor)
      doctor_vault "$@"
      ;;
    init)
      init_vault "$@"
      ;;
    unseal)
      unseal_vault "$@"
      ;;
    auth)
      dispatch_auth "$@"
      ;;
    policy)
      dispatch_policy "$@"
      ;;
    tutor)
      dispatch_tutor "$@"
      ;;
    help | -h | --help)
      usage
      ;;
    *)
      usage >&2
      fatal "Unknown command: ${command}"
      ;;
  esac
}

run_with_audit() {
  local exit_code=0
  local command_line

  AUDIT_ACTIVE=1
  AUDIT_FINALIZED=0
  AUDIT_ERROR=""
  AUDIT_ARGS=("$@")
  command_line="$(redacted_command_line "$@")"
  log_info "Starting vault-manager command: ${command_line}"
  audit_record "started" 0 "$@"

  set -E
  trap 'exit_code=$?; if [ "${AUDIT_FINALIZED:-0}" -eq 0 ]; then log_error "Failed vault-manager command (${exit_code}): ${command_line}"; audit_record "failed" "$exit_code" "${AUDIT_ARGS[@]}"; AUDIT_FINALIZED=1; fi; exit "$exit_code"' ERR
  main "$@"
  trap - ERR

  log_info "Completed vault-manager command: ${command_line}"
  audit_record "success" 0 "$@"
  AUDIT_FINALIZED=1
  return 0
}

run_with_audit "$@"
