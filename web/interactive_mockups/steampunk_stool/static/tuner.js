// tuner.js -- the parameter-tuning panel logic. Loaded by tuner.html, which
// is used BOTH as the "separate window within the browser tab" mode
// (embedded via <iframe src="tuner.html"> from index.html) AND as the
// "popout window" mode (window.open("tuner.html", ...)) -- Liam's spec asked
// for both as selectable node-wired options, so this is the ONE piece of UI
// + wiring code both contexts load; nothing is duplicated or hardcoded to
// one presentation.
//
// Publishes {param, value, ts} over a plain browser WebSocket straight to
// Wavelet's param_channel ws:// relay (projection/transport/ws_relay_server.py,
// projection/graph/param_channel_node.py, PR #910) -- the wire shape those
// modules already define; this file does not invent a second protocol.

const PARAM_LABELS = {
  seat_radius: "Seat radius",
  seat_thickness: "Seat thickness",
  leg_radius: "Leg pipe radius",
  leg_wall: "Pipe wall thickness",
  leg_bottom_z: "Foot height",
  leg_top_z: "Overall height",
  stretcher_z: "Stretcher ring height",
  leg_spread: "Leg spread",
};

// Sensible slider step per param (mm) -- everything else falls back to 1.
const PARAM_STEP = {
  leg_wall: 0.5,
};

// Same ?live=<base-url> override viewer.js supports (see its own comment) --
// lets a copied-elsewhere tuner.html (e.g. inside a Discord/Aperture artifact
// page, via artifact_pages.py's interactive_3d hook) still find wherever
// server.py actually runs. Default (no param): relative fetch, unchanged.
const LIVE_BASE = (new URLSearchParams(location.search).get("live") || "").replace(/\/+$/, "");
function liveUrl(relPath) {
  return LIVE_BASE ? `${LIVE_BASE}/${relPath}` : relPath;
}

let ws = null;
let wsBackoffMs = 300;
const WS_BACKOFF_MAX_MS = 4000;
let config = null;
let sliderEls = {};
let suppressPublish = false; // true while applying an incoming remote update

function $(id) { return document.getElementById(id); }

function setConnState(state) {
  const dot = $("conn-dot");
  const label = $("conn-label");
  dot.className = "conn-dot " + state;
  label.textContent = { connected: "live", connecting: "connecting…", disconnected: "reconnecting…" }[state] || state;
}

function buildSliders(defaults, ranges) {
  const root = $("params");
  root.innerHTML = "";
  sliderEls = {};
  for (const name of Object.keys(defaults)) {
    const [lo, hi] = ranges[name];
    const step = PARAM_STEP[name] || 1;
    const row = document.createElement("div");
    row.className = "param-row";
    row.innerHTML = `
      <div class="row-head">
        <label for="p-${name}">${PARAM_LABELS[name] || name}</label>
        <span class="val" id="v-${name}">${defaults[name].toFixed(1)} mm</span>
      </div>
      <input type="range" id="p-${name}" min="${lo}" max="${hi}" step="${step}" value="${defaults[name]}">
    `;
    root.appendChild(row);
    const input = row.querySelector("input");
    sliderEls[name] = input;
    input.addEventListener("input", () => onSliderInput(name, input));
  }
}

function onSliderInput(name, input) {
  const value = parseFloat(input.value);
  $("v-" + name).textContent = value.toFixed(1) + " mm";
  if (suppressPublish) return; // this call was triggered by applyRemoteUpdate, not the user
  publish(name, value);
}

function applyRemoteUpdate(name, value) {
  const input = sliderEls[name];
  if (!input) return;
  suppressPublish = true;
  input.value = value;
  $("v-" + name).textContent = Number(value).toFixed(1) + " mm";
  suppressPublish = false;
}

function publish(param, value) {
  if (!ws || ws.readyState !== WebSocket.OPEN) return;
  ws.send(JSON.stringify({ param, value, ts: Date.now() / 1000 }));
}

function connect() {
  if (!config) return;
  setConnState("connecting");
  ws = new WebSocket(config.ws_uri);

  ws.onopen = () => {
    wsBackoffMs = 300;
    setConnState("connected");
  };

  ws.onmessage = (evt) => {
    let msg;
    try {
      msg = JSON.parse(evt.data);
    } catch (e) {
      return;
    }
    if (msg && typeof msg.param === "string" && msg.param in sliderEls) {
      applyRemoteUpdate(msg.param, msg.value);
    }
  };

  ws.onclose = () => {
    setConnState("disconnected");
    setTimeout(connect, wsBackoffMs);
    wsBackoffMs = Math.min(wsBackoffMs * 2, WS_BACKOFF_MAX_MS);
  };

  ws.onerror = () => {
    try { ws.close(); } catch (e) { /* no-op */ }
  };
}

function resetToDefaults() {
  if (!config) return;
  for (const [name, value] of Object.entries(config.defaults)) {
    const input = sliderEls[name];
    if (input) {
      input.value = value;
      $("v-" + name).textContent = Number(value).toFixed(1) + " mm";
    }
    publish(name, value);
  }
}

async function init() {
  $("reset-btn").addEventListener("click", resetToDefaults);
  try {
    const resp = await fetch(liveUrl("generated/config.json"), { cache: "no-store" });
    if (!resp.ok) throw new Error("config fetch failed: " + resp.status);
    config = await resp.json();
  } catch (e) {
    $("offline-note").style.display = "block";
    $("offline-note").textContent =
      "Could not reach the live server (generated/config.json). Run: py server.py — from this page's own directory.";
    return;
  }
  buildSliders(config.defaults, config.ranges);
  connect();
}

init();
