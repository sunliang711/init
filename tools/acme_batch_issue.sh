#!/usr/bin/env bash

set -euo pipefail

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

ACME_HOME="/root/.acme.sh"
CERT_DIR="/etc/certs"
DEFAULT_RELOAD_CMD="/usr/local/bin/acme_reload_hook.sh"
EMAIL=""
CHALLENGE=""
DNS_PROVIDER=""
HTTP_MODE="standalone"
WEBROOT=""
KEY_LENGTH="ec-256"
RELOAD_CMD="${DEFAULT_RELOAD_CMD}"
INSTALL_ONLY=0
APT_UPDATED=0

declare -a CERT_SPECS=()

log() {
    echo ">> $*" >&2
}

die() {
    log "$*"
    exit 1
}

usage() {
    cat <<'EOF'
用法:
  acme_batch_issue.sh --email admin@example.com --challenge dns01 --dns-provider dns_cf \
    -d example.com,www.example.com -d api.example.com

  acme_batch_issue.sh --email admin@example.com --challenge http01 --http-mode standalone \
    -d example.com -d api.example.com,ws.api.example.com

  acme_batch_issue.sh --email admin@example.com --challenge http01 --http-mode webroot \
    --webroot /var/www/acme-challenge -d example.com,www.example.com

参数:
  --email <email>
      acme.sh 账户邮箱，安装 acme.sh 时使用，必填。

  --challenge <dns01|http01>
      指定签发验证方式，必填。
      dns01  通过 DNS TXT 记录验证。
      http01 通过 80 端口下的 HTTP 文件验证。

  --dns-provider <provider>
      dns01 模式必填，对应 acme.sh 的 DNS provider 名称。
      例如: dns_cf、dns_dp、dns_ali。
      具体凭据需提前通过环境变量导出，脚本本身不保存凭据。

  --http-mode <standalone|webroot>
      仅 http01 模式使用，默认 standalone。
      standalone  由 acme.sh 自己临时监听 80 端口完成验证。
      webroot     将验证文件写入指定目录，由现有 Nginx/Apache 对外提供。

  --webroot <path>
      仅当 --http-mode webroot 时必填。
      例如: /var/www/acme-challenge

  --cert-dir <path>
      证书安装目录，默认 /etc/certs。
      每张证书输出为:
        <主域名>.cer
        <主域名>.key
        <主域名>.pem

  --acme-home <path>
      acme.sh 安装目录，默认 /root/.acme.sh。

  --key-length <value>
      acme.sh 的密钥类型，默认 ec-256。
      常见值: ec-256、ec-384、2048、4096。

  --reloadcmd <command>
      可选。证书安装或后续自动续期成功后执行的 reload 命令。
      默认值: /usr/local/bin/acme_reload_hook.sh
      例如: --reloadcmd /root/reload_nomad_nginx.sh

  -d, --domain <domains>
      一次传入一张证书的域名列表，可重复传递以批量签发多张证书。
      多个域名之间使用英文逗号分隔，第一个域名视为主域名。
      示例:
        -d example.com
        -d example.com,www.example.com
        -d api.example.com,ws.api.example.com

  --install-only
      只安装 acme.sh，不执行签发。

  -h, --help
      显示本帮助信息并退出。

细节说明:
  1. 每个 -d/--domain 代表一张证书申请，可重复多次。
  2. 第一个域名为主域名，证书文件名也按该主域名生成。
  3. dns01 适合无法开放 80 端口，或希望使用通配符证书的场景。
  4. http01 standalone 要求 80 端口未被其他服务占用。
  5. http01 webroot 要求现有 Web 服务已正确暴露 /.well-known/acme-challenge/。
  6. 如果未提供 --reloadcmd，默认使用 /usr/local/bin/acme_reload_hook.sh。
  7. 默认 reload hook 不存在时，脚本会自动创建一个仅包含 shebang 和 exit 0 的占位文件。
  8. 脚本需要 root 权限，并默认面向 Linux + apt-get 环境。

常见 DNS Provider 环境变量:
  dns_cf (Cloudflare)
    推荐方式:
      export CF_Token="你的_api_token"
      export CF_Account_ID="你的_account_id"
    兼容旧方式:
      export CF_Key="你的_global_api_key"
      export CF_Email="你的_cloudflare_email"

  dns_ali (阿里云 DNS)
      export Ali_Key="你的_access_key_id"
      export Ali_Secret="你的_access_key_secret"

  dns_tencent (腾讯云 DNSPod)
      export Tencent_SecretId="你的_secret_id"
      export Tencent_SecretKey="你的_secret_key"

  说明:
    1. 以上环境变量需要在执行脚本前先 export。
    2. 脚本在 dns01 模式下会校验以上常见 Provider 的必填环境变量。
    3. 如果使用 sudo，建议先切到 root 后再 export 并执行脚本。
    4. 其他 DNS Provider 的变量名请查看 acme.sh 对应 dnsapi 脚本或官方文档。

示例:
  # dns01: 一次签发两张证书
  acme_batch_issue.sh \
    --email admin@example.com \
    --challenge dns01 \
    --dns-provider dns_cf \
    -d example.com,www.example.com \
    -d api.example.com

  # http01 standalone: 80 端口未被占用时使用
  acme_batch_issue.sh \
    --email admin@example.com \
    --challenge http01 \
    --http-mode standalone \
    -d example.com \
    -d api.example.com,ws.api.example.com

  # http01 webroot: 复用现有 Web 服务
  acme_batch_issue.sh \
    --email admin@example.com \
    --challenge http01 \
    --http-mode webroot \
    --webroot /var/www/acme-challenge \
    --reloadcmd /root/reload_nomad_nginx.sh \
    -d example.com,www.example.com
EOF
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

env_var_is_set() {
    local var_name="${1:?missing env var name}"
    [ -n "${!var_name:-}" ]
}

require_dns_provider_env_vars() {
    local missing_vars=()
    local env_var=""

    case "${DNS_PROVIDER}" in
        dns_cf)
            if env_var_is_set "CF_Token" || env_var_is_set "CF_Account_ID"; then
                if ! env_var_is_set "CF_Token"; then
                    missing_vars+=("CF_Token")
                fi
                if ! env_var_is_set "CF_Account_ID"; then
                    missing_vars+=("CF_Account_ID")
                fi
            elif env_var_is_set "CF_Key" || env_var_is_set "CF_Email"; then
                if ! env_var_is_set "CF_Key"; then
                    missing_vars+=("CF_Key")
                fi
                if ! env_var_is_set "CF_Email"; then
                    missing_vars+=("CF_Email")
                fi
            else
                missing_vars+=("CF_Token" "CF_Account_ID")
            fi
            ;;
        dns_ali)
            for env_var in Ali_Key Ali_Secret; do
                if ! env_var_is_set "${env_var}"; then
                    missing_vars+=("${env_var}")
                fi
            done
            ;;
        dns_tencent)
            for env_var in Tencent_SecretId Tencent_SecretKey; do
                if ! env_var_is_set "${env_var}"; then
                    missing_vars+=("${env_var}")
                fi
            done
            ;;
        *)
            log "skip dns provider env check for ${DNS_PROVIDER}, please ensure required variables are exported"
            return 0
            ;;
    esac

    if [ "${#missing_vars[@]}" -gt 0 ]; then
        die "missing required env vars for ${DNS_PROVIDER}: ${missing_vars[*]}"
    fi
}

require_root() {
    if [ "${EUID}" -ne 0 ]; then
        die "this script must be run as root"
    fi
}

require_linux() {
    if [ "$(uname -s)" != "Linux" ]; then
        die "this script only supports Linux"
    fi
}

update_apt_once() {
    if [ "${APT_UPDATED}" -eq 1 ]; then
        return 0
    fi

    if ! command_exists apt-get; then
        die "apt-get is required to install missing dependencies"
    fi

    log "updating apt index"
    apt-get update >/dev/null
    APT_UPDATED=1
}

install_package() {
    local cmd="${1:?missing command}"
    local pkg="${2:-$1}"

    if command_exists "${cmd}"; then
        return 0
    fi

    update_apt_once
    log "installing package ${pkg}"
    DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkg}" >/dev/null
}

validate_domain_label() {
    local domain="${1:?missing domain}"

    if [[ ! "${domain}" =~ ^[A-Za-z0-9._*-]+$ ]]; then
        die "invalid domain: ${domain}"
    fi
}

normalize_cert_spec() {
    local spec="${1:?missing spec}"
    local cleaned="${spec// /}"

    if [ -z "${cleaned}" ]; then
        die "empty domain spec is not allowed"
    fi

    if [[ "${cleaned}" == *, || "${cleaned}" == ,* || "${cleaned}" == *,,* ]]; then
        die "invalid domain spec: ${spec}"
    fi

    echo "${cleaned}"
}

acme_bin() {
    echo "${ACME_HOME}/acme.sh"
}

acme_cert_dir_name() {
    local primary_domain="${1:?missing primary domain}"

    case "${KEY_LENGTH}" in
        ec-*|ecc)
            echo "${primary_domain}_ecc"
            ;;
        *)
            echo "${primary_domain}"
            ;;
    esac
}

ensure_default_reload_hook() {
    if [ "${RELOAD_CMD}" != "${DEFAULT_RELOAD_CMD}" ]; then
        return 0
    fi

    if [ -e "${DEFAULT_RELOAD_CMD}" ]; then
        return 0
    fi

    log "creating default reload hook at ${DEFAULT_RELOAD_CMD}"
    mkdir -p "$(dirname "${DEFAULT_RELOAD_CMD}")"
    cat > "${DEFAULT_RELOAD_CMD}" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "${DEFAULT_RELOAD_CMD}"
}

install_acme() {
    local email="${1:?email is required}"
    local tmp_dir=""
    local installer=""

    install_package curl curl
    install_package jq jq

    if [ "${CHALLENGE}" = "http01" ] && [ "${HTTP_MODE}" = "standalone" ]; then
        install_package socat socat
    fi

    if [ -x "$(acme_bin)" ]; then
        log "acme.sh already installed, skip"
        return 0
    fi

    tmp_dir="$(mktemp -d)"
    installer="${tmp_dir}/acme-install.sh"
    trap 'rm -rf "${tmp_dir}"' RETURN

    log "downloading acme.sh installer"
    curl -fsSL https://get.acme.sh -o "${installer}"

    log "installing acme.sh"
    sh "${installer}" email="${email}" >/dev/null

    if [ ! -x "$(acme_bin)" ]; then
        die "acme.sh install failed"
    fi

    log "acme.sh install success"
}

build_issue_args() {
    local cert_spec="${1:?missing cert spec}"
    local -a domains=()
    local domain=""
    local issue_args=()

    IFS=',' read -r -a domains <<< "${cert_spec}"

    for domain in "${domains[@]}"; do
        validate_domain_label "${domain}"
        issue_args+=("-d" "${domain}")
    done

    case "${CHALLENGE}" in
        dns01)
            issue_args+=("--dns" "${DNS_PROVIDER}")
            ;;
        http01)
            if [ "${HTTP_MODE}" = "webroot" ]; then
                issue_args+=("-w" "${WEBROOT}")
            else
                issue_args+=("--standalone")
            fi
            ;;
        *)
            die "unsupported challenge: ${CHALLENGE}"
            ;;
    esac

    issue_args+=("--keylength" "${KEY_LENGTH}")
    printf '%s\n' "${issue_args[@]}"
}

issue_cert() {
    local cert_spec="${1:?missing cert spec}"
    local -a domains=()
    local primary_domain=""
    local acme_domain_dir=""
    local cert_name=""
    local cert_file=""
    local key_file=""
    local fullchain_file=""
    local -a issue_args=()
    local -a install_args=()

    IFS=',' read -r -a domains <<< "${cert_spec}"
    primary_domain="${domains[0]}"
    cert_name="${primary_domain}"
    acme_domain_dir="$(acme_cert_dir_name "${primary_domain}")"

    if [ -e "${ACME_HOME}/${acme_domain_dir}/${primary_domain}.cer" ]; then
        log "cert already exists for ${primary_domain}, skip issue and refresh install config"
    else
        while IFS= read -r line; do
            issue_args+=("${line}")
        done < <(build_issue_args "${cert_spec}")

        log "issuing cert for ${cert_spec}"
        "$(acme_bin)" --issue "${issue_args[@]}"

        if [ ! -e "${ACME_HOME}/${acme_domain_dir}/${primary_domain}.cer" ]; then
            die "issue cert failed for ${primary_domain}"
        fi
    fi

    mkdir -p "${CERT_DIR}"
    cert_file="${CERT_DIR}/${cert_name}.cer"
    key_file="${CERT_DIR}/${cert_name}.key"
    fullchain_file="${CERT_DIR}/${cert_name}.pem"
    install_args=(
        "--install-cert"
        "-d" "${primary_domain}"
        "--keylength" "${KEY_LENGTH}"
        "--cert-file" "${cert_file}"
        "--key-file" "${key_file}"
        "--fullchain-file" "${fullchain_file}"
    )

    if [ -n "${RELOAD_CMD}" ]; then
        install_args+=("--reloadcmd" "${RELOAD_CMD}")
    fi

    log "installing cert for ${primary_domain} to ${CERT_DIR}"
    "$(acme_bin)" "${install_args[@]}"

    if [ ! -e "${fullchain_file}" ] || [ ! -e "${key_file}" ]; then
        die "cert install failed for ${primary_domain}"
    fi

    log "cert install success for ${primary_domain}"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --email)
                [ $# -ge 2 ] || die "missing value for --email"
                EMAIL="$2"
                shift 2
                ;;
            --challenge)
                [ $# -ge 2 ] || die "missing value for --challenge"
                CHALLENGE="$2"
                shift 2
                ;;
            --dns-provider)
                [ $# -ge 2 ] || die "missing value for --dns-provider"
                DNS_PROVIDER="$2"
                shift 2
                ;;
            --http-mode)
                [ $# -ge 2 ] || die "missing value for --http-mode"
                HTTP_MODE="$2"
                shift 2
                ;;
            --webroot)
                [ $# -ge 2 ] || die "missing value for --webroot"
                WEBROOT="$2"
                shift 2
                ;;
            --cert-dir)
                [ $# -ge 2 ] || die "missing value for --cert-dir"
                CERT_DIR="$2"
                shift 2
                ;;
            --acme-home)
                [ $# -ge 2 ] || die "missing value for --acme-home"
                ACME_HOME="$2"
                shift 2
                ;;
            --key-length)
                [ $# -ge 2 ] || die "missing value for --key-length"
                KEY_LENGTH="$2"
                shift 2
                ;;
            --reloadcmd)
                [ $# -ge 2 ] || die "missing value for --reloadcmd"
                RELOAD_CMD="$2"
                shift 2
                ;;
            -d|--domain)
                [ $# -ge 2 ] || die "missing value for --domain"
                CERT_SPECS+=("$(normalize_cert_spec "$2")")
                shift 2
                ;;
            --install-only)
                INSTALL_ONLY=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "unknown argument: $1"
                ;;
        esac
    done
}

validate_args() {
    case "${CHALLENGE}" in
        dns01|http01)
            ;;
        *)
            die "--challenge must be dns01 or http01"
            ;;
    esac

    if [ -z "${EMAIL}" ]; then
        die "--email is required"
    fi

    if [ "${CHALLENGE}" = "dns01" ] && [ -z "${DNS_PROVIDER}" ]; then
        die "--dns-provider is required for dns01"
    fi

    if [ "${CHALLENGE}" = "dns01" ]; then
        require_dns_provider_env_vars
    fi

    if [ "${CHALLENGE}" = "http01" ]; then
        case "${HTTP_MODE}" in
            standalone|webroot)
                ;;
            *)
                die "--http-mode must be standalone or webroot"
                ;;
        esac

        if [ "${HTTP_MODE}" = "webroot" ] && [ -z "${WEBROOT}" ]; then
            die "--webroot is required when --http-mode webroot"
        fi
    fi

    if [ "${INSTALL_ONLY}" -eq 0 ] && [ "${#CERT_SPECS[@]}" -eq 0 ]; then
        die "at least one -d/--domain is required"
    fi
}

main() {
    local cert_spec=""

    parse_args "$@"
    require_root
    require_linux
    validate_args
    ensure_default_reload_hook
    install_acme "${EMAIL}"

    if [ "${INSTALL_ONLY}" -eq 1 ]; then
        log "install-only mode completed"
        return 0
    fi

    for cert_spec in "${CERT_SPECS[@]}"; do
        issue_cert "${cert_spec}"
    done

    log "all certificate requests completed"
}

main "$@"
