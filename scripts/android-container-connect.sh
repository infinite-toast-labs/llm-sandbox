#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

if [ "$#" -ne 1 ]; then
  echo "Usage: $0 <container-name>" >&2
  exit 1
fi

container_name="$1"
adb_host="host.docker.internal"
adb_port="$ANDROID_HOST_ADB_SERVER_PORT"
emulator_serial="emulator-$ANDROID_EMULATOR_PORT"

android_require_macos
android_resolve_host_sdk_root
android_require_host_tools adb

if ! docker container inspect "$container_name" >/dev/null 2>&1; then
  echo "Error: container '$container_name' does not exist. Run the Android sandbox target first." >&2
  exit 1
fi

if ! docker container inspect -f '{{.State.Running}}' "$container_name" 2>/dev/null | grep -q true; then
  echo "Starting container '$container_name'..."
  docker start "$container_name" >/dev/null
  sleep 3
fi

docker exec -u root "$container_name" bash -lc "
  install -d -m 755 /usr/local/bin
  install -d -m 755 /home/gem/.local/bin
  android_sdk_root=\${ANDROID_SDK_ROOT:-/opt/android-sdk}
  adb_bin=\$(command -v adb || true)
  if [ -z \"\$adb_bin\" ] && [ -x \"\$android_sdk_root/platform-tools/adb\" ]; then
    adb_bin=\"\$android_sdk_root/platform-tools/adb\"
  fi
  if [ -z \"\$adb_bin\" ]; then
    echo 'Error: adb is not installed in the container image.' >&2
    exit 1
  fi
  cat > /usr/local/bin/android-adb <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec \"\$adb_bin\" -H '$adb_host' -P '$adb_port' \"\\\$@\"
EOF
  cat > /usr/local/bin/android-emulator-adb <<EOF
#!/usr/bin/env bash
set -euo pipefail
exec \"\$adb_bin\" -H '$adb_host' -P '$adb_port' -s '$emulator_serial' \"\\\$@\"
EOF
  chmod 755 /usr/local/bin/android-adb /usr/local/bin/android-emulator-adb
  ln -sf /usr/local/bin/android-adb /home/gem/.local/bin/android-adb
  ln -sf /usr/local/bin/android-emulator-adb /home/gem/.local/bin/android-emulator-adb
"

for _ in $(seq 1 30); do
  if "$ANDROID_HOST_ADB" devices | awk -v serial="$emulator_serial" 'NR > 1 && $1 == serial && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
    break
  fi
  sleep 1
done

docker exec -u gem "$container_name" bash -lc "
  set -euo pipefail
  echo 'Container ADB devices via host adb server:'
  android-adb devices -l
"

if ! "$ANDROID_HOST_ADB" devices | awk -v serial="$emulator_serial" 'NR > 1 && $1 == serial && $2 == "device" { found = 1 } END { exit(found ? 0 : 1) }'; then
  echo >&2
  echo "Error: host adb server does not currently see '$emulator_serial' as a ready device." >&2
  echo "The container bridge helpers were installed, but the deterministic emulator is not currently available." >&2
  echo "Run 'make android-emulator-start' or 'make android-connect' so the host adb server is restarted in managed mode before the emulator boots." >&2
  exit 1
fi

docker exec -u gem "$container_name" bash -lc "
  set -euo pipefail
  echo
  echo 'Deterministic emulator state:'
  android-emulator-adb get-state
"
