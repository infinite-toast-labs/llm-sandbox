#!/usr/bin/env bash
# install-android.sh — Install the clipboard bridge into the Android sandbox container.
#
# Usage (from repo root):
#   ./clipboard-bridge/install-android.sh [CONTAINER_NAME]
#
# Default container name: llm-sandbox-android

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_CONTAINER_VALUE="${DEFAULT_CONTAINER:-llm-sandbox-android}"
DASHBOARD_URL_VALUE="${DASHBOARD_URL:-http://localhost:8081}"

DEFAULT_CONTAINER="${DEFAULT_CONTAINER_VALUE}" \
DASHBOARD_URL="${DASHBOARD_URL_VALUE}" \
"${SCRIPT_DIR}/install.sh" "${1:-$DEFAULT_CONTAINER_VALUE}"
