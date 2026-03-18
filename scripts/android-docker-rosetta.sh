#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./android-host-common.sh
source "$SCRIPT_DIR/android-host-common.sh"

android_require_macos

if ! command -v docker >/dev/null 2>&1; then
  echo "Error: Docker CLI is not installed or not on PATH." >&2
  exit 1
fi

if [ "$(uname -m)" != "arm64" ]; then
  echo "Docker Rosetta mode is only applicable on Apple Silicon; starting Docker Desktop normally."
  if ! pgrep -x Docker >/dev/null 2>&1; then
    open -a Docker
  fi
  exit 0
fi

docker_settings="$HOME/Library/Group Containers/group.com.docker/settings.json"
if [ ! -f "$docker_settings" ]; then
  echo "Error: Docker Desktop settings file not found at $docker_settings." >&2
  echo "Start Docker Desktop once manually, then rerun this target." >&2
  exit 1
fi

python3 - "$docker_settings" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
data = json.loads(settings_path.read_text(encoding="utf-8"))
data["useVirtualizationFramework"] = True
data["useVirtualizationFrameworkRosetta"] = True
settings_path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")
PY

if pgrep -x Docker >/dev/null 2>&1; then
  echo "Stopping Docker Desktop..."
  osascript -e 'quit app "Docker"' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    if ! pgrep -x Docker >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  if pgrep -x Docker >/dev/null 2>&1; then
    echo "Docker Desktop did not quit cleanly; forcing it to exit..."
    pkill -x Docker >/dev/null 2>&1 || true
    sleep 2
  fi
fi

echo "Starting Docker Desktop with Rosetta enabled..."
open -a Docker

echo "Waiting for Docker Desktop to become ready..."
for _ in $(seq 1 180); do
  if docker info >/dev/null 2>&1; then
    echo "Docker Desktop is running with Apple Virtualization Framework + Rosetta enabled."
    exit 0
  fi
  sleep 1
done

echo "Error: Docker Desktop did not become ready within 180 seconds." >&2
exit 1
