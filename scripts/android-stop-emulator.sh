#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

android_require_macos
android_resolve_host_sdk_root
android_require_host_tools adb

serial="$(android_resolve_running_avd_serial || true)"
pid="$(android_resolve_avd_pid || true)"

if [ -n "$serial" ]; then
  echo "Stopping emulator '$ANDROID_AVD_NAME' ($serial)..."
  "$ANDROID_HOST_ADB" -s "$serial" emu kill >/dev/null || true
elif [ -n "$pid" ]; then
  echo "Stopping stale emulator '$ANDROID_AVD_NAME' process ($pid)..."
  kill "$pid" >/dev/null 2>&1 || true
else
  echo "Emulator '$ANDROID_AVD_NAME' is not running."
fi

"$ANDROID_HOST_ADB" disconnect "127.0.0.1:$ANDROID_EMULATOR_TCP_PORT" >/dev/null 2>&1 || true
