// Character-distinctness oracle — the three.js (independent-renderer) gate for Character Increment A.
//
// Loads N character GLBs produced by tools/character_resolver.py via three.js GLTFLoader (a genuinely
// different engine than Godot) and asserts:
//   (1) each loads + has a POSITION attribute (the resolver wrote a valid mesh);
//   (2) each carries morph targets (morphAttributes.position non-empty) — proves the morph-target
//       WRITE the research memo §5 names round-trips into three.js;
//   (3) every pair of GLBs is GEOMETRICALLY DISTINCT (mean per-vertex position differs beyond eps) —
//       proves two genomes resolve to two visibly-different faces, on a real second renderer.
//
//   node character_oracle.mjs <a.glb> <b.glb> [<c.glb> ...]
//
// exit 0 = all loaded, all have morph targets, all pairwise-distinct; 1 = a check failed; 2 = usage.
import { readFileSync } from "node:fs";
import { GLTFLoader } from "node-three-gltf";

const files = process.argv.slice(2);
if (files.length < 2) {
  console.error("usage: node character_oracle.mjs <a.glb> <b.glb> [more.glb ...]");
  process.exit(2);
}

async function load(path) {
  const buf = readFileSync(path);
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  const loader = new GLTFLoader();
  const gltf = await new Promise((resolve, reject) => loader.parse(ab, "", resolve, reject));
  let geom = null;
  gltf.scene.traverse((o) => {
    if (o.isMesh && o.geometry?.attributes?.position && geom === null) geom = o.geometry;
  });
  return geom;
}

function positions(geom) {
  return geom.attributes.position.array;
}

function meanAbsDiff(a, b) {
  const n = Math.min(a.length, b.length);
  let s = 0;
  for (let i = 0; i < n; i++) s += Math.abs(a[i] - b[i]);
  return n > 0 ? s / n : 0;
}

let ok = true;
const geoms = [];
for (const f of files) {
  let g;
  try {
    g = await load(f);
  } catch (e) {
    console.error(`FAIL load ${f}: ${e?.message ?? e}`);
    ok = false;
    continue;
  }
  if (!g) {
    console.error(`FAIL ${f}: no mesh with POSITION`);
    ok = false;
    continue;
  }
  const morphs = g.morphAttributes?.position?.length ?? 0;
  const hasMorphs = morphs > 0;
  console.log(`load ${f}: vertices=${g.attributes.position.count} morphTargets=${morphs}`);
  if (!hasMorphs) {
    console.error(`FAIL ${f}: expected morph targets (morphAttributes.position) but found none`);
    ok = false;
  }
  geoms.push({ f, g });
}

const EPS = 1e-4;
for (let i = 0; i < geoms.length; i++) {
  for (let j = i + 1; j < geoms.length; j++) {
    const d = meanAbsDiff(positions(geoms[i].g), positions(geoms[j].g));
    const distinct = d > EPS;
    console.log(`distinct ${geoms[i].f} vs ${geoms[j].f}: meanAbsDiff=${d.toExponential(3)} > ${EPS}? ${distinct}`);
    if (!distinct) {
      console.error(`FAIL: ${geoms[i].f} and ${geoms[j].f} are geometrically identical (genomes did not differ)`);
      ok = false;
    }
  }
}

if (!ok) {
  console.error("CHARACTER ORACLE: FAILURES PRESENT");
  process.exit(1);
}
console.log("CHARACTER ORACLE: all faces load, carry morph targets, and are pairwise distinct — PASS");
process.exit(0);
