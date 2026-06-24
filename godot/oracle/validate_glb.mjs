// Khronos glTF-validator gate — the cheapest "different renderer" oracle.
//
// The official npm `gltf-validator` package is an INDEPENDENT glTF 2.0 implementation
// (Khronos, Dart->JS) with NO CLI bin, so this tiny wrapper drives validateBytes() and
// exits non-zero on any glTF ERROR. A Godot-exported GLB passing this proves the export is
// spec-conformant — i.e. any compliant renderer (three.js, Blender, model-viewer, ...) can
// consume the SAME data. This is "substrate independence across renderers", automated.
//
//   node validate_glb.mjs <path-to.glb>        (or: npm run validate -- <path-to.glb>)
//
// exit 0 = conformant (0 errors); 1 = glTF errors; 2 = usage / read error.
import { readFileSync } from "node:fs";
import { validateBytes } from "gltf-validator";

const file = process.argv[2];
if (!file) {
  console.error("usage: node validate_glb.mjs <path-to.glb>");
  process.exit(2);
}

let bytes;
try {
  bytes = new Uint8Array(readFileSync(file));
} catch (e) {
  console.error(`cannot read '${file}': ${e.message}`);
  process.exit(2);
}

const report = await validateBytes(bytes);
const { numErrors, numWarnings } = report.issues;
const info = report.info ?? {};
console.log(
  `glTF-validator: ${file} -> errors=${numErrors} warnings=${numWarnings} ` +
    `version=${info.version ?? "?"} generator=${info.generator ?? "?"}`,
);
if (numErrors > 0) {
  for (const m of report.issues.messages.filter((x) => x.severity === 0)) {
    console.error(`  ERROR ${m.code}: ${m.message} @ ${m.pointer ?? ""}`);
  }
  process.exit(1);
}
process.exit(0);
