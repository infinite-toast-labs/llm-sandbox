# llm sandbox

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
