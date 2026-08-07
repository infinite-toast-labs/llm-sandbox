#!/usr/bin/env python3
"""Hot-reload a Chrome geolocation override through the DevTools Protocol."""

from __future__ import annotations

import argparse
import asyncio
import itertools
import json
import math
import os
import pathlib
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

import websockets


CONFIG_PATH = pathlib.Path(
    os.environ.get(
        "SANDBOX_GEOLOCATION_CONFIG",
        "/home/gem/.config/llm-sandbox/geolocation.json",
    )
)
CDP_HTTP_BASE = os.environ.get("SANDBOX_CDP_HTTP_BASE", "http://127.0.0.1:9222")
POLL_SECONDS = float(os.environ.get("SANDBOX_GEOLOCATION_POLL_SECONDS", "0.5"))
STATUS_PATH = pathlib.Path(
    os.environ.get(
        "SANDBOX_GEOLOCATION_STATUS",
        "/home/gem/.local/state/llm-sandbox/geolocation-status.json",
    )
)
CDP_REQUEST_IDS = itertools.count(1)


class GeolocationError(ValueError):
    pass


def log(message: str) -> None:
    print(
        f"{time.strftime('%Y-%m-%d %H:%M:%S')} geolocation: {message}",
        flush=True,
    )


def parse_number(raw: str, name: str) -> float:
    try:
        value = float(raw.strip())
    except (AttributeError, ValueError) as exc:
        raise GeolocationError(f"{name} must be a number; got {raw!r}") from exc
    if not math.isfinite(value):
        raise GeolocationError(f"{name} must be finite; got {raw!r}")
    return value


def parse_location(values: list[str]) -> dict[str, Any]:
    if not values:
        raise GeolocationError("provide LAT LNG or a quoted 'LAT,LNG' coordinate")

    if "," in values[0]:
        coordinate_parts = [part.strip() for part in values[0].split(",")]
        if len(coordinate_parts) != 2 or not all(coordinate_parts):
            raise GeolocationError("coordinates must use the form 'LAT,LNG'")
        latitude_raw, longitude_raw = coordinate_parts
        accuracy_raw = values[1] if len(values) > 1 else "20"
        if len(values) > 2:
            raise GeolocationError("too many values after the 'LAT,LNG' coordinate")
    else:
        if len(values) not in (2, 3):
            raise GeolocationError("provide LAT LNG followed by optional ACCURACY_METERS")
        latitude_raw, longitude_raw = values[:2]
        accuracy_raw = values[2] if len(values) == 3 else "20"

    latitude = parse_number(latitude_raw, "latitude")
    longitude = parse_number(longitude_raw, "longitude")
    accuracy = parse_number(accuracy_raw, "accuracy")

    if not -90 <= latitude <= 90:
        raise GeolocationError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise GeolocationError("longitude must be between -180 and 180")
    if accuracy < 0:
        raise GeolocationError("accuracy must be zero or greater")

    return validate_config(
        {
        "enabled": True,
        "latitude": latitude,
        "longitude": longitude,
        "accuracy": accuracy,
        }
    )


def optional_number(
    raw: dict[str, Any], key: str, *, minimum: float | None = None
) -> float | None:
    value = raw.get(key)
    if value is None:
        return None
    number = parse_number(str(value), key.replace("_", " "))
    if minimum is not None and number < minimum:
        raise GeolocationError(f"{key.replace('_', ' ')} must be {minimum} or greater")
    return number


def validate_config(raw: dict[str, Any]) -> dict[str, Any]:
    """Validate the persisted/API representation and return normalized values."""
    if not isinstance(raw, dict) or not isinstance(raw.get("enabled"), bool):
        raise GeolocationError("location config must contain an 'enabled' boolean")
    if not raw["enabled"]:
        return {"enabled": False}

    latitude = parse_number(str(raw.get("latitude", "")), "latitude")
    longitude = parse_number(str(raw.get("longitude", "")), "longitude")
    accuracy = parse_number(str(raw.get("accuracy", 20)), "accuracy")
    if not -90 <= latitude <= 90:
        raise GeolocationError("latitude must be between -90 and 90")
    if not -180 <= longitude <= 180:
        raise GeolocationError("longitude must be between -180 and 180")
    if accuracy < 0:
        raise GeolocationError("accuracy must be zero or greater")

    normalized: dict[str, Any] = {
        "enabled": True,
        "latitude": latitude,
        "longitude": longitude,
        "accuracy": accuracy,
    }
    for key, minimum in (
        ("altitude", None),
        ("altitude_accuracy", 0),
        ("heading", 0),
        ("speed", 0),
    ):
        value = optional_number(raw, key, minimum=minimum)
        if value is not None:
            normalized[key] = value

    if normalized.get("heading", 0) >= 360:
        raise GeolocationError("heading must be less than 360 degrees")

    timezone_name = raw.get("timezone")
    if timezone_name is not None:
        if not isinstance(timezone_name, str) or not timezone_name.strip():
            raise GeolocationError("timezone must be a non-empty IANA timezone name")
        timezone_name = timezone_name.strip()
        try:
            ZoneInfo(timezone_name)
        except ZoneInfoNotFoundError as exc:
            raise GeolocationError(
                f"timezone must be a valid IANA name; got {timezone_name!r}"
            ) from exc
        normalized["timezone"] = timezone_name

    return normalized


def write_config(config: dict[str, Any]) -> None:
    CONFIG_PATH.parent.mkdir(parents=True, exist_ok=True)
    temporary_path = CONFIG_PATH.with_suffix(CONFIG_PATH.suffix + ".tmp")
    temporary_path.write_text(
        json.dumps(config, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary_path.replace(CONFIG_PATH)


def read_config() -> dict[str, Any] | None:
    try:
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError) as exc:
        raise GeolocationError(f"cannot read {CONFIG_PATH}: {exc}") from exc

    try:
        return validate_config(raw)
    except GeolocationError as exc:
        raise GeolocationError(f"invalid {CONFIG_PATH}: {exc}") from exc


def config_fingerprint(config: dict[str, Any] | None) -> tuple[Any, ...]:
    if config is None:
        return ("unconfigured",)
    if not config["enabled"]:
        return ("disabled",)
    return ("enabled", json.dumps(config, sort_keys=True, separators=(",", ":")))


def write_status(status: dict[str, Any]) -> None:
    STATUS_PATH.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        **status,
        "updated_at": datetime.now(timezone.utc).isoformat(),
    }
    temporary_path = STATUS_PATH.with_suffix(STATUS_PATH.suffix + ".tmp")
    temporary_path.write_text(
        json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    temporary_path.replace(STATUS_PATH)


def fetch_json(path: str) -> Any:
    request = urllib.request.Request(
        f"{CDP_HTTP_BASE}{path}", headers={"Cache-Control": "no-cache"}
    )
    with urllib.request.urlopen(request, timeout=2) as response:
        return json.load(response)


async def cdp_call(url: str, method: str, params: dict[str, Any] | None = None) -> Any:
    async with websockets.connect(
        url,
        open_timeout=2,
        close_timeout=1,
        max_size=2**20,
    ) as connection:
        return await cdp_call_on_connection(connection, method, params)


async def cdp_call_on_connection(
    connection: Any, method: str, params: dict[str, Any] | None = None
) -> Any:
    request_id = next(CDP_REQUEST_IDS)
    await connection.send(
        json.dumps(
            {
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        )
    )
    while True:
        response = json.loads(await asyncio.wait_for(connection.recv(), timeout=3))
        if response.get("id") != request_id:
            continue
        if "error" in response:
            detail = response["error"].get("message", str(response["error"]))
            raise RuntimeError(f"CDP {method} failed: {detail}")
        return response.get("result")


async def set_browser_permission(config: dict[str, Any]) -> None:
    browser_url = fetch_json("/json/version")["webSocketDebuggerUrl"]
    if config["enabled"]:
        await cdp_call(
            browser_url,
            "Browser.grantPermissions",
            {"permissions": ["geolocation"]},
        )
    else:
        await cdp_call(browser_url, "Browser.resetPermissions")


def target_origin(target: dict[str, Any]) -> str | None:
    parsed = urllib.parse.urlsplit(target.get("url", ""))
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        return None
    return f"{parsed.scheme}://{parsed.netloc}"


async def grant_origin_permission(origin: str) -> None:
    browser_url = fetch_json("/json/version")["webSocketDebuggerUrl"]
    await cdp_call(
        browser_url,
        "Browser.setPermission",
        {
            "permission": {"name": "geolocation"},
            "setting": "granted",
            "origin": origin,
        },
    )


async def apply_to_target(connection: Any, config: dict[str, Any]) -> None:
    if config["enabled"]:
        geolocation_params = {
            "latitude": config["latitude"],
            "longitude": config["longitude"],
            "accuracy": config["accuracy"],
        }
        for config_key, cdp_key in (
            ("altitude", "altitude"),
            ("altitude_accuracy", "altitudeAccuracy"),
            ("heading", "heading"),
            ("speed", "speed"),
        ):
            if config_key in config:
                geolocation_params[cdp_key] = config[config_key]
        await cdp_call_on_connection(
            connection,
            "Emulation.setGeolocationOverride",
            geolocation_params,
        )
        await cdp_call_on_connection(
            connection,
            "Emulation.setTimezoneOverride",
            {"timezoneId": config.get("timezone", "")},
        )
    else:
        await cdp_call_on_connection(
            connection,
            "Emulation.clearGeolocationOverride",
        )
        await cdp_call_on_connection(
            connection,
            "Emulation.setTimezoneOverride",
            {"timezoneId": ""},
        )


def page_targets() -> list[dict[str, Any]]:
    targets = fetch_json("/json/list")
    return [
        target
        for target in targets
        if target.get("type") == "page" and target.get("webSocketDebuggerUrl")
    ]


async def watch() -> None:
    active_fingerprint: tuple[Any, ...] | None = None
    permission_fingerprint: tuple[Any, ...] | None = None
    applied_targets: dict[str, tuple[Any, ...]] = {}
    last_error: str | None = None
    last_status_fingerprint: str | None = None
    config: dict[str, Any] | None = None
    target_connections: dict[str, tuple[str, Any]] = {}

    async def close_target_connections(target_ids: set[str] | None = None) -> None:
        ids = target_ids if target_ids is not None else set(target_connections)
        for target_id in ids:
            item = target_connections.pop(target_id, None)
            if item is not None:
                try:
                    await item[1].close()
                except Exception:
                    pass

    while True:
        try:
            config = read_config()
            fingerprint = config_fingerprint(config)

            # With no config, leave the browser's native behavior untouched.
            if config is None:
                active_fingerprint = fingerprint
                permission_fingerprint = fingerprint
                applied_targets.clear()
                await close_target_connections()
                status = {
                    "service": "ready",
                    "browser_connected": False,
                    "configured": False,
                    "enabled": False,
                    "page_targets": 0,
                    "applied_targets": 0,
                    "last_error": None,
                }
                status_fingerprint = json.dumps(status, sort_keys=True)
                if status_fingerprint != last_status_fingerprint:
                    write_status(status)
                    last_status_fingerprint = status_fingerprint
                await asyncio.sleep(POLL_SECONDS)
                continue

            if fingerprint != active_fingerprint:
                applied_targets.clear()
                active_fingerprint = fingerprint
                if config["enabled"]:
                    log(
                        "loaded "
                        f"{config['latitude']}, {config['longitude']} "
                        f"(accuracy {config['accuracy']} m"
                        + (
                            f", timezone {config['timezone']})"
                            if config.get("timezone")
                            else ")"
                        )
                    )
                else:
                    log("override disabled")

            if fingerprint != permission_fingerprint:
                await set_browser_permission(config)
                permission_fingerprint = fingerprint

            targets = page_targets()
            current_target_ids = {target["id"] for target in targets}
            await close_target_connections(set(target_connections) - current_target_ids)
            applied_targets = {
                target_id: value
                for target_id, value in applied_targets.items()
                if target_id in current_target_ids
            }

            for target in targets:
                origin = target_origin(target)
                target_fingerprint = (*fingerprint, origin)
                if applied_targets.get(target["id"]) == target_fingerprint:
                    continue
                if config["enabled"] and origin:
                    await grant_origin_permission(origin)
                connection_item = target_connections.get(target["id"])
                if (
                    connection_item is None
                    or connection_item[0] != target["webSocketDebuggerUrl"]
                ):
                    if connection_item is not None:
                        await close_target_connections({target["id"]})
                    connection = await websockets.connect(
                        target["webSocketDebuggerUrl"],
                        open_timeout=2,
                        close_timeout=1,
                        max_size=2**20,
                    )
                    target_connections[target["id"]] = (
                        target["webSocketDebuggerUrl"],
                        connection,
                    )
                else:
                    connection = connection_item[1]
                await apply_to_target(connection, config)
                applied_targets[target["id"]] = target_fingerprint
                if config["enabled"]:
                    log(
                        f"applied override to page {target['id']}"
                        + (f" ({origin})" if origin else "")
                    )

            if not config["enabled"]:
                await close_target_connections()

            last_error = None
            status = {
                "service": "ready",
                "browser_connected": True,
                "configured": True,
                "enabled": config["enabled"],
                "page_targets": len(targets),
                "applied_targets": len(applied_targets),
                "last_error": None,
            }
            status_fingerprint = json.dumps(status, sort_keys=True)
            if status_fingerprint != last_status_fingerprint:
                write_status(status)
                last_status_fingerprint = status_fingerprint
        except (
            GeolocationError,
            KeyError,
            OSError,
            RuntimeError,
            asyncio.TimeoutError,
            urllib.error.URLError,
            websockets.exceptions.WebSocketException,
        ) as exc:
            error = str(exc)
            if error != last_error:
                log(f"waiting to retry after error: {error}")
                last_error = error
            # Force permission and target updates to retry after Chrome reconnects.
            permission_fingerprint = None
            applied_targets.clear()
            await close_target_connections()
            status = {
                "service": "degraded",
                "browser_connected": False,
                "configured": config is not None,
                "enabled": bool((config or {}).get("enabled", False)),
                "page_targets": 0,
                "applied_targets": 0,
                "last_error": error,
            }
            status_fingerprint = json.dumps(status, sort_keys=True)
            if status_fingerprint != last_status_fingerprint:
                write_status(status)
                last_status_fingerprint = status_fingerprint

        await asyncio.sleep(POLL_SECONDS)


def show_config() -> int:
    config = read_config()
    if config is None:
        print("Location override: not configured (browser uses its native location)")
    elif config["enabled"]:
        print("Location override: enabled")
        print(f"Coordinates:       {config['latitude']}, {config['longitude']}")
        print(f"Accuracy:          {config['accuracy']} meters")
        if config.get("timezone"):
            print(f"Timezone:          {config['timezone']}")
    else:
        print("Location override: disabled (browser uses its native location)")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    set_parser = subparsers.add_parser("set", help="set and enable an override")
    set_parser.add_argument(
        "values",
        nargs="+",
        metavar="VALUE",
        help="LAT LNG [ACCURACY] or a quoted LAT,LNG [ACCURACY]",
    )
    subparsers.add_parser("clear", help="disable and clear the override")
    subparsers.add_parser("show", help="show the saved override")
    subparsers.add_parser("watch", help="watch config and apply it through CDP")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "set":
            config = parse_location(args.values)
            write_config(config)
            return show_config()
        if args.command == "clear":
            write_config({"enabled": False})
            return show_config()
        if args.command == "show":
            return show_config()
        asyncio.run(watch())
        return 0
    except GeolocationError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 2
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
