// three.js (a genuinely DIFFERENT engine) loads the SAME Godot-exported GLB headlessly and
// asserts geometry PARITY against Godot's own counts — proving the scene_node data renders
// the same across renderers, not merely that the file is spec-valid. This is the literal
// "test on a different renderer, things work the same" gate, and the seed of the web delegate.
//
//   node three_parity.mjs <path-to.glb> [path-to-counts.json]   (or: npm run parity -- <glb> <counts>)
//
// exit 0 = loaded (and parity holds if counts given); 1 = parity mismatch; 2 = load/usage error.
import { readFileSync } from "node:fs";
import { GLTFLoader } from "node-three-gltf";

const glb = process.argv[2];
const countsPath = process.argv[3];
if (!glb) {
  console.error("usage: node three_parity.mjs <glb> [counts.json]");
  process.exit(2);
}

let gltf;
try {
  const buf = readFileSync(glb);
  // GLTFLoader.parse needs the exact ArrayBuffer slice — a Node Buffer's underlying buffer
  // can be larger/shared and would corrupt the parse.
  const ab = buf.buffer.slice(buf.byteOffset, buf.byteOffset + buf.byteLength);
  const loader = new GLTFLoader();
  gltf = await new Promise((resolve, reject) => loader.parse(ab, "", resolve, reject));
} catch (e) {
  console.error(`three.js failed to load '${glb}': ${e?.message ?? e}`);
  process.exit(2);
}

let meshes = 0;
let vertices = 0;
gltf.scene.traverse((o) => {
  if (o.isMesh && o.geometry?.attributes?.position) {
    meshes++;
    vertices += o.geometry.attributes.position.count;
  }
});
console.log(`three.js GLTFLoader: ${glb} -> meshes=${meshes} vertices=${vertices}`);

if (countsPath) {
  const want = JSON.parse(readFileSync(countsPath, "utf8"));
  const okMesh = meshes === want.meshes;
  const okVerts = vertices === want.vertices;
  console.log(
    `parity vs Godot: meshes ${meshes}==${want.meshes}? ${okMesh}; vertices ${vertices}==${want.vertices}? ${okVerts}`,
  );
  if (!okMesh || !okVerts) {
    console.error("PARITY MISMATCH: three.js and Godot disagree on the GLB geometry");
    process.exit(1);
  }
  console.log("PARITY OK: three.js and Godot agree on the GLB geometry");
}
process.exit(0);
