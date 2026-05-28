#!/usr/bin/env bash
set -euo pipefail

SHELL_USER="${SHELL_USER:-gem}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/home/${SHELL_USER}/.tailscale}"
TAILSCALE_HTTPS_DIR="${TAILSCALE_HTTPS_DIR:-${TAILSCALE_STATE_DIR}/https}"
TAILSCALE_HTTPS_PORT="${TAILSCALE_HTTPS_PORT:-443}"
TAILSCALE_CA_DAYS="${TAILSCALE_CA_DAYS:-3650}"
TAILSCALE_SERVER_CERT_DAYS="${TAILSCALE_SERVER_CERT_DAYS:-825}"
NGINX_ACTIVE_CONF="${NGINX_ACTIVE_CONF:-/opt/gem/nginx-server-active.conf}"
NGINX_ACTIVE_CONF_BACKUP="${NGINX_ACTIVE_CONF}.llm-sandbox-orig"

tailscale_cmd() {
    tailscale --socket="${TAILSCALE_SOCKET}" "$@"
}

require_tailscale_online() {
    if ! tailscale_cmd debug prefs >/dev/null 2>&1; then
        echo "ERROR: tailscaled is not ready." >&2
        exit 1
    fi
}

read_tailscale_identity() {
    local status_json
    status_json="$(tailscale_cmd status --json)"

    TAILSCALE_IP="$(tailscale_cmd ip -4 2>/dev/null | head -1 || true)"
    TAILSCALE_DNS_NAME="$(printf '%s\n' "${status_json}" | awk -F'"' '/"DNSName":/ {print $4; exit}' | sed 's/\.$//')"

    if [ -z "${TAILSCALE_IP}" ] || [ -z "${TAILSCALE_DNS_NAME}" ]; then
        echo "ERROR: could not determine Tailscale IP/DNS identity." >&2
        exit 1
    fi
}

ensure_openssl() {
    if command -v openssl >/dev/null 2>&1; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y openssl
}

generate_ca_if_missing() {
    mkdir -p "${TAILSCALE_HTTPS_DIR}"

    if [ -s "${TAILSCALE_HTTPS_DIR}/ca.key" ] && [ -s "${TAILSCALE_HTTPS_DIR}/ca.crt" ]; then
        return 0
    fi

    local ca_common_name
    ca_common_name="${TAILSCALE_CA_COMMON_NAME:-llm-sandbox Tailscale Local CA (${TAILSCALE_DNS_NAME})}"

    openssl genrsa -out "${TAILSCALE_HTTPS_DIR}/ca.key" 2048 >/dev/null 2>&1
    openssl req \
        -x509 \
        -new \
        -nodes \
        -key "${TAILSCALE_HTTPS_DIR}/ca.key" \
        -sha256 \
        -days "${TAILSCALE_CA_DAYS}" \
        -subj "/CN=${ca_common_name}/" \
        -out "${TAILSCALE_HTTPS_DIR}/ca.crt" >/dev/null 2>&1
}

generate_server_cert() {
    cat > "${TAILSCALE_HTTPS_DIR}/server-ext.cnf" <<EOF
subjectAltName=DNS:${TAILSCALE_DNS_NAME},IP:${TAILSCALE_IP}
extendedKeyUsage=serverAuth
keyUsage=digitalSignature,keyEncipherment
EOF

    openssl genrsa -out "${TAILSCALE_HTTPS_DIR}/server.key" 2048 >/dev/null 2>&1
    openssl req \
        -new \
        -key "${TAILSCALE_HTTPS_DIR}/server.key" \
        -subj "/CN=${TAILSCALE_DNS_NAME}/" \
        -out "${TAILSCALE_HTTPS_DIR}/server.csr" >/dev/null 2>&1
    openssl x509 \
        -req \
        -in "${TAILSCALE_HTTPS_DIR}/server.csr" \
        -CA "${TAILSCALE_HTTPS_DIR}/ca.crt" \
        -CAkey "${TAILSCALE_HTTPS_DIR}/ca.key" \
        -CAcreateserial \
        -out "${TAILSCALE_HTTPS_DIR}/server.crt" \
        -days "${TAILSCALE_SERVER_CERT_DAYS}" \
        -sha256 \
        -extfile "${TAILSCALE_HTTPS_DIR}/server-ext.cnf" >/dev/null 2>&1

    chmod 700 "${TAILSCALE_HTTPS_DIR}"
    chmod 600 "${TAILSCALE_HTTPS_DIR}/ca.key" "${TAILSCALE_HTTPS_DIR}/server.key"
    chmod 644 \
        "${TAILSCALE_HTTPS_DIR}/ca.crt" \
        "${TAILSCALE_HTTPS_DIR}/server.crt" \
        "${TAILSCALE_HTTPS_DIR}/server.csr" \
        "${TAILSCALE_HTTPS_DIR}/server-ext.cnf"
    if [ -e "${TAILSCALE_HTTPS_DIR}/ca.srl" ]; then
        chmod 644 "${TAILSCALE_HTTPS_DIR}/ca.srl"
    fi
    chown -R root:root "${TAILSCALE_HTTPS_DIR}"
}

patch_nginx_https_listener() {
    if [ ! -f "${NGINX_ACTIVE_CONF_BACKUP}" ]; then
        cp "${NGINX_ACTIVE_CONF}" "${NGINX_ACTIVE_CONF_BACKUP}"
    fi

    awk \
        -v port="${TAILSCALE_HTTPS_PORT}" \
        -v cert="${TAILSCALE_HTTPS_DIR}/server.crt" \
        -v key="${TAILSCALE_HTTPS_DIR}/server.key" \
        '
        {
            print
            if ($0 ~ /listen \[::\]:8080;/) {
                print ""
                print "    # llm-sandbox-tailscale-https"
                print "    listen " port " ssl;"
                print "    listen [::]:" port " ssl;"
                print "    ssl_certificate " cert ";"
                print "    ssl_certificate_key " key ";"
                print "    ssl_session_cache shared:llm_sandbox_tls:10m;"
                print "    ssl_session_timeout 1d;"
                print "    ssl_protocols TLSv1.2 TLSv1.3;"
            }
        }
        ' "${NGINX_ACTIVE_CONF_BACKUP}" > "${NGINX_ACTIVE_CONF}.tmp"

    mv "${NGINX_ACTIVE_CONF}.tmp" "${NGINX_ACTIVE_CONF}"

    nginx -t >/dev/null
    nginx -s reload >/dev/null 2>&1 || nginx
}

write_summary_files() {
    printf 'https://%s/\n' "${TAILSCALE_DNS_NAME}" > "${TAILSCALE_HTTPS_DIR}/url.txt"
    printf 'https://%s/\n' "${TAILSCALE_IP}" > "${TAILSCALE_HTTPS_DIR}/ip-url.txt"
    printf '%s\n' "${TAILSCALE_DNS_NAME}" > "${TAILSCALE_HTTPS_DIR}/dns-name.txt"
    printf '%s\n' "${TAILSCALE_IP}" > "${TAILSCALE_HTTPS_DIR}/ip.txt"
    chown "${SHELL_USER}:${SHELL_USER}" \
        "${TAILSCALE_HTTPS_DIR}/url.txt" \
        "${TAILSCALE_HTTPS_DIR}/ip-url.txt" \
        "${TAILSCALE_HTTPS_DIR}/dns-name.txt" \
        "${TAILSCALE_HTTPS_DIR}/ip.txt"
}

main() {
    require_tailscale_online
    ensure_openssl
    read_tailscale_identity
    generate_ca_if_missing
    generate_server_cert
    patch_nginx_https_listener
    write_summary_files

    echo "Configured HTTPS on Tailscale interface."
    echo "  https://${TAILSCALE_DNS_NAME}/"
    echo "  https://${TAILSCALE_IP}/"
}

main "$@"
