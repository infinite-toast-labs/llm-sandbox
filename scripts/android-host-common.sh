#!/usr/bin/env bash
set -euo pipefail

ANDROID_AVD_NAME="${ANDROID_AVD_NAME:-llm_sandbox_pixel_9_pro_api_36_1}"
ANDROID_DEVICE_ID="${ANDROID_DEVICE_ID:-pixel_9_pro}"
ANDROID_SYSTEM_IMAGE="${ANDROID_SYSTEM_IMAGE:-system-images;android-36.1;google_apis_playstore;arm64-v8a}"
ANDROID_EMULATOR_PORT="${ANDROID_EMULATOR_PORT:-5560}"
ANDROID_EMULATOR_TCP_PORT="${ANDROID_EMULATOR_TCP_PORT:-5561}"
ANDROID_HOST_ADB_SERVER_PORT="${ANDROID_HOST_ADB_SERVER_PORT:-5037}"

ANDROID_HOST_SDK_ROOT="${ANDROID_HOST_SDK_ROOT:-}"
ANDROID_HOST_ADB="${ANDROID_HOST_ADB:-}"
ANDROID_HOST_EMULATOR="${ANDROID_HOST_EMULATOR:-}"
ANDROID_HOST_AVDMANAGER="${ANDROID_HOST_AVDMANAGER:-}"
ANDROID_HOST_SDKMANAGER="${ANDROID_HOST_SDKMANAGER:-}"
DOCKER_DESKTOP_SETTINGS="${DOCKER_DESKTOP_SETTINGS:-}"

android_require_macos() {
  if [ "$(uname -s)" != "Darwin" ]; then
    echo "Error: the optional Android sandbox workflow currently expects a macOS host." >&2
    exit 1
  fi
}

android_docker_settings_candidates() {
  if [ -n "$DOCKER_DESKTOP_SETTINGS" ]; then
    printf '%s\n' "$DOCKER_DESKTOP_SETTINGS"
  fi
  printf '%s\n' \
    "$HOME/Library/Group Containers/group.com.docker/settings-store.json" \
    "$HOME/Library/Group Containers/group.com.docker/settings.json" \
    "$HOME/Library/Application Support/Docker/settings-store.json" \
    "$HOME/Library/Application Support/Docker/settings.json"
}

android_resolve_docker_settings_path() {
  local candidate preferred

  preferred="$HOME/Library/Group Containers/group.com.docker/settings-store.json"
  while IFS= read -r candidate; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done < <(android_docker_settings_candidates)

  if [ -d "$(dirname "$preferred")" ]; then
    printf '%s\n' "$preferred"
    return 0
  fi

  return 1
}

android_resolve_host_sdk_root() {
  if [ -n "$ANDROID_HOST_SDK_ROOT" ] && [ -d "$ANDROID_HOST_SDK_ROOT" ]; then
    return 0
  fi

  local candidate
  for candidate in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" "$HOME/Library/Android/sdk"; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
      ANDROID_HOST_SDK_ROOT="$candidate"
      export ANDROID_HOST_SDK_ROOT
      return 0
    fi
  done

  ANDROID_HOST_SDK_ROOT=""
  export ANDROID_HOST_SDK_ROOT
}

android_find_tool() {
  local tool="$1"
  local path_candidate=""

  android_resolve_host_sdk_root

  case "$tool" in
    adb)
      if [ -n "$ANDROID_HOST_SDK_ROOT" ] && [ -x "$ANDROID_HOST_SDK_ROOT/platform-tools/adb" ]; then
        echo "$ANDROID_HOST_SDK_ROOT/platform-tools/adb"
        return 0
      fi
      ;;
    emulator)
      if [ -n "$ANDROID_HOST_SDK_ROOT" ] && [ -x "$ANDROID_HOST_SDK_ROOT/emulator/emulator" ]; then
        echo "$ANDROID_HOST_SDK_ROOT/emulator/emulator"
        return 0
      fi
      ;;
    avdmanager|sdkmanager)
      if [ -n "$ANDROID_HOST_SDK_ROOT" ] && [ -d "$ANDROID_HOST_SDK_ROOT/cmdline-tools" ]; then
        while IFS= read -r path_candidate; do
          if [ -x "$path_candidate" ]; then
            echo "$path_candidate"
            return 0
          fi
        done < <(find "$ANDROID_HOST_SDK_ROOT/cmdline-tools" -maxdepth 4 -path "*/bin/$tool" -type f 2>/dev/null | sort)
      fi
      ;;
  esac

  if command -v "$tool" >/dev/null 2>&1; then
    command -v "$tool"
    return 0
  fi

  return 1
}

android_print_prereq_message() {
  local missing=("$@")
  local joined_missing
  joined_missing="$(printf '%s ' "${missing[@]}")"

  cat <<EOF >&2
Android development support is optional and requires host Android tools before you run these targets.

Missing tools: ${joined_missing% }

Expected host prerequisites:
  - Android SDK root present at \$ANDROID_SDK_ROOT, \$ANDROID_HOME, or ~/Library/Android/sdk
  - adb
  - emulator
  - avdmanager
  - sdkmanager

On macOS the simplest path is Android Studio + Android SDK Command-line Tools.
After installation, make sure the SDK root is discoverable or export ANDROID_SDK_ROOT explicitly.
EOF
}

android_require_host_tools() {
  local tool resolved
  local -a missing=()

  for tool in "$@"; do
    resolved="$(android_find_tool "$tool" || true)"
    case "$tool" in
      adb) ANDROID_HOST_ADB="$resolved" ;;
      emulator) ANDROID_HOST_EMULATOR="$resolved" ;;
      avdmanager) ANDROID_HOST_AVDMANAGER="$resolved" ;;
      sdkmanager) ANDROID_HOST_SDKMANAGER="$resolved" ;;
    esac
    if [ -z "$resolved" ]; then
      missing+=("$tool")
    fi
  done

  export ANDROID_HOST_ADB ANDROID_HOST_EMULATOR ANDROID_HOST_AVDMANAGER ANDROID_HOST_SDKMANAGER

  if [ "${#missing[@]}" -gt 0 ]; then
    android_print_prereq_message "${missing[@]}"
    return 1
  fi
}

android_system_image_dir() {
  android_resolve_host_sdk_root
  printf '%s/%s\n' "$ANDROID_HOST_SDK_ROOT" "${ANDROID_SYSTEM_IMAGE//;/\/}"
}

android_avd_ini_path() {
  printf '%s/.android/avd/%s.ini\n' "$HOME" "$ANDROID_AVD_NAME"
}

android_avd_dir() {
  printf '%s/.android/avd/%s.avd\n' "$HOME" "$ANDROID_AVD_NAME"
}

android_upsert_ini() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp_file

  tmp_file="$(mktemp)"
  if [ -f "$file" ]; then
    awk -F= -v key="$key" -v value="$value" '
      $1 == key { print key "=" value; found = 1; next }
      { print }
      END { if (!found) print key "=" value }
    ' "$file" >"$tmp_file"
  else
    printf '%s=%s\n' "$key" "$value" >"$tmp_file"
  fi
  mv "$tmp_file" "$file"
}

android_resolve_running_avd_serial() {
  local serial state avd_name

  while read -r serial state; do
    [ -n "$serial" ] || continue
    case "$serial" in
      emulator-*)
        ;;
      *)
        continue
        ;;
    esac
    [ "$state" = "device" ] || continue
    avd_name="$("$ANDROID_HOST_ADB" -s "$serial" emu avd name 2>/dev/null | tr -d '\r')"
    if [ "$avd_name" = "$ANDROID_AVD_NAME" ]; then
      printf '%s\n' "$serial"
      return 0
    fi
  done < <("$ANDROID_HOST_ADB" devices | tail -n +2)

  return 1
}

android_resolve_avd_pid() {
  ps -ax -o pid= -o command= | awk -v avd="$ANDROID_AVD_NAME" -v port="$ANDROID_EMULATOR_PORT" '
    $0 ~ ("-avd " avd) &&
    $0 ~ ("-port " port) &&
    ($0 ~ /\/emulator( |$)/ || $0 ~ /qemu-system-/) {
      print $1
      exit
    }
  '
}

android_restart_host_adb_server_for_container() {
  "$ANDROID_HOST_ADB" kill-server >/dev/null 2>&1 || true
  "$ANDROID_HOST_ADB" -a start-server >/dev/null
}
