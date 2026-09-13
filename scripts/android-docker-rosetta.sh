#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker CLI is not installed or not on PATH." >&2
  exit 1
fi

if [ "$(uname -s)" != "Darwin" ]; then
  # Docker Desktop/Rosetta is macOS-specific; preserve other Docker hosts.
  docker info >/dev/null
  exit 0
fi

start_docker_desktop() {
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  echo "Starting Docker Desktop with its saved settings..."
  open -a Docker
  echo "Waiting for Docker Desktop to become ready..."
  for _ in $(seq 1 180); do
    if docker info >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  echo "Error: Docker Desktop did not become ready within 180 seconds." >&2
  return 1
}

# Let Docker read its own settings first. Accessing its private settings from
# Python can trigger macOS app-data permission prompts during remote startup.
start_docker_desktop
if [ "$(uname -m)" != "arm64" ]; then
  echo "Docker is ready; Rosetta is not needed on this host."
  exit 0
fi
if pgrep -f '^/Applications/Docker[.]app/Contents/MacOS/com[.]docker[.]virtualization .* --rosetta( |$)' >/dev/null 2>&1; then
  echo "Docker is ready with Rosetta active; no settings access or restart needed."
  exit 0
fi

settings_changed=0
docker_settings=""
if [ "$(uname -m)" = "arm64" ]; then
  docker_settings="$(android_resolve_docker_settings_path || true)"
  if [ -z "$docker_settings" ]; then
    echo "Error: Docker Desktop settings directory not found." >&2
    echo "Start Docker Desktop once manually, then rerun this target." >&2
    exit 1
  fi

  settings_changed="$(python3 - "$docker_settings" <<'PYTHON'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
print(int(not (data.get("useVirtualizationFramework") is True
               and data.get("useVirtualizationFrameworkRosetta") is True)))
PYTHON
)"
fi

if [ "$settings_changed" -eq 0 ] && docker info >/dev/null 2>&1; then
  echo "Docker is already ready; no restart needed."
  exit 0
fi

if [ "$settings_changed" -eq 1 ]; then
  if pgrep -x Docker >/dev/null 2>&1 || pgrep -f '/com.docker.backend' >/dev/null 2>&1; then
    echo "Stopping Docker Desktop to enable Rosetta..."
    osascript -e 'quit app "Docker"'
    for _ in $(seq 1 30); do
      if ! pgrep -x Docker >/dev/null 2>&1 && ! pgrep -f '/com.docker.backend' >/dev/null 2>&1; then
        break
      fi
      sleep 1
    done
    if pgrep -x Docker >/dev/null 2>&1 || pgrep -f '/com.docker.backend' >/dev/null 2>&1; then
      echo "Error: Docker Desktop did not quit cleanly; settings were not changed." >&2
      exit 1
    fi
  fi

  # Write after shutdown so Docker cannot overwrite the changes as it exits.
  echo "Enabling Apple Virtualization Framework + Rosetta at $docker_settings..."
  python3 - "$docker_settings" <<'PYTHON'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8")) if settings_path.exists() else {}
data["useVirtualizationFramework"] = True
data["useVirtualizationFrameworkRosetta"] = True
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PYTHON
fi

echo "Starting Docker Desktop..."
open -a Docker

echo "Waiting for Docker Desktop to become ready..."
for _ in $(seq 1 180); do
  if docker info >/dev/null 2>&1; then
    echo "Docker Desktop is ready."
    exit 0
  fi
  sleep 1
done

echo "Error: Docker Desktop did not become ready within 180 seconds." >&2
exit 1
