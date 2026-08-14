# llm sandbox

## Android Pixel 9 Pro in the browser

The sibling `joystick-base` Android emulator is available as a direct,
human-facing browser UI at:

```text
http://localhost:8080/emulator/
```

Start the sandbox, Android phone, authenticated emulator gRPC endpoint, and
browser stream gateway together with:

```bash
make emulator-web-up
```

The page reconnects automatically and provides responsive Back, Home, Recents,
Power, and volume controls. Its display accepts keyboard/mouse input and native
browser pointer events, including concurrent contacts on phones and tablets. Use
the sandbox's HTTPS/Tailscale address with `/emulator/` when connecting from a
phone; mobile browsers restrict several fullscreen and media capabilities on
plain HTTP origins other than localhost.

For a near-native presentation on the target Pixel 9 Pro, open the HTTPS route
in Chrome, expand **More**, choose **Install app**, and launch **Joystick Base**
from the home screen. The installed PWA runs without Chrome's address and tab
bars, while the existing lower Back/Home/Recents controls remain visible. The
emulator uses the same 20:9, 1280 × 2856 display geometry as the physical phone,
eliminating the large aspect-ratio bars caused by the former tablet profile.

Useful lifecycle and diagnostic commands are:

```bash
make emulator-web-status
make emulator-web-verify
make emulator-web-logs
make emulator-web-restart
make emulator-web-stop       # leaves Android running
```

`JOYSTICK_BASE_DIR` defaults to `../joystick-base` and can be overridden for a
different checkout. The browser path is reverse-proxied through the existing
sandbox nginx service, while the host gateway remains bound to macOS loopback.
The emulator's native gRPC endpoint uses its per-process bearer token; that
token never reaches the browser or the nginx container.

This route has the same network trust boundary as the existing sandbox VNC UI:
anyone who can reach the sandbox ingress can operate the Android phone. Do not
publish port 8080 directly to an untrusted network. Prefer Tailscale HTTPS or put
an authenticated reverse proxy in front of the entire sandbox.

## Browser location override

The Chromium instance visible through the sandbox VNC page supports a
hot-reloadable geolocation override. Set either a Google Maps-style coordinate
pair or separate latitude/longitude values:

```bash
make location COORDS="35.906275, -115.076392"
# Equivalent:
make location LAT=35.906275 LNG=-115.076392
```

The default reported accuracy is 20 meters. Override it when needed:

```bash
make location COORDS="35.906275, -115.076392" GEOLOCATION_ACCURACY=5
```

The change reaches existing and newly opened sandbox tabs within about one
second. It uses Chrome DevTools Protocol inside the `llm-sandbox` container;
it does not change the macOS host location and does not require a container
restart.

Inspect or clear the override with:

```bash
make location-show
make location-clear
```

The same controls are part of the sandbox's existing versioned API and appear
automatically in its OpenAPI document:

```text
UI:       http://localhost:8080/v1/geolocation/ui
Swagger:  http://localhost:8080/v1/docs#/geolocation
OpenAPI:  http://localhost:8080/v1/openapi.json
```

The UI accepts a complete Google Maps-style coordinate pair in one paste, such
as `35.906275, -115.076392`, and immediately fills the individual latitude and
longitude controls.

Core API operations:

```bash
curl http://localhost:8080/v1/geolocation

curl -X PUT http://localhost:8080/v1/geolocation \
  -H 'Content-Type: application/json' \
  -d '{"latitude":35.906275,"longitude":-115.076392,"accuracy":10}'

curl -X DELETE http://localhost:8080/v1/geolocation
```

`GET /v1/geolocation/capabilities` advertises the complete surface, including
partial updates, validation without applying, health, named presets, optional
altitude/motion fields, and a matching IANA timezone override.

The saved setting lives in the sandbox home volume, so it remains active after
`make stop` followed by `make up`. The normal lifecycle remains:

```bash
make up
make stop
```
