#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

android_require_macos
android_resolve_host_sdk_root
android_require_host_tools adb emulator avdmanager sdkmanager
android_restart_host_adb_server_for_container

window_mode="${ANDROID_EMULATOR_WINDOW_MODE:-headless}"
case "$window_mode" in
  headless)
    ;;
  windowed)
    ;;
  *)
    echo "Error: ANDROID_EMULATOR_WINDOW_MODE must be 'headless' or 'windowed'." >&2
    exit 1
    ;;
esac

serial="$(android_resolve_running_avd_serial || true)"
desired_serial="emulator-$ANDROID_EMULATOR_PORT"
stale_pid="$(android_resolve_avd_pid || true)"
log_file="$HOME/.android/${ANDROID_AVD_NAME}.log"
mkdir -p "$HOME/.android"

if [ -z "$serial" ]; then
  if "$ANDROID_HOST_ADB" devices | awk 'NR > 1 {print $1}' | grep -Fxq "$desired_serial"; then
    if [ -n "$stale_pid" ]; then
      echo "Removing stale emulator '$ANDROID_AVD_NAME' process on $desired_serial..."
      kill "$stale_pid" >/dev/null 2>&1 || true
      sleep 2
      "$ANDROID_HOST_ADB" disconnect "127.0.0.1:$ANDROID_EMULATOR_TCP_PORT" >/dev/null 2>&1 || true
    else
      echo "Error: $desired_serial is already in use by a different emulator." >&2
      echo "Stop the other emulator or change ANDROID_EMULATOR_PORT before retrying." >&2
      exit 1
    fi
  fi

  "$SCRIPT_DIR/android-create-avd.sh"

  echo "Starting emulator '$ANDROID_AVD_NAME' on $desired_serial in $window_mode mode..."
  python3 - "$ANDROID_HOST_EMULATOR" "$log_file" \
    "$ANDROID_AVD_NAME" "$ANDROID_EMULATOR_PORT" "$window_mode" <<'PY'
import subprocess
import sys

emulator, log_file, avd_name, port, window_mode = sys.argv[1:6]

args = [
    emulator,
    "-avd", avd_name,
    "-port", port,
    "-gpu", "host",
    "-skip-adb-auth",
    "-no-boot-anim",
    "-no-snapshot-load",
    "-no-snapshot-save",
    "-netdelay", "none",
    "-netspeed", "full",
]
if window_mode == "headless":
    args.append("-no-window")

with open(log_file, "ab", buffering=0) as log:
    proc = subprocess.Popen(
        args,
        stdin=subprocess.DEVNULL,
        stdout=log,
        stderr=subprocess.STDOUT,
        start_new_session=True,
        close_fds=True,
    )
    print(proc.pid)
PY

  serial="$desired_serial"
else
  echo "Emulator '$ANDROID_AVD_NAME' is already running on $serial."
fi

echo "Waiting for $serial to boot..."
for _ in $(seq 1 120); do
  if "$ANDROID_HOST_ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -qx '1'; then
    break
  fi
  sleep 2
done

if ! "$ANDROID_HOST_ADB" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | grep -qx '1'; then
  echo "Error: emulator '$ANDROID_AVD_NAME' did not finish booting. See $log_file for details." >&2
  exit 1
fi

echo "Using host adb server bridge on port $ANDROID_HOST_ADB_SERVER_PORT..."
sleep 2

echo "Host ADB devices:"
"$ANDROID_HOST_ADB" devices
echo ""
echo "Container adb server: host.docker.internal:$ANDROID_HOST_ADB_SERVER_PORT"
echo "Container target serial: $desired_serial"
