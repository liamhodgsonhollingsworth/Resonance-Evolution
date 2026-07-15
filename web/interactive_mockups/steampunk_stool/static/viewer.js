// viewer.js -- the 3D "demo window": orbit/pan/zoom around the artifact,
// click-to-inspect individual parts, and live-reload the model whenever
// server.py's regen loop (draining the real param_channel ws:// substrate)
// produces a new .glb. Two selectable "separate window" modes for the
// tuning panel per Liam's spec (msg 1526751917060128809): an embedded
// docked panel (a genuinely separate <iframe> document within this tab) or
// a real window.open() popout -- both point at the exact same tuner.html /
// param_channel wiring, selected via one dropdown ("node-based option"),
// never hardcoded to one.

import * as THREE from "https://unpkg.com/three@0.160.0/build/three.module.js";
import { OrbitControls } from "https://unpkg.com/three@0.160.0/examples/jsm/controls/OrbitControls.js";
import { GLTFLoader } from "https://unpkg.com/three@0.160.0/examples/jsm/loaders/GLTFLoader.js";

const PART_LABELS = {
  seat: "Seat (reclaimed wood)",
  leg: "Leg (black pipe)",
  foot: "Bent foot",
  tee: "Tee junction",
  stretch: "Stretcher pipe",
  flange: "Floor flange",
};

function friendlyPartName(name) {
  const m = name.match(/^([a-z]+)(\d*)$/i);
  if (!m) return name;
  const [, base, idx] = m;
  const label = PART_LABELS[base] || base;
  return idx ? `${label} ${parseInt(idx, 10) + 1}` : label;
}

// ---- scene setup -----------------------------------------------------------

const viewport = document.getElementById("viewport");
const scene = new THREE.Scene();
scene.background = new THREE.Color(0x16130f);
scene.fog = new THREE.Fog(0x16130f, 1400, 4200);

const camera = new THREE.PerspectiveCamera(45, window.innerWidth / window.innerHeight, 1, 8000);
camera.position.set(560, 420, 700);

const renderer = new THREE.WebGLRenderer({ antialias: true });
renderer.setPixelRatio(Math.min(window.devicePixelRatio, 2));
renderer.setSize(window.innerWidth, window.innerHeight);
renderer.shadowMap.enabled = true;
viewport.appendChild(renderer.domElement);

const controls = new OrbitControls(camera, renderer.domElement);
controls.target.set(0, 220, 0);
controls.enableDamping = true;
controls.dampingFactor = 0.08;
controls.minDistance = 120;
controls.maxDistance = 3000;
controls.update();

scene.add(new THREE.HemisphereLight(0xfff2df, 0x1a140c, 0.65));
const key = new THREE.DirectionalLight(0xffe6bf, 1.1);
key.position.set(500, 800, 400);
key.castShadow = true;
scene.add(key);
const rim = new THREE.DirectionalLight(0x8fb3ff, 0.35);
rim.position.set(-600, 300, -400);
scene.add(rim);

const grid = new THREE.GridHelper(2000, 40, 0x4a3d2b, 0x2a231a);
scene.add(grid);

// ---- model loading / live reload -------------------------------------------

const loader = new GLTFLoader();
let modelGroup = null;
let cameraFitted = false;
const selectableMeshes = [];
const originalEmissive = new Map();

function fitCameraToObject(obj) {
  const box = new THREE.Box3().setFromObject(obj);
  const size = box.getSize(new THREE.Vector3());
  const center = box.getCenter(new THREE.Vector3());
  controls.target.copy(center);
  const maxDim = Math.max(size.x, size.y, size.z);
  const dist = maxDim * 1.7;
  camera.position.set(center.x + dist * 0.65, center.y + dist * 0.5, center.z + dist * 0.75);
  camera.near = Math.max(1, dist / 200);
  camera.far = dist * 20;
  camera.updateProjectionMatrix();
  controls.update();
}

async function loadModel(url) {
  const gltf = await loader.loadAsync(url);
  const next = gltf.scene;
  // The canonical proc3d exporter (Alethea-cc/tools/proc3d/glb_export.py,
  // PR #934) writes POSITION-only geometry (no NORMAL accessor -- see its
  // own module docstring) and does not bake a Z-up -> Y-up conversion (proc3d
  // authors everything Z-up; glTF/three.js convention is Y-up). Both are
  // handled HERE on the consuming side rather than by carrying a forked
  // exporter: compute smooth normals per mesh, and rotate the whole loaded
  // group -90deg about X once.
  next.rotation.x = -Math.PI / 2;
  next.traverse((child) => {
    if (child.isMesh) {
      if (!child.geometry.attributes.normal) child.geometry.computeVertexNormals();
      child.castShadow = true;
      child.receiveShadow = true;
    }
  });
  if (modelGroup) scene.remove(modelGroup);
  selectableMeshes.length = 0;
  next.traverse((child) => { if (child.isMesh) selectableMeshes.push(child); });
  modelGroup = next;
  scene.add(modelGroup);
  if (!cameraFitted) {
    fitCameraToObject(modelGroup);
    cameraFitted = true;
  }
  return modelGroup;
}

// ---- interaction: click a part to inspect it -------------------------------

const raycaster = new THREE.Raycaster();
const pointerNdc = new THREE.Vector2();
let selected = null;
const label = document.getElementById("part-label");

function clearSelection() {
  if (selected && originalEmissive.has(selected)) {
    selected.material.emissive.copy(originalEmissive.get(selected));
  }
  selected = null;
  label.style.display = "none";
}

function selectMesh(mesh, screenX, screenY) {
  clearSelection();
  selected = mesh;
  if (mesh.material && mesh.material.emissive) {
    if (!originalEmissive.has(mesh)) originalEmissive.set(mesh, mesh.material.emissive.clone());
    mesh.material.emissive.set(0x8a5a1e);
  }
  label.textContent = friendlyPartName(mesh.name || "part");
  label.style.left = screenX + 14 + "px";
  label.style.top = screenY + 8 + "px";
  label.style.display = "block";
}

renderer.domElement.addEventListener("pointerdown", (evt) => {
  const rect = renderer.domElement.getBoundingClientRect();
  pointerNdc.x = ((evt.clientX - rect.left) / rect.width) * 2 - 1;
  pointerNdc.y = -((evt.clientY - rect.top) / rect.height) * 2 + 1;
  raycaster.setFromCamera(pointerNdc, camera);
  const hits = raycaster.intersectObjects(selectableMeshes, false);
  if (hits.length > 0) {
    selectMesh(hits[0].object, evt.clientX, evt.clientY);
  } else {
    clearSelection();
  }
});

// ---- toolbar: wireframe / auto-rotate / reset camera -----------------------

document.getElementById("wireframe-btn").addEventListener("click", (evt) => {
  const on = evt.target.classList.toggle("active");
  scene.traverse((child) => {
    if (child.isMesh) child.material.wireframe = on;
  });
});

document.getElementById("rotate-btn").addEventListener("click", (evt) => {
  controls.autoRotate = evt.target.classList.toggle("active");
  controls.autoRotateSpeed = 1.6;
});

document.getElementById("reset-view-btn").addEventListener("click", () => {
  if (modelGroup) fitCameraToObject(modelGroup);
});

// ---- tuning-panel mode: embedded iframe vs real popout window --------------

const embeddedPanel = document.getElementById("embedded-panel");
const embeddedIframe = document.getElementById("embedded-iframe");
const modeSelect = document.getElementById("tuner-mode");
let popoutRef = null;

function applyTunerMode(mode) {
  if (popoutRef && !popoutRef.closed) popoutRef.close();
  popoutRef = null;
  embeddedPanel.classList.remove("show");

  if (mode === "embedded") {
    if (!embeddedIframe.getAttribute("src")) embeddedIframe.setAttribute("src", "tuner.html");
    embeddedPanel.classList.add("show");
  } else if (mode === "popout") {
    popoutRef = window.open("tuner.html", "stool-tuner", "width=380,height=780,resizable=yes");
  }
}

modeSelect.addEventListener("change", () => applyTunerMode(modeSelect.value));

// draggable embedded panel (still "a separate window", just movable within the tab)
(function makeDraggable() {
  const bar = embeddedPanel.querySelector(".panel-titlebar");
  let dragging = false, offX = 0, offY = 0;
  bar.addEventListener("pointerdown", (e) => {
    dragging = true;
    const rect = embeddedPanel.getBoundingClientRect();
    offX = e.clientX - rect.left;
    offY = e.clientY - rect.top;
    embeddedPanel.style.right = "auto";
  });
  window.addEventListener("pointermove", (e) => {
    if (!dragging) return;
    embeddedPanel.style.left = (e.clientX - offX) + "px";
    embeddedPanel.style.top = (e.clientY - offY) + "px";
  });
  window.addEventListener("pointerup", () => { dragging = false; });
})();

// ---- live status polling (server.py's regen loop -> version bump) ---------

const banner = document.getElementById("banner");
const glbBadge = document.getElementById("glb-badge");
let lastVersion = -1;
let liveMode = false;

async function pollStatus() {
  try {
    const resp = await fetch("generated/status.json", { cache: "no-store" });
    if (!resp.ok) throw new Error("status " + resp.status);
    const status = await resp.json();
    liveMode = true;
    banner.classList.remove("show");
    glbBadge.textContent = "live · v" + status.version;
    glbBadge.className = "badge ok";
    if (status.version !== lastVersion) {
      lastVersion = status.version;
      await loadModel("generated/live_stool.glb?v=" + status.version);
    }
  } catch (e) {
    if (liveMode) {
      // was live, server went away
      glbBadge.textContent = "server unreachable";
      glbBadge.className = "badge err";
    }
  }
}

async function init() {
  window.addEventListener("resize", () => {
    camera.aspect = window.innerWidth / window.innerHeight;
    camera.updateProjectionMatrix();
    renderer.setSize(window.innerWidth, window.innerHeight);
  });

  // fast first paint: try the live server immediately; fall back to the
  // committed static reference GLB if it isn't running.
  try {
    const resp = await fetch("generated/status.json", { cache: "no-store" });
    if (!resp.ok) throw new Error("no live server");
    const status = await resp.json();
    lastVersion = status.version;
    liveMode = true;
    glbBadge.textContent = "live · v" + status.version;
    glbBadge.className = "badge ok";
    await loadModel("generated/live_stool.glb?v=" + status.version);
    modeSelect.disabled = false;
  } catch (e) {
    await loadModel("assets/stool_default.glb");
    glbBadge.textContent = "static reference (no live server)";
    glbBadge.className = "badge warn";
    banner.classList.add("show");
    banner.innerHTML =
      "Live tuning server not running -- showing the static reference model. " +
      "Run <code>py server.py</code> from this page's own directory, then reload, to enable live parameter tuning.";
    modeSelect.value = "off";
  }

  setInterval(pollStatus, 400);
  applyTunerMode(modeSelect.value);

  renderer.setAnimationLoop(() => {
    controls.update();
    renderer.render(scene, camera);
  });
}

init();
