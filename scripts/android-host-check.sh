#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

quiet=0
print_adb=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quiet)
      quiet=1
      ;;
    --print-adb)
      print_adb=1
      ;;
    *)
      echo "Usage: $0 [--quiet] [--print-adb]" >&2
      exit 1
      ;;
  esac
  shift
done

android_require_macos
android_resolve_host_sdk_root
android_require_host_tools adb emulator avdmanager sdkmanager

if [ "$(uname -m)" = "arm64" ]; then
  docker_settings="$(android_resolve_docker_settings_path || true)"
  if [ -f "$docker_settings" ]; then
    docker_flags="$(python3 -c '
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    data = json.load(fh)
print("1" if data.get("useVirtualizationFramework") or data.get("UseVirtualizationFramework") else "0")
print("1" if data.get("useVirtualizationFrameworkRosetta") or data.get("UseVirtualizationFrameworkRosetta") else "0")
' "$docker_settings" 2>/dev/null || true)"
    docker_vf_enabled="$(printf '%s\n' "$docker_flags" | sed -n '1p')"
    docker_rosetta_enabled="$(printf '%s\n' "$docker_flags" | sed -n '2p')"
    if [ "$docker_vf_enabled" != "1" ] || [ "$docker_rosetta_enabled" != "1" ]; then
      cat <<EOF >&2
Docker Desktop is not configured for Apple Virtualization Framework + Rosetta.

Interactive Codex inside the optional linux/amd64 Android container depends on
Docker Desktop using Rosetta for x86_64/amd64 emulation on Apple Silicon.

Fix:
  Docker Desktop > Settings > General
  - Use the Virtualization Framework
  - Use Rosetta for x86_64/amd64 emulation on Apple Silicon

After enabling both settings, restart Docker Desktop and rerun:
  make android-docker-rosetta
  make android-prereqs
EOF
      exit 1
    fi
  fi
fi

if [ "$print_adb" -eq 1 ]; then
  printf '%s\n' "$ANDROID_HOST_ADB"
  exit 0
fi

if [ "$quiet" -eq 0 ]; then
  cat <<EOF
Android host prerequisites look good.
  SDK root:    $ANDROID_HOST_SDK_ROOT
  adb:         $ANDROID_HOST_ADB
  emulator:    $ANDROID_HOST_EMULATOR
  avdmanager:  $ANDROID_HOST_AVDMANAGER
  sdkmanager:  $ANDROID_HOST_SDKMANAGER
  Docker amd64: $(if [ "$(uname -m)" = "arm64" ]; then printf '%s' 'Rosetta enabled'; else printf '%s' 'native host'; fi)
  Host adb server: tcp:$ANDROID_HOST_ADB_SERVER_PORT
  AVD name:    $ANDROID_AVD_NAME
  Device ID:   $ANDROID_DEVICE_ID
  Image:       $ANDROID_SYSTEM_IMAGE
  Ports:       emulator-$ANDROID_EMULATOR_PORT / tcp:$ANDROID_EMULATOR_TCP_PORT
EOF
fi
