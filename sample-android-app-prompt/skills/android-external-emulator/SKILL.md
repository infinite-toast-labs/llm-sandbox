---
name: android-external-emulator
description: Use when building or testing an Android app from inside a Linux sandbox container while the Android emulator runs outside the container and is reached through the host ADB server. Covers empty-project bootstrap, container-only Gradle builds, install/launch flows, UI interaction, screenshots, and failure handling when the external emulator bridge is missing.
---

# Android External Emulator

Use this skill when the coding agent is inside the Android sandbox container and must develop against an emulator running on the host, not inside Docker.

## Rules

- Do all Android SDK, Gradle, and `adb` work inside the container.
- Do not try to start `emulator` inside the container.
- Do not build APKs on the host.
- Assume the agent is already running inside the target app repository unless the user says otherwise.
- Default host ADB server is `host.docker.internal:5037`.
- Default deterministic emulator serial is `emulator-5560`.
- If the bridge is unavailable, stop and report the exact host-side action needed instead of guessing.

## Quick Start

From the current app repository:

```bash
pwd
ls -la
```

Before any Android build, install, or test step:

```bash
export ANDROID_ADB_HOST="${ANDROID_ADB_HOST:-host.docker.internal}"
export ANDROID_ADB_PORT="${ANDROID_ADB_PORT:-5037}"
export ANDROID_ADB_SERIAL="${ANDROID_ADB_SERIAL:-emulator-5560}"

if command -v android-adb >/dev/null 2>&1; then
  android-adb devices -l
else
  adb -H "$ANDROID_ADB_HOST" -P "$ANDROID_ADB_PORT" devices -l
fi
```

Continue only if the deterministic serial shows up as `device`.

## If The Emulator Is Missing

If the host ADB server does not show the deterministic emulator as `device`:

1. Retry `android-adb devices -l` or `adb -H "$ANDROID_ADB_HOST" -P "$ANDROID_ADB_PORT" devices -l`.
2. If it is still missing, tell the user the host ADB bridge is not available from the container.
3. Ask for the host-side Android sandbox flow to be started or reconnected, for example `make android-up` or `make android-connect` from the sandbox repo on the host.

Do not claim the app was tested if the container never reached the external emulator.

## Project Bootstrap

When the current repository is empty or only partially initialized:

- Create a standard Gradle Android app structure.
- Keep the first iteration lean so the first clean build is reliable.
- Avoid unnecessary dependencies until the app builds, installs, and launches.
- Prefer a single activity and a simple layout for the first verified loop.

Minimum loop:

1. App compiles.
2. APK installs from inside the container.
3. Activity launches on the external emulator.
4. One deterministic UI interaction runs through `adb`.
5. Screenshot evidence is captured.

## Build, Install, Launch

Run from the Android app root:

```bash
./gradlew --no-daemon assembleDebug --console=plain
android-emulator-adb install -r app/build/outputs/apk/debug/app-debug.apk
android-emulator-adb shell am start -n <applicationId>/<activity>
```

Use the actual manifest package and launch activity. If needed, inspect the manifest or Gradle config first.

## UI Validation

For deterministic UI interaction:

```bash
android-emulator-adb shell uiautomator dump /sdcard/window_dump.xml >/dev/null
android-emulator-adb exec-out cat /sdcard/window_dump.xml
```

Use the dumped bounds to drive:

```bash
android-emulator-adb shell input tap <x> <y>
```

Confirm foreground activity when needed:

```bash
android-emulator-adb shell dumpsys activity activities
```

## Screenshot Evidence

Save screenshots under the current project so the user can inspect them later:

```bash
mkdir -p artifacts/android-e2e
android-emulator-adb exec-out screencap -p > artifacts/android-e2e/before.png
android-emulator-adb exec-out screencap -p > artifacts/android-e2e/after.png
```

Capture at least:

- app launched
- post-interaction state

## Working Style

- Build small increments and verify often.
- Prefer direct terminal commands over speculative explanations.
- If Android Gradle Plugin, SDK platform, or build-tools versions disagree, fix the project or environment and rerun.
- Report exact commands and artifact paths in the final response.
