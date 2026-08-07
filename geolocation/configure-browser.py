#!/usr/bin/env python3
"""Enable geolocation permission in sandbox Chromium's seeded/local profile."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import tempfile


PATHS = (
    pathlib.Path("/opt/gem/preferences.json"),
    pathlib.Path("/home/gem/.config/browser/Default/Preferences"),
)


def is_enabled(path: pathlib.Path) -> bool:
    if not path.exists():
        return path == PATHS[1]
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return False
    return (
        data.get("profile", {})
        .get("default_content_setting_values", {})
        .get("geolocation")
        == 1
    )


def enable(path: pathlib.Path) -> bool:
    if not path.exists():
        return False
    data = json.loads(path.read_text(encoding="utf-8"))
    settings = data.setdefault("profile", {}).setdefault(
        "default_content_setting_values", {}
    )
    if settings.get("geolocation") == 1:
        return False
    settings["geolocation"] = 1

    stat = path.stat()
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            json.dump(data, output, indent=2, sort_keys=True)
            output.write("\n")
        os.chmod(temporary_name, stat.st_mode)
        os.chown(temporary_name, stat.st_uid, stat.st_gid)
        os.replace(temporary_name, path)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "apply"))
    args = parser.parse_args()
    if args.command == "check":
        return 0 if all(is_enabled(path) for path in PATHS) else 1

    changed = [str(path) for path in PATHS if enable(path)]
    if changed:
        print("Enabled sandbox Chromium geolocation permission in: " + ", ".join(changed))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
