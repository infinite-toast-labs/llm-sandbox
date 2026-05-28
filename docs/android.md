# Optional Android Development Support

This repository now includes an opt-in Android sandbox variant. The default
`make build` / `make up` flow is unchanged. Android support lives behind new
`make android-*` targets so existing users do not pay the image-size or host
tooling cost unless they want Android development.

## Host prerequisites

These host targets expect macOS plus Android development tools already
installed on the host:

- Android SDK root at `ANDROID_SDK_ROOT`, `ANDROID_HOME`, or `~/Library/Android/sdk`
- `adb`
- `emulator`
- `avdmanager`
- `sdkmanager`

Run the rough prerequisite check before anything else:

```bash
make android-docker-rosetta
make android-prereqs
```

If any required tool is missing, the target exits early with the expected
prerequisites instead of partially configuring the sandbox.

## What gets created

- An optional Docker image: `llm-sandbox-android`
- An optional Docker container: `llm-sandbox-android`
- An optional Docker volume: `llm-sandbox-android-home`
- A deterministic host AVD:
  `llm_sandbox_pixel_9_pro_api_36_1`

The Android container keeps its dashboard on `http://localhost:8081` so it can
coexist with the default sandbox at `http://localhost:8080`.

On Apple Silicon hosts, the Android variant is built and run as
`linux/amd64`. The official Linux Android SDK command-line toolchain used here
is x86_64-first, so the optional Android container runs under Docker's amd64
emulation while the emulator itself stays native on macOS.

On Apple Silicon with Docker Desktop, interactive `codex` in the Android
container requires Docker Desktop to use the Apple Virtualization Framework
plus Rosetta for `x86_64/amd64` emulation. If Rosetta is disabled, the Android
container may still run, but interactive `codex` can fail at startup with
`Function not implemented (os error 38)`.

Use `make android-docker-rosetta` to update Docker Desktop's settings, restart
Docker Desktop if needed, and wait until the daemon is ready again.

## Main workflow

```bash
make android-up
make android-shell
```

`make android-up` does the following:

1. Builds the Android-enabled image variant.
2. Verifies the macOS host prerequisites.
3. Creates the deterministic Pixel 9 Pro AVD if needed.
4. Starts the host emulator on fixed ports `5560/5561` with ADB auth prompts
   disabled for this managed emulator flow.
5. Starts the Android-enabled sandbox container.
6. Restarts the host ADB server in listen-on-all-interfaces mode on `5037`.
7. Installs `android-adb` and `android-emulator-adb` helpers in the container
   so container-side ADB commands go through the host ADB server and target the
   deterministic emulator serial.

## Useful targets

```bash
make android-avd-create
make android-emulator-start
make android-connect
make android-status
make android-emulator-stop
make android-stop
make android-clean
make android-destroy
```

Inside the Android container after `make android-up`, use:

```bash
android-adb devices -l
android-emulator-adb get-state
```

`android-adb` talks to the host ADB server at `host.docker.internal:5037`.
`android-emulator-adb` does the same thing but pins the deterministic emulator
serial `emulator-5560`.

## Notes

- The default sandbox image and container names remain unchanged.
- The Android image is built from the same base image, but only the
  `android-*` targets enable the Android toolchain layer.
- The host emulator stays outside Docker so Apple GPU acceleration remains on
  the macOS side.
- The container no longer connects directly to the emulator TCP port. It uses
  the host ADB server instead, which is more reliable on Docker Desktop.
- `make setup-tailscale-android` starts `tailscaled` with
  `GODEBUG=cpu.all=off` inside the amd64/Rosetta container. Without that Go
  runtime setting, Tailscale registration can fail with control-plane
  `chacha20poly1305: message authentication failed` errors.
- If you open the dashboard as `http://<tailscale-ip>:8080`, Chrome treats it
  as an insecure context. Image previews, markdown preview, clipboard access,
  and other webview features in code-server can fail in that mode.
- `make setup-tailscale-android` now also provisions HTTPS on the container's
  Tailscale interface and exports a local CA cert to
  `tailscale-certs/llm-sandbox-android-root-ca.crt`.
- Install and trust that CA cert on any client device that should open the
  sandbox directly, then use either
  `https://<tailscale-dns-name>/` or `https://<tailscale-ip>/`.
- `make tailscale-browser-android` still exists as a tunnel-based fallback if
  you do not want to install the CA cert on a client device.
