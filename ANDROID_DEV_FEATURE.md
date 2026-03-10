# Thesis

The goal is to create a **reproducible Android development and testing environment** where:

1. The **Android Emulator runs on the macOS host** to use Apple GPU acceleration (Metal).
2. A **Dockerized Ubuntu environment** contains the coding agent, Android SDK tools, and automation stack.
3. The container **connects to the host emulator via ADB over TCP** using `host.docker.internal`.
4. The setup must support **end-to-end (E2E) Android testing**, including building APKs, installing them on the emulator, and running automated UI tests.

The agent must produce a **fully working pipeline** that can be rebuilt from scratch and verified automatically.

---

# Objectives

Implement a system where:

* macOS host runs Android Emulator with GPU acceleration
* Docker container runs Ubuntu dev environment
* Container connects to emulator using ADB
* Container builds and installs Android apps
* Container runs automated UI tests

The result should allow a coding agent to iterate on Android apps and verify behavior **without running the emulator inside Docker**.

---

# Constraints

1. Emulator **must run on macOS host** (Apple Silicon GPU cannot be passed into Docker).
2. Docker container must run **Ubuntu**.
3. Android SDK tools must be installed via `sdkmanager`.
4. ADB must connect to `host.docker.internal:5555`.
5. Everything must be **scriptable and reproducible**.
6. The system must support **headless CI-style testing**.

---

# System Architecture

```
macOS Host
│
├─ Android Emulator (GPU acceleration via Metal)
│     └─ adb tcpip 5555
│
└─ Docker
      └─ Ubuntu container
            ├─ Android SDK
            ├─ adb client
            ├─ build tools / Gradle
            ├─ test automation tools
            └─ coding agent
```

The emulator is treated as a **remote Android device** reachable through ADB.

---

# Implementation Tasks

## 1. Create Dockerfile

Update an existing Dockerfile that:

* installs:

  * openjdk-17
  * android sdk commandline tools
  * adb
  * gradle
  * python3 + pip
* installs Android platform tools
* installs Android build tools
* accepts Android SDK licenses automatically

Ensure environment variables:

```
ANDROID_HOME=/opt/android-sdk
ANDROID_SDK_ROOT=/opt/android-sdk
```

Add SDK paths to `PATH`.

The container must start with a shell that:

* attempts `adb connect host.docker.internal:5555`
* prints `adb devices`

---

## 2. Host Emulator Setup Script

Create a macOS script:

```
scripts/start_emulator.sh
```

Responsibilities:

1. Start an Android Virtual Device:

```
emulator -avd <pixel 9 pro devic> -gpu host
```

2. Enable ADB TCP:

```
adb tcpip 5555
```

3. Confirm emulator availability:

```
adb devices
```

Ensure emulator is reachable via TCP.

---

## 3. Container Startup Script

Create or update a container entry script:

```
scripts/container_init.sh
```

Responsibilities:

1. Wait until emulator is reachable.
2. Run:

```
adb connect host.docker.internal:5555
```

3. Verify connection:

```
adb devices
```

Retry connection if needed.

---

## 4. Android Build Verification

Inside the container:

1. Create a minimal Android sample app or clone one.
2. Build APK using Gradle:

```
./gradlew assembleDebug
```

3. Install APK:

```
adb install app-debug.apk
```

4. Launch the activity:

```
adb shell am start
```

---

## 5. UI Automation Test

Implement a simple E2E test:

Options:

* `uiautomator2`
* Android instrumentation tests
* ADB input commands

Example actions:

```
adb shell input tap
adb shell input text
```

Verify:

* app launches
* UI interaction works

Return pass/fail result.

---

## 6. End-to-End Validation Script

Create:

```
scripts/e2e_test.sh
```

Steps:

1. Verify ADB connection
2. Build APK
3. Install APK
4. Launch app
5. Run UI interaction test
6. Exit with success/failure

The script should allow automated CI verification.

---

# Expected Deliverables

The agent must produce:

```
project/
│
├─ Dockerfile
├─ docker-compose.yml
│
├─ scripts/
│     ├─ start_emulator.sh
│     ├─ container_init.sh
│     └─ e2e_test.sh
│
├─ sample-android-app/
│
└─ README.md
```

README must include:

* prerequisites
* how to start emulator
* how to build container
* how to run E2E test

---

# Success Criteria

The setup is successful when:

1. Emulator runs on macOS with GPU acceleration.
2. Container connects via ADB.
3. APK builds successfully.
4. APK installs onto emulator.
5. Automated test executes.
6. Entire workflow can be reproduced from a clean environment.

---

# Optional Enhancements

If time permits:

* support **multiple emulators**
* parallel test execution
* screenshot capture via ADB
* video recording of test runs
* automated crash log extraction (`logcat`)

---

# End State

A coding agent should be able to:

* edit Android code
* rebuild the APK
* deploy to emulator
* run UI tests
* iterate automatically

without needing GPU access inside Docker.
