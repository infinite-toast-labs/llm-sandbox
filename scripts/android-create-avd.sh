#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

android_require_macos
android_resolve_host_sdk_root
android_require_host_tools adb emulator avdmanager sdkmanager

if ! "$ANDROID_HOST_AVDMANAGER" list device | grep -Eq "\"$ANDROID_DEVICE_ID\"|Name:[[:space:]]*$ANDROID_DEVICE_ID"; then
  echo "Error: device profile '$ANDROID_DEVICE_ID' is not available from avdmanager on this host." >&2
  exit 1
fi

system_image_dir="$(android_system_image_dir)"
if [ ! -d "$system_image_dir" ]; then
  echo "Installing host system image '$ANDROID_SYSTEM_IMAGE'..."
  set +o pipefail
  yes | "$ANDROID_HOST_SDKMANAGER" --sdk_root="$ANDROID_HOST_SDK_ROOT" --install "$ANDROID_SYSTEM_IMAGE"
  sdkmanager_status=${PIPESTATUS[1]:-0}
  set -o pipefail
  if [ "$sdkmanager_status" -ne 0 ]; then
    exit "$sdkmanager_status"
  fi
fi

mkdir -p "$HOME/.android/avd"

if [ ! -f "$(android_avd_ini_path)" ]; then
  echo "Creating AVD '$ANDROID_AVD_NAME'..."
  printf 'no\n' | "$ANDROID_HOST_AVDMANAGER" create avd \
    --force \
    --name "$ANDROID_AVD_NAME" \
    --package "$ANDROID_SYSTEM_IMAGE" \
    --device "$ANDROID_DEVICE_ID"
else
  echo "AVD '$ANDROID_AVD_NAME' already exists."
fi

config_file="$(android_avd_dir)/config.ini"
android_upsert_ini "$config_file" "AvdId" "$ANDROID_AVD_NAME"
android_upsert_ini "$config_file" "avd.name" "$ANDROID_AVD_NAME"
android_upsert_ini "$config_file" "PlayStore.enabled" "yes"
android_upsert_ini "$config_file" "avd.ini.displayname" "LLM Sandbox Pixel 9 Pro"
android_upsert_ini "$config_file" "fastboot.forceColdBoot" "yes"
android_upsert_ini "$config_file" "fastboot.forceFastBoot" "no"
android_upsert_ini "$config_file" "hw.gpu.enabled" "yes"
android_upsert_ini "$config_file" "hw.gpu.mode" "host"
android_upsert_ini "$config_file" "runtime.network.speed" "full"
android_upsert_ini "$config_file" "runtime.network.latency" "none"
android_upsert_ini "$config_file" "showDeviceFrame" "no"
android_upsert_ini "$config_file" "skin.dynamic" "yes"
android_upsert_ini "$config_file" "skin.name" "pixel_9_pro"
android_upsert_ini "$config_file" "skin.path" "$ANDROID_HOST_SDK_ROOT/skins/pixel_9_pro"

echo "AVD '$ANDROID_AVD_NAME' is ready."
