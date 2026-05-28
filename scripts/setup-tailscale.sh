#!/usr/bin/env bash
set -euo pipefail

SHELL_USER="${SHELL_USER:-gem}"
TAILSCALE_HOSTNAME="${TAILSCALE_HOSTNAME:-llm-sandbox}"
TAILSCALE_AUTH_KEY="${TAILSCALE_AUTH_KEY:-}"
TAILSCALE_EXTRA_ARGS="${TAILSCALE_EXTRA_ARGS:-}"
TAILSCALE_SOCKET="${TAILSCALE_SOCKET:-/var/run/tailscale/tailscaled.sock}"
TAILSCALE_UP_TIMEOUT="${TAILSCALE_UP_TIMEOUT:-20s}"
TAILSCALE_GODEBUG="${TAILSCALE_GODEBUG:-}"
SSH_PUBLIC_KEY="${SSH_PUBLIC_KEY:-}"
TAILSCALE_STATE_DIR="${TAILSCALE_STATE_DIR:-/home/${SHELL_USER}/.tailscale}"
TAILSCALE_STATE_FILE="${TAILSCALE_STATE_DIR}/tailscaled.state"
SSHD_DROPIN="/etc/ssh/sshd_config.d/99-llm-sandbox.conf"
USING_USERSPACE=0
LAST_TAILSCALE_UP_OUTPUT=""

has_systemd() {
    command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]
}

require_user() {
    if ! id "${SHELL_USER}" >/dev/null 2>&1; then
        echo "ERROR: user '${SHELL_USER}' does not exist in container."
        exit 1
    fi
}

install_prereqs() {
    if command -v curl >/dev/null 2>&1 && command -v ip >/dev/null 2>&1 && command -v sshd >/dev/null 2>&1; then
        return 0
    fi

    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y
    apt-get install -y curl ca-certificates iproute2 procps openssh-server
}

install_tailscale_if_missing() {
    if command -v tailscale >/dev/null 2>&1; then
        return 0
    fi
    curl -fsSL https://tailscale.com/install.sh | sh
}

ensure_sshd_running() {
    local ssh_dir="/home/${SHELL_USER}/.ssh"
    local auth_keys="${ssh_dir}/authorized_keys"

    mkdir -p /run/sshd "${ssh_dir}"
    touch "${auth_keys}"
    chmod 700 "${ssh_dir}"
    chmod 600 "${auth_keys}"
    chown -R "${SHELL_USER}:${SHELL_USER}" "${ssh_dir}"

    if [ -n "${SSH_PUBLIC_KEY}" ] && ! grep -Fqx "${SSH_PUBLIC_KEY}" "${auth_keys}"; then
        printf '%s\n' "${SSH_PUBLIC_KEY}" >> "${auth_keys}"
        echo "Added SSH key to ${auth_keys}"
    fi

    cat > "${SSHD_DROPIN}" <<EOF
PasswordAuthentication no
PubkeyAuthentication yes
PermitRootLogin no
ChallengeResponseAuthentication no
UsePAM yes
AllowUsers ${SHELL_USER}
EOF

    ssh-keygen -A >/dev/null 2>&1 || true
    /usr/sbin/sshd -t

    if ! pgrep -x sshd >/dev/null 2>&1; then
        /usr/sbin/sshd
    fi
}

ensure_user_shell_env() {
    local bashrc_template="/opt/gem/bashrc"
    local user_bashrc="/home/${SHELL_USER}/.bashrc"
    local marker_start="# >>> llm-sandbox tool env >>>"
    local marker_end="# <<< llm-sandbox tool env <<<"

    local -a target_files
    target_files=("${bashrc_template}" "${user_bashrc}")

    for target in "${target_files[@]}"; do
        touch "${target}"
        if ! grep -Fq "${marker_start}" "${target}"; then
            cat >> "${target}" <<'EOF'

# >>> llm-sandbox tool env >>>
export NPM_CONFIG_PREFIX="$HOME/.npm-global"
mkdir -p "$NPM_CONFIG_PREFIX/bin" "$NPM_CONFIG_PREFIX/lib" >/dev/null 2>&1 || true
case ":$PATH:" in
    *":$NPM_CONFIG_PREFIX/bin:"*) ;;
    *) export PATH="$NPM_CONFIG_PREFIX/bin:$PATH" ;;
esac
case ":$PATH:" in
    *":$HOME/.local/bin:"*) ;;
    *) export PATH="$HOME/.local/bin:$PATH" ;;
esac
# <<< llm-sandbox tool env <<<
EOF
        fi
    done

    chown "${SHELL_USER}:${SHELL_USER}" "${user_bashrc}"
    su - "${SHELL_USER}" -c 'mkdir -p "$HOME/.npm-global/bin" "$HOME/.npm-global/lib"'
    su - "${SHELL_USER}" -c 'npm config set prefix "$HOME/.npm-global" >/dev/null 2>&1 || true'
}

tailscale_cmd() {
    tailscale --socket="${TAILSCALE_SOCKET}" "$@"
}

tailscale_ip() {
    tailscale_cmd ip -4 2>/dev/null | head -1 || true
}

ensure_tailscaled_running() {
    mkdir -p /var/run/tailscale "${TAILSCALE_STATE_DIR}"
    chown -R "${SHELL_USER}:${SHELL_USER}" "${TAILSCALE_STATE_DIR}"

    if [ -n "${TAILSCALE_GODEBUG}" ] && pgrep -x tailscaled >/dev/null 2>&1; then
        pkill -x tailscaled >/dev/null 2>&1 || true
        sleep 1
    fi

    if tailscale_cmd debug prefs >/dev/null 2>&1; then
        return 0
    fi

    if pgrep -x tailscaled >/dev/null 2>&1; then
        pkill -x tailscaled >/dev/null 2>&1 || true
        sleep 1
    fi

    if has_systemd; then
        systemctl enable --now tailscaled
    else
        local -a tailscaled_args
        local -a tailscaled_env
        tailscaled_args=(--state="${TAILSCALE_STATE_FILE}" --socket="${TAILSCALE_SOCKET}")
        tailscaled_env=()
        if [ -n "${TAILSCALE_GODEBUG}" ]; then
            tailscaled_env+=(GODEBUG="${TAILSCALE_GODEBUG}")
        fi
        if [ ! -e /dev/net/tun ]; then
            echo "Note: /dev/net/tun not found, using userspace networking mode."
            tailscaled_args+=(--tun=userspace-networking)
            USING_USERSPACE=1
        fi
        nohup env "${tailscaled_env[@]}" tailscaled "${tailscaled_args[@]}" >/var/log/tailscaled.log 2>&1 &
    fi

    for _ in {1..30}; do
        if tailscale_cmd debug prefs >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
    done

    echo "ERROR: tailscaled did not become ready."
    exit 1
}

tailscale_up() {
    local -a up_args
    up_args=(--ssh --accept-routes --hostname="${TAILSCALE_HOSTNAME}" --timeout="${TAILSCALE_UP_TIMEOUT}")

    if [ "${1:-}" = "--force-reauth" ]; then
        up_args+=(--force-reauth)
    fi

    if [ -n "${TAILSCALE_AUTH_KEY}" ]; then
        up_args+=(--authkey="${TAILSCALE_AUTH_KEY}")
    fi

    if [ -n "${TAILSCALE_EXTRA_ARGS}" ]; then
        # Intentional word splitting for CLI-style extra args.
        # shellcheck disable=SC2206
        local extra_args=( ${TAILSCALE_EXTRA_ARGS} )
        up_args+=("${extra_args[@]}")
    fi

    set +e
    local up_output
    up_output="$(tailscale_cmd up "${up_args[@]}" 2>&1)"
    local up_code=$?
    set -e
    LAST_TAILSCALE_UP_OUTPUT="${up_output}"

    printf '%s\n' "${up_output}"
    if [ "${up_code}" -ne 0 ]; then
        echo "tailscale up exited with code ${up_code}."
    fi
}

tailscale_auth_state_is_stale() {
    local status_output log_output diagnosis
    status_output="$(tailscale_cmd status 2>&1 || true)"
    log_output="$(tail -200 /var/log/tailscaled.log 2>/dev/null || true)"
    diagnosis="${LAST_TAILSCALE_UP_OUTPUT}
${status_output}
${log_output}"

    printf '%s\n' "${diagnosis}" | grep -Eiq 'chacha20poly1305|message authentication failed'
}

restart_tailscaled_with_fresh_state() {
    local backup_dir backup_file
    backup_dir="${TAILSCALE_STATE_DIR}/state-backups"
    backup_file="${backup_dir}/tailscaled.state.$(date +%Y%m%d%H%M%S).bak"

    echo "Backing up stale Tailscale state to ${backup_file}"
    mkdir -p "${backup_dir}"
    if [ -e "${TAILSCALE_STATE_FILE}" ]; then
        mv "${TAILSCALE_STATE_FILE}" "${backup_file}"
    fi
    chown -R "${SHELL_USER}:${SHELL_USER}" "${TAILSCALE_STATE_DIR}"

    pkill -x tailscaled >/dev/null 2>&1 || true
    sleep 1
    ensure_tailscaled_running
}

recover_stale_tailscale_auth() {
    if [ -z "${TAILSCALE_AUTH_KEY}" ]; then
        return 0
    fi
    if [ -n "$(tailscale_ip)" ]; then
        return 0
    fi
    if ! tailscale_auth_state_is_stale; then
        return 0
    fi

    echo "Detected stale Tailscale auth state; retrying with forced reauthentication."
    tailscale_up --force-reauth
    if [ -n "$(tailscale_ip)" ]; then
        return 0
    fi

    echo "Forced reauthentication did not recover Tailscale; registering from fresh state."
    restart_tailscaled_with_fresh_state
    tailscale_up
}

main() {
    require_user
    install_prereqs
    install_tailscale_if_missing
    ensure_user_shell_env
    ensure_sshd_running
    ensure_tailscaled_running
    tailscale_up
    recover_stale_tailscale_auth

    local tailscale_ip
    tailscale_ip="$(tailscale_ip)"
    if [ -z "${tailscale_ip}" ]; then
        echo "Tailscale is installed but not connected yet."
        echo "If a login URL was printed above, open it, then rerun make setup-tailscale."
        exit 1
    fi

    if [ ! -e /dev/net/tun ]; then
        USING_USERSPACE=1
    fi

    printf '%s\n' "${tailscale_ip}" > "${TAILSCALE_STATE_DIR}/ip.txt"
    chown "${SHELL_USER}:${SHELL_USER}" "${TAILSCALE_STATE_DIR}/ip.txt"
    chmod 644 "${TAILSCALE_STATE_DIR}/ip.txt"

    echo ""
    echo "Setup complete."
    echo "Tailscale IPv4: ${tailscale_ip}"
    echo "From another tailnet device:"
    echo "  tailscale ssh ${SHELL_USER}@${TAILSCALE_HOSTNAME}"
    if [ "${USING_USERSPACE}" = "0" ] && [ -s "/home/${SHELL_USER}/.ssh/authorized_keys" ]; then
        echo "  ssh ${SHELL_USER}@${tailscale_ip}"
        echo ""
        echo "Plain http://${tailscale_ip}:8080 is not a secure browser context."
        echo "The host-side make target provisions HTTPS and exports a local CA cert after this step."
    elif [ "${USING_USERSPACE}" = "1" ]; then
        echo "Userspace mode detected; use tailscale ssh for remote access."
    fi
}

main "$@"
