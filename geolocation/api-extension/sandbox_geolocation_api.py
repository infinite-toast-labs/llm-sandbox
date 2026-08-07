"""FastAPI routes for the sandbox-local Chromium geolocation override."""

from __future__ import annotations

import json
import pathlib
from typing import Any, Literal

from fastapi import APIRouter, HTTPException, status
from fastapi.responses import FileResponse
from pydantic import BaseModel, ConfigDict, Field

from geolocation import (
    CONFIG_PATH,
    STATUS_PATH,
    GeolocationError,
    read_config,
    validate_config,
    write_config,
)


ASSET_DIR = pathlib.Path(__file__).with_name("ui")
router = APIRouter(tags=["geolocation"])


PRESETS: dict[str, dict[str, Any]] = {
    "chicago": {
        "label": "Chicago",
        "latitude": 41.8781,
        "longitude": -87.6298,
        "timezone": "America/Chicago",
    },
    "new-york": {
        "label": "New York",
        "latitude": 40.7128,
        "longitude": -74.006,
        "timezone": "America/New_York",
    },
    "san-francisco": {
        "label": "San Francisco",
        "latitude": 37.7749,
        "longitude": -122.4194,
        "timezone": "America/Los_Angeles",
    },
    "london": {
        "label": "London",
        "latitude": 51.5072,
        "longitude": -0.1276,
        "timezone": "Europe/London",
    },
    "tokyo": {
        "label": "Tokyo",
        "latitude": 35.6762,
        "longitude": 139.6503,
        "timezone": "Asia/Tokyo",
    },
    "sydney": {
        "label": "Sydney",
        "latitude": -33.8688,
        "longitude": 151.2093,
        "timezone": "Australia/Sydney",
    },
}


class LocationInput(BaseModel):
    model_config = ConfigDict(extra="forbid")

    latitude: float = Field(ge=-90, le=90, examples=[35.906275])
    longitude: float = Field(ge=-180, le=180, examples=[-115.076392])
    accuracy: float = Field(default=20, ge=0, description="Accuracy radius in meters")
    altitude: float | None = Field(default=None, description="Meters above sea level")
    altitude_accuracy: float | None = Field(default=None, ge=0)
    heading: float | None = Field(default=None, ge=0, lt=360, description="Degrees clockwise from true north")
    speed: float | None = Field(default=None, ge=0, description="Meters per second")
    timezone: str | None = Field(default=None, examples=["America/Chicago"], description="Optional IANA timezone override")


class LocationPatch(BaseModel):
    model_config = ConfigDict(extra="forbid")

    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    accuracy: float | None = Field(default=None, ge=0)
    altitude: float | None = None
    altitude_accuracy: float | None = Field(default=None, ge=0)
    heading: float | None = Field(default=None, ge=0, lt=360)
    speed: float | None = Field(default=None, ge=0)
    timezone: str | None = None


class RuntimeState(BaseModel):
    service: str
    browser_connected: bool
    configured: bool
    enabled: bool
    page_targets: int
    applied_targets: int
    last_error: str | None = None
    updated_at: str | None = None


class LocationState(BaseModel):
    scope: Literal["sandbox_chromium_only"] = "sandbox_chromium_only"
    enabled: bool
    pending: bool = Field(description="True while the watcher is applying the saved state")
    location: LocationInput | None
    runtime: RuntimeState
    links: dict[str, str]


class Preset(BaseModel):
    id: str
    label: str
    latitude: float
    longitude: float
    timezone: str


class ValidationResult(BaseModel):
    valid: Literal[True] = True
    normalized: LocationInput


class HealthResponse(BaseModel):
    status: Literal["healthy", "degraded", "unconfigured"]
    browser_connected: bool
    override_enabled: bool
    last_error: str | None = None


def runtime_state() -> RuntimeState:
    try:
        raw = json.loads(STATUS_PATH.read_text(encoding="utf-8"))
        return RuntimeState.model_validate(raw)
    except (FileNotFoundError, OSError, json.JSONDecodeError, ValueError):
        return RuntimeState(
            service="starting",
            browser_connected=False,
            configured=CONFIG_PATH.exists(),
            enabled=False,
            page_targets=0,
            applied_targets=0,
        )


def current_state() -> LocationState:
    try:
        config = read_config()
    except GeolocationError as exc:
        raise HTTPException(status_code=500, detail=str(exc)) from exc
    enabled = bool(config and config.get("enabled"))
    runtime = runtime_state()
    location = None
    if enabled and config is not None:
        location = LocationInput.model_validate(
            {key: value for key, value in config.items() if key != "enabled"}
        )
    return LocationState(
        enabled=enabled,
        pending=(runtime.enabled != enabled or (config is not None and not runtime.configured)),
        location=location,
        runtime=runtime,
        links={
            "self": "/v1/geolocation",
            "ui": "/v1/geolocation/ui",
            "capabilities": "/v1/geolocation/capabilities",
            "presets": "/v1/geolocation/presets",
            "openapi": "/v1/openapi.json",
            "docs": "/v1/docs#/geolocation",
        },
    )


def save_location(payload: LocationInput) -> LocationState:
    try:
        normalized = validate_config({"enabled": True, **payload.model_dump(exclude_none=True)})
        write_config(normalized)
    except GeolocationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return current_state()


@router.get("", response_model=LocationState, operation_id="get_geolocation")
async def get_location() -> LocationState:
    """Return saved coordinates plus live browser-application status."""
    return current_state()


@router.put("", response_model=LocationState, operation_id="set_geolocation")
async def set_location(payload: LocationInput) -> LocationState:
    """Replace and enable the sandbox Chromium geolocation override."""
    return save_location(payload)


@router.patch("", response_model=LocationState, operation_id="patch_geolocation")
async def patch_location(payload: LocationPatch) -> LocationState:
    """Change selected fields without resending the entire location."""
    existing = read_config()
    if not existing or not existing.get("enabled"):
        raise HTTPException(
            status_code=status.HTTP_409_CONFLICT,
            detail="No enabled location exists; use PUT with latitude and longitude first.",
        )
    updates = payload.model_dump(exclude_unset=True)
    if updates.get("latitude", 0) is None or updates.get("longitude", 0) is None:
        raise HTTPException(status_code=422, detail="latitude and longitude cannot be null")
    merged = {**existing, **updates}
    for key, value in list(merged.items()):
        if value is None and key not in {"latitude", "longitude", "accuracy"}:
            merged.pop(key)
    try:
        write_config(validate_config(merged))
    except GeolocationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return current_state()


@router.delete("", response_model=LocationState, operation_id="clear_geolocation")
async def clear_location() -> LocationState:
    """Disable all overrides and restore the sandbox browser's native behavior."""
    write_config({"enabled": False})
    return current_state()


@router.post("/reset", response_model=LocationState, operation_id="reset_geolocation")
async def reset_location() -> LocationState:
    """Explicit action-style alias for DELETE /v1/geolocation."""
    return await clear_location()


@router.post("/validate", response_model=ValidationResult, operation_id="validate_geolocation")
async def validate_location(payload: LocationInput) -> ValidationResult:
    """Validate and normalize a location without changing browser state."""
    try:
        normalized = validate_config({"enabled": True, **payload.model_dump(exclude_none=True)})
    except GeolocationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
    return ValidationResult(
        normalized=LocationInput.model_validate(
            {key: value for key, value in normalized.items() if key != "enabled"}
        )
    )


@router.get("/health", response_model=HealthResponse, operation_id="geolocation_health")
async def health() -> HealthResponse:
    """Check whether the watcher can reach Chromium and apply the override."""
    runtime = runtime_state()
    if runtime.browser_connected:
        health_status = "healthy"
    elif not runtime.configured:
        health_status = "unconfigured"
    else:
        health_status = "degraded"
    return HealthResponse(
        status=health_status,
        browser_connected=runtime.browser_connected,
        override_enabled=runtime.enabled,
        last_error=runtime.last_error,
    )


@router.get("/capabilities", operation_id="get_geolocation_capabilities")
async def capabilities() -> dict[str, Any]:
    """Discover supported fields, semantics, limits, and related endpoints."""
    return {
        "scope": "sandbox_chromium_only",
        "hot_reload": True,
        "persists_across_container_stop_start": True,
        "new_tabs_automatically_inherit": True,
        "apply_latency_seconds": {"typical": 0.5, "upper_bound": 1.5},
        "coordinate_system": "WGS84 decimal degrees (Google Maps style)",
        "fields": {
            "latitude": {"required": True, "minimum": -90, "maximum": 90},
            "longitude": {"required": True, "minimum": -180, "maximum": 180},
            "accuracy": {"default": 20, "minimum": 0, "unit": "meters"},
            "altitude": {"required": False, "unit": "meters"},
            "altitude_accuracy": {"required": False, "minimum": 0, "unit": "meters"},
            "heading": {"required": False, "minimum": 0, "exclusive_maximum": 360, "unit": "degrees"},
            "speed": {"required": False, "minimum": 0, "unit": "meters_per_second"},
            "timezone": {"required": False, "format": "IANA timezone name"},
        },
        "operations": {
            "read": "GET /v1/geolocation",
            "replace": "PUT /v1/geolocation",
            "partial_update": "PATCH /v1/geolocation",
            "clear": "DELETE /v1/geolocation",
            "reset_alias": "POST /v1/geolocation/reset",
            "validate_without_apply": "POST /v1/geolocation/validate",
            "health": "GET /v1/geolocation/health",
            "presets": "GET /v1/geolocation/presets",
            "apply_preset": "POST /v1/geolocation/presets/{preset_id}",
            "web_ui": "GET /v1/geolocation/ui",
        },
    }


@router.get("/presets", response_model=list[Preset], operation_id="list_geolocation_presets")
async def list_presets() -> list[Preset]:
    """List deterministic sample locations with matching timezones."""
    return [Preset(id=preset_id, **preset) for preset_id, preset in PRESETS.items()]


@router.post("/presets/{preset_id}", response_model=LocationState, operation_id="apply_geolocation_preset")
async def apply_preset(preset_id: str) -> LocationState:
    """Apply a named deterministic location preset."""
    preset = PRESETS.get(preset_id)
    if preset is None:
        raise HTTPException(status_code=404, detail=f"Unknown preset: {preset_id}")
    return save_location(
        LocationInput.model_validate(
            {key: value for key, value in preset.items() if key != "label"}
        )
    )


@router.get(
    "/ui",
    response_class=FileResponse,
    operation_id="open_geolocation_ui",
    summary="Geolocation management UI",
)
async def ui() -> FileResponse:
    return FileResponse(ASSET_DIR / "index.html", media_type="text/html")


@router.get("/ui/styles.css", include_in_schema=False)
async def ui_styles() -> FileResponse:
    return FileResponse(ASSET_DIR / "styles.css", media_type="text/css")


@router.get("/ui/app.js", include_in_schema=False)
async def ui_script() -> FileResponse:
    return FileResponse(ASSET_DIR / "app.js", media_type="application/javascript")
