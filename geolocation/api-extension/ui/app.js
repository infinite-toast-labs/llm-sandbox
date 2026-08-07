const API = "/v1/geolocation";

const $ = (id) => document.getElementById(id);
const form = $("locationForm");
const feedback = $("feedback");
let presets = [];

function parseCoordinatePair(raw) {
  const normalized = raw.trim().replaceAll("−", "-");
  const parts = normalized.replace(/^\(|\)$/g, "").split(",");
  if (parts.length !== 2 || parts.some((part) => part.trim() === "")) {
    throw new Error("Use latitude, longitude — for example 35.906275, -115.076392");
  }
  const latitude = Number(parts[0].trim());
  const longitude = Number(parts[1].trim());
  if (!Number.isFinite(latitude) || !Number.isFinite(longitude)) {
    throw new Error("Both coordinates must be numbers.");
  }
  if (latitude < -90 || latitude > 90) {
    throw new Error("Latitude must be between −90 and 90.");
  }
  if (longitude < -180 || longitude > 180) {
    throw new Error("Longitude must be between −180 and 180.");
  }
  return { latitude, longitude };
}

function showPairState(type, message) {
  const field = $("coordinatePair").closest(".paste-field");
  field.classList.remove("valid", "invalid");
  if (type) field.classList.add(type);
  $("pairHint").textContent = message;
}

function applyCoordinatePair({ announce = true } = {}) {
  const raw = $("coordinatePair").value;
  if (!raw.trim()) {
    showPairState("", "Paste directly from Google Maps");
    return null;
  }
  try {
    const pair = parseCoordinatePair(raw);
    $("latitude").value = pair.latitude;
    $("longitude").value = pair.longitude;
    showPairState("valid", "Recognized — ready to apply");
    if (announce) setFeedback(`Parsed ${pair.latitude}, ${pair.longitude}.`, "success");
    return pair;
  } catch (error) {
    showPairState("invalid", error.message);
    if (announce) setFeedback(error.message, "error");
    return null;
  }
}

function optionalNumber(id) {
  const value = $(id).value.trim();
  return value === "" ? undefined : Number(value);
}

function setFeedback(message, type = "") {
  feedback.textContent = message;
  feedback.className = `feedback ${type}`;
}

function requestError(payload, fallback) {
  if (typeof payload?.detail === "string") return payload.detail;
  if (Array.isArray(payload?.detail)) return payload.detail.map((item) => item.msg).join("; ");
  return fallback;
}

async function api(path = "", options = {}) {
  const response = await fetch(`${API}${path}`, {
    headers: { "Content-Type": "application/json", ...(options.headers || {}) },
    ...options,
  });
  const payload = await response.json();
  if (!response.ok) throw new Error(requestError(payload, `Request failed (${response.status})`));
  return payload;
}

function updateVisualization(state) {
  const marker = $("marker");
  const location = state.location;
  $("overrideMetric").textContent = state.enabled ? "ACTIVE" : "OFF";
  $("pagesMetric").textContent = `${state.runtime.applied_targets} / ${state.runtime.page_targets}`;

  const statusWrap = document.querySelector(".status-wrap");
  statusWrap.classList.remove("healthy", "error");
  if (state.pending) {
    $("statusText").textContent = "Applying change";
  } else if (state.runtime.browser_connected) {
    statusWrap.classList.add("healthy");
    $("statusText").textContent = state.enabled ? "Override live" : "Browser ready";
  } else if (state.runtime.last_error) {
    statusWrap.classList.add("error");
    $("statusText").textContent = "Service degraded";
  } else {
    $("statusText").textContent = "Waiting for browser";
  }

  if (!state.enabled || !location) {
    marker.classList.remove("active");
    $("coordinateReadout").textContent = "NO OVERRIDE";
    return;
  }

  marker.style.setProperty("--x", `${((location.longitude + 180) / 360) * 100}%`);
  marker.style.setProperty("--y", `${((90 - location.latitude) / 180) * 100}%`);
  marker.classList.add("active");
  $("coordinateReadout").textContent = `${location.latitude.toFixed(4)}, ${location.longitude.toFixed(4)}`;
}

function fillForm(location) {
  if (!location) return;
  for (const key of ["latitude", "longitude", "accuracy", "altitude", "heading", "speed", "timezone"]) {
    $(key).value = location[key] ?? "";
  }
  $("coordinatePair").value = `${location.latitude}, ${location.longitude}`;
  showPairState("valid", "Recognized — ready to apply");
}

function updateCurl(payload) {
  const compact = JSON.stringify(payload);
  $("curlExample").textContent = `curl -X PUT http://localhost:8080/v1/geolocation \\\n+  -H 'Content-Type: application/json' \\\n+  -d '${compact}'`;
}

async function refresh({ fill = false } = {}) {
  const state = await api();
  updateVisualization(state);
  if (fill && state.location) fillForm(state.location);
  return state;
}

async function loadPresets() {
  presets = await api("/presets");
  const select = $("preset");
  for (const preset of presets) {
    const option = document.createElement("option");
    option.value = preset.id;
    option.textContent = `${preset.label} · ${preset.latitude}, ${preset.longitude}`;
    select.append(option);
  }
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  if ($("coordinatePair").value.trim() && !applyCoordinatePair({ announce: false })) {
    setFeedback($("pairHint").textContent, "error");
    $("coordinatePair").focus();
    return;
  }
  const payload = {
    latitude: Number($("latitude").value),
    longitude: Number($("longitude").value),
    accuracy: optionalNumber("accuracy") ?? 20,
    altitude: optionalNumber("altitude"),
    heading: optionalNumber("heading"),
    speed: optionalNumber("speed"),
    timezone: $("timezone").value.trim() || undefined,
  };
  Object.keys(payload).forEach((key) => payload[key] === undefined && delete payload[key]);
  try {
    setFeedback("Applying to sandbox Chromium…");
    const state = await api("", { method: "PUT", body: JSON.stringify(payload) });
    updateCurl(payload);
    updateVisualization(state);
    setFeedback("Saved. Open tabs will receive the location within about one second.", "success");
    setTimeout(() => refresh(), 700);
  } catch (error) {
    setFeedback(error.message, "error");
  }
});

$("coordinatePair").addEventListener("input", () => applyCoordinatePair({ announce: false }));
$("coordinatePair").addEventListener("paste", () => {
  window.setTimeout(() => applyCoordinatePair(), 0);
});

for (const id of ["latitude", "longitude"]) {
  $(id).addEventListener("change", () => {
    const latitude = Number($("latitude").value);
    const longitude = Number($("longitude").value);
    if (Number.isFinite(latitude) && Number.isFinite(longitude)) {
      $("coordinatePair").value = `${latitude}, ${longitude}`;
      showPairState("valid", "Recognized — ready to apply");
    }
  });
}

$("applyPreset").addEventListener("click", () => {
  const preset = presets.find((item) => item.id === $("preset").value);
  if (!preset) {
    setFeedback("Choose a preset first.", "error");
    return;
  }
  fillForm({ ...preset, accuracy: 20 });
  setFeedback(`${preset.label} loaded. Press Apply location to activate it.`);
});

$("resetButton").addEventListener("click", async () => {
  try {
    setFeedback("Clearing override…");
    const state = await api("", { method: "DELETE" });
    updateVisualization(state);
    setFeedback("Override cleared. Chromium is back to native location behavior.", "success");
    setTimeout(() => refresh(), 700);
  } catch (error) {
    setFeedback(error.message, "error");
  }
});

Promise.all([loadPresets(), refresh({ fill: true })])
  .then(() => setFeedback("Ready."))
  .catch((error) => {
    document.querySelector(".status-wrap").classList.add("error");
    $("statusText").textContent = "API unavailable";
    setFeedback(error.message, "error");
  });

setInterval(() => refresh().catch(() => {}), 2500);
