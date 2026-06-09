#!/usr/bin/env bash
# Fix ownership of /home/gem when mounted as a Docker volume (created root-owned)
chown "$USER_UID:$USER_GID" /home/gem

# Keep integrated-terminal Git auth on the normal Git credential helper path.
# code-server's integrated askpass injects a per-window socket into terminals; if
# that socket goes stale, `gh auth status` remains fine while `git push` fails.
SETTINGS_DIR="/home/gem/.config/code-server/vscode/User"
SETTINGS_FILE="$SETTINGS_DIR/settings.json"
mkdir -p "$SETTINGS_DIR"
python3 - "$SETTINGS_FILE" <<'PY'
import json
import pathlib
import sys

settings_path = pathlib.Path(sys.argv[1])
settings = {}
if settings_path.exists():
    raw = settings_path.read_text(encoding="utf-8").strip()
    if raw:
        try:
            settings = json.loads(raw)
        except json.JSONDecodeError:
            backup_path = settings_path.with_suffix(".json.invalid")
            backup_path.write_text(raw + "\n", encoding="utf-8")
            settings = {}

settings["git.useIntegratedAskPass"] = False
settings_path.write_text(json.dumps(settings, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
chown -R "$USER_UID:$USER_GID" "$SETTINGS_DIR"

exec /opt/gem/run.sh "$@"
