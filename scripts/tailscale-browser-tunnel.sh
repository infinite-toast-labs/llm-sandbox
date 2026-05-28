#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -ne 4 ]; then
    echo "Usage: $0 <tailscale-host-or-ip> <local-port> <remote-port> <ssh-user>" >&2
    exit 1
fi

TARGET_HOST="$1"
LOCAL_PORT="$2"
REMOTE_PORT="$3"
SSH_USER="$4"

if ! command -v ssh >/dev/null 2>&1; then
    echo "ERROR: ssh is required on the client machine." >&2
    exit 1
fi

echo "Open http://localhost:${LOCAL_PORT} in Chrome after the tunnel connects."
echo "Press Ctrl+C to stop the tunnel."

exec ssh \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -N \
    -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
    "${SSH_USER}@${TARGET_HOST}"
