# Blender integration decision — hybrid recommendation

**Purpose:** decide what should route THROUGH Blender (as an offline authoring backend) vs what should stay IN-ENGINE (Godot + the node substrate), for the Resonance-Evolution engine.
**Date:** 2026-07-01

---

## 1. The question and the constraints

We want more 3D vocabulary — more kit meshes, procedural geometry, cleaned/decimated assets, maybe morph-target characters — feeding the engine's GLB ingest path. Blender is the obvious authoring backend. The question is not "Blender: yes/no" but **which jobs belong in Blender vs which belong in the live engine loop**, and for the pure format-conversion job, **whether a lightweight converter beats spinning up Blender at all.**

Three hard constraints shape the answer:

- **Node-wiring simplicity law.** Every capability must be (or be plannable as) a wired node on a 2D canvas. So Blender appears as a **process node** (`Blender` / `Bake` / `Convert`) that shells out — never as a hard dependency baked into the runtime.
- **System-neutral / engine-agnostic core.** The engine core is renderer-neutral; delegates are thin. Blender must **not** become load-bearing at runtime. It is an **offline / authoring** tool that emits **GLB data** the engine ingests. The live in-engine hot-reload loop must run on a machine with **no Blender installed.**
- **GLB is the clean seam.** The verified ingest path is `mesh:{source:"glb", path:"res://assets/vendor/<kit>/<file>.glb"}` → `godot/renderers/godot_scene_renderer.gd` `_load_glb()` (line 516), which calls `GLTFDocument.new().append_from_file(path, state)`. Blender's only job, if used, is to EMIT a spec-valid GLB into `godot/assets/vendor/...`. Everything else is decoupled by that seam. The engine already gates ingested GLB through a Khronos validator + a three.js parity oracle, so any GLB producer — Blender or otherwise — is checked the same way.

---

## 2. Capability survey

### 2a. Headless CLI (`blender --background --python`)

Blender runs fully headless with no GUI. The canonical invocation is `blender myscene.blend --background --python myscript.py` ([Blender Manual — Command Line Arguments](https://docs.blender.org/manual/en/latest/advanced/command_line/arguments.html)). Short forms: `-b` = `--background`, `-P` = `--python` ([janakiev — Running Blender from the Command Line](https://janakiev.com/blog/blender-command-line/)).

Key mechanics, verified:

- **Passing args to your script.** Blender parses everything on the command line, so you separate *your* args with a `--` sentinel — Blender ignores everything after `--`, and the script reads them: `blender -b -P convert.py -- in.obj out.glb`, then in Python `argv = sys.argv[sys.argv.index("--") + 1:]` ([janakiev](https://janakiev.com/blog/blender-command-line/); [Blender Python API — Tips and Tricks](https://docs.blender.org/api/current/info_tips_and_tricks.html)).
- **`--factory-startup`** loads Blender with factory defaults (no user prefs/add-ons config), which makes batch runs **deterministic and reproducible** across machines — important for CI ([Blender Manual — Command Line Arguments](https://docs.blender.org/manual/en/latest/advanced/command_line/arguments.html)).
- **`--python-expr`** runs an inline expression instead of a file — handy for one-liners: e.g. `blender -b input.blend --python-expr "import bpy; bpy.ops.export_scene.gltf(filepath='output.glb')"` ([jakelazaroff/til — Export a Blender file to GLB from the command line](https://github.com/jakelazaroff/til/blob/main/blender/export-a-blender-file-to-glb-from-the-command-line.md)).
- **Exit behavior.** In `--background` mode Blender runs the script and quits; a script can force exit with `sys.exit()`/`bpy.ops.wm.quit_blender()`. (Note: the older `-c`/command form implies `--background` — [Blender Manual](https://docs.blender.org/manual/en/latest/advanced/command_line/arguments.html).)

This is the safest way to use Blender as a backend: you spawn the binary, it does one job, it exits. No persistent Blender process, no runtime coupling.

### 2b. `bpy` as a Python module (`pip install bpy`)

Blender is also shipped as an importable Python module — "Blender as a Python module for use in studio pipelines, web services, scientific research, and more" ([bpy · PyPI](https://pypi.org/project/bpy/)). This lets a *normal* Python process `import bpy` and drive Blender without spawning the binary.

Verified current status ([bpy · PyPI](https://pypi.org/project/bpy/)):

- **Latest version 5.1.2, released 2026-05-19.**
- **Locked to exactly one Python version:** 5.1.2 requires **Python 3.13** and only 3.13 — "Each Blender release supports one Python version, and the package is only compatible with that version."
- **Heavy wheels:** 205–391 MB per platform (Win ARM64 205.6 MB, Win x64 350.2 MB, Linux x64 390.9 MB, macOS ARM64 238.5 MB).
- **Known dependency friction:** numpy>2.0 incompatibility, missing OpenImageIO, and version-drift install failures are recurrent ([bpy issue #134550 — numpy version](https://projects.blender.org/blender/blender/issues/134550); [bpy issue #119156 — can't install recent versions](https://projects.blender.org/blender/blender/issues/119156); [BioErrorLog — Installing bpy via pip](https://en.bioerrorlog.work/entry/pip-install-bpy)). LTS-window-only on PyPI; older versions live at `https://download.blender.org/pypi/`.

**Assessment:** `bpy`-as-module tightly couples our conversion tooling's Python interpreter to Blender's exact Python version and a ~350 MB wheel. That is a hard dependency in the wrong place. For a *process node that shells out*, spawning the `blender` binary is strictly better — the node just needs `blender` on PATH, no Python-version lockstep.

### 2c. glTF round-trip (`io_scene_gltf2` / `bpy.ops.export_scene.gltf`)

Blender ships the Khronos-maintained glTF 2.0 importer/exporter as a built-in add-on ([Blender Manual — glTF 2.0](https://docs.blender.org/manual/en/latest/addons/import_export/scene_gltf2.html)). Driven from script via `bpy.ops.export_scene.gltf(...)` ([Blender Python API — Export Scene Operators](https://docs.blender.org/api/current/bpy.ops.export_scene.html)).

Key options (verified via the operator docs and community references):

- **`export_format`** — `'GLB'` (single binary `.glb`, our target), `'GLTF_SEPARATE'` (`.gltf` + `.bin` + textures), `'GLTF_EMBEDDED'` (base64-in-JSON) ([Export Scene Operators](https://docs.blender.org/api/current/bpy.ops.export_scene.html)). Passing a `.glb` filepath defaults to GLB ([jakelazaroff/til](https://github.com/jakelazaroff/til/blob/main/blender/export-a-blender-file-to-glb-from-the-command-line.md)).
- **`export_apply`** — apply modifiers on export (bakes the modifier stack into the emitted mesh) ([Blender Artists — GLB/GLTF export: baking modifiers](https://blenderartists.org/t/glb-gltf-export-cant-bake-modifiers/1527614)).
- **`export_yup`** — export +Y-up (glTF's convention; Blender is Z-up) — matches what our GLB consumers expect ([Blender Manual — glTF 2.0](https://docs.blender.org/manual/en/latest/addons/import_export/scene_gltf2.html)).
- **Morph targets / shape keys** — `export_morph`, `export_morph_normal`, `export_morph_tangent` (glTF morph targets = Blender shape keys) ([Blender Python API — export_scene](https://docs.blender.org/api/blender2.8/bpy.ops.export_scene.html)).
- **Draco compression** — `export_draco_mesh_compression_enable`, `..._level` (0–6), and per-attribute quantization (`..._position_quantization`, `..._normal_quantization`, `..._texcoord_quantization`, `..._generic_quantization`) ([Blender Python API — export_scene](https://docs.blender.org/api/blender2.8/bpy.ops.export_scene.html); [Jonas Sandstedt — compress a glTF with Draco in Blender](https://jonassandstedt.se/blog/how-to-export-and-compress-a-gltf-file-with-draco-3d-using-blender/)).
- **Materials** — PBR metallic-roughness materials export cleanly.

**Draco caveat for us:** Draco-compressed GLB requires a Draco-aware decoder to load. Godot 4's `GLTFDocument` supports Draco, but our Khronos validator + three.js oracle need Draco extensions enabled to load compressed files. **Recommendation: emit UNCOMPRESSED GLB by default** from the Blender node (leave Draco off), so the validators and Godot ingest are unconditionally clean; apply Draco as a *separate, optional* gltf-transform pass later if size matters (see §2f).

### 2d. Geometry Nodes → GLB

Blender's Geometry Nodes is a node-based procedural-geometry system — conceptually the same shape as our engine's node substrate, which makes it a natural "procgen through Blender" option. Procedural output **can** be baked to GLB, but with a real gotcha:

- Geometry Nodes frequently outputs **instances**, and instances need a **Realize Instances** node (or "Make Instances Real") before/at export, or you get an empty/partial GLB. This is a known, still-rough area ([glTF-Blender-IO issue #1537 — instances from geometry nodes not exported](https://github.com/KhronosGroup/glTF-Blender-IO/issues/1537); [Blender issue #94953 — support geometry nodes in glTF exporter](https://projects.blender.org/blender/blender/issues/94953)).
- With **Realize Instances + `export_apply=True`**, the evaluated procedural mesh bakes down to plain triangles and exports as ordinary GLB geometry.

**Assessment:** Geometry Nodes is a legitimate way to *manufacture* procedural GLB vocabulary offline (e.g. scattered rocks, a parametric fence, a generated building shell), then bake → GLB → ingest. It is **not** a live in-engine capability and should not be confused with our own node substrate's live solve — it's a *content factory*, run offline, output committed as GLB.

### 2e. Blender MCP / automation servers

The prominent option is **[ahujasid/blender-mcp](https://github.com/ahujasid/blender-mcp)** (MIT, ~22k stars, updated 2026-01-23 per search metadata). It exposes Blender's Python API to LLMs over MCP. Architecture: a **Blender add-on runs a socket server inside a live Blender GUI session**, and a separate MCP server (launched via `uvx`) relays commands from Claude Desktop / Cursor / VS Code ([blender-mcp README](https://github.com/ahujasid/blender-mcp/blob/main/README.md)). Features: create/modify/delete objects, materials, **execute arbitrary Python in Blender**, and pull assets from Poly Haven / Sketchfab / Hyper3D / Hunyuan3D.

**Assessment against our posture:** blender-mcp **drives a live, interactive Blender GUI** — the README requires Blender open with the add-on enabled; it is not a headless batch tool. Its own disclaimer flags that `execute_blender_code` runs "arbitrary Python code in Blender, which can be powerful but potentially dangerous" ([README](https://github.com/ahujasid/blender-mcp/blob/main/README.md)). That is the opposite of our "offline, deterministic, one-job-then-exit, no runtime coupling" requirement. It also doesn't fit "everything is a node / everything has a text equivalent": it's an interactive LLM↔GUI bridge, not a reproducible wired step. **Do not adopt blender-mcp as engine infrastructure.** (It's fine as a human-side exploratory modeling toy, but it stays outside the engine.) Our node substrate already IS the "text equivalent of automation"; a headless `blender --background --python` process node gives us the reproducibility MCP-into-a-live-GUI gives up.

Newer CLI surface worth noting: Blender 4.2+ added `blender --command <subcommand>` (e.g. `extension build`, `extension install-file`) for the extension system ([Blender Manual — Extensions Command Line Arguments](https://docs.blender.org/manual/en/latest/advanced/command_line/extension_arguments.html)). Not needed for conversion/baking, but relevant if we ever ship a custom export add-on.

### 2f. Lightweight non-Blender converters (prefer these for pure conversion)

For *pure format conversion* — no mesh authoring, just "turn this OBJ/FBX into a clean GLB" — Blender is overkill. Lighter, faster, no ~350 MB dependency:

- **[obj2gltf](https://github.com/CesiumGS/obj2gltf)** (Cesium, pure Node.js). `npm install -g obj2gltf`, then `obj2gltf -i model.obj -o model.glb` (binary GLB). Handles MTL materials → PBR metallic-roughness. **OBJ-only.** No Blender required.
- **[gltf-transform](https://gltf-transform.dev/cli)** (pure JS/Node). `npm install --global @gltf-transform/cli`. Does **not** convert from OBJ/FBX — it operates on *existing* glTF/GLB — but it's the best tool for the *post-conversion* pass: `inspect`, `validate`, `optimize`, `draco`, `weld`, `dedup`, texture compression. Example: `gltf-transform optimize input.glb output.glb --compress draco --texture-compress webp`.
- **[FBX2glTF](https://github.com/godotengine/FBX2glTF)** (godotengine fork; also facebookincubator). Single-binary CLI for FBX → GLB: `FBX2glTF --binary --draco --input in.fbx --output out.glb`. This is the lightweight answer for **FBX**, which obj2gltf can't do.
- **[assimp](https://github.com/wangerzi/3d-model-convert-to-gltf)** / MeshSmith — broad multi-format (STL/STEP/OBJ/FBX/Collada) → glTF/GLB, but heavier setup and more variable glTF fidelity than the dedicated tools above.

**Rule of thumb:** OBJ → GLB use **obj2gltf**; FBX → GLB use **FBX2glTF**; polish/compress any GLB use **gltf-transform**. Reach for **Blender only** when the job needs *authoring* (procedural geometry, decimation/retopo, UV work, morph targets), not mere conversion.

---

## 3. THE HYBRID RECOMMENDATION

**One-line:** Keep the live loop 100% in-engine; use Blender only as an **offline authoring/bake process node** for jobs that genuinely need mesh authoring or procedural geometry; and for *pure format conversion* **prefer a lightweight converter (obj2gltf / FBX2glTF, polish with gltf-transform) over Blender** — reserve Blender for the authoring jobs a converter can't do.

### Job → home mapping

| Job | Home | Tool | Why |
|---|---|---|---|
| Live scene arrangement / node-wiring | **IN-ENGINE** | node substrate | This is the hot-reload loop — must run with no Blender installed |
| WFC Context solve | **IN-ENGINE** | WFC kernel | Live iteration; already engine-native |
| Painterly evolver | **IN-ENGINE** | evolver | Live human-in-loop fitness; can't depend on Blender |
| Primitive parts (13-shape catalog) | **IN-ENGINE** | `catalog.json` | Asset-free, instant, no external tool |
| Live scene composition / camera / view | **IN-ENGINE** | Godot renderer | Runtime path; Blender-free by design |
| **OBJ → GLB** conversion | **LIGHTWEIGHT (preferred)** | **obj2gltf** | Pure Node, no ~350 MB dep, fast, MTL→PBR |
| **FBX → GLB** conversion | **LIGHTWEIGHT (preferred)** | **FBX2glTF** | Single binary, handles FBX; Blender not needed |
| GLB optimize / validate / Draco / weld / dedup | **LIGHTWEIGHT** | **gltf-transform** | Best-in-class glTF post-processing, pure JS |
| OBJ/FBX → GLB **when a converter mangles it** | **THROUGH BLENDER** | `blender -b -P convert.py` | Blender's importers are the most robust fallback |
| Procedural geometry (scatter, parametric kits) | **THROUGH BLENDER** | Geometry Nodes → Realize Instances → bake → GLB | Offline content factory; bake to plain GLB |
| Mesh cleanup / decimation / retopo / UV | **THROUGH BLENDER** | `blender -b -P` (modifiers, decimate) | Genuine mesh authoring; no CLI converter does this |
| Character morph-target authoring (if needed) | **THROUGH BLENDER** | shape keys → `export_morph` | Morph-target authoring is Blender's job |

**Stay-in-engine rationale:** everything in the top block is the *live-iteration loop*. Coupling any of it to Blender would violate the system-neutral constraint (runtime must run Blender-free) and the node-wiring law (the loop stays as wired nodes, not shell-outs to a 3D DCC).

**Prefer-lightweight rationale:** most incoming CC0 kits are already GLB or trivially OBJ/FBX. For those, obj2gltf / FBX2glTF do the job in seconds with a tiny dependency, versus spinning up a ~350 MB Blender for a format flip. Blender earns its cost only when the job is *authoring*.

---

## 4. Recommended concrete setup

**Install route: spawn the `blender` binary in `--background`, NOT `pip install bpy`.**

Reasoning:
- A `Blender` *process node* only needs `blender` on PATH — no Python-version lockstep. `bpy`-as-module (§2b) forces our tooling onto Blender's exact interpreter (5.1.2 → Python 3.13 *only*) plus a 205–391 MB wheel and recurring numpy/OIIO friction. That's a hard dependency in the exact place the constraints forbid.
- Spawn-the-binary is one-job-then-exit: no persistent process, no runtime coupling, trivially wrapped as a node that shells out.
- **Version-match caveat:** pin/record the Blender version used for a bake (e.g. `blender --version` captured into the node's output metadata). Blender's glTF exporter evolves; a bake is reproducible only against a known Blender version. `--factory-startup` removes user-config variance across machines.

**Sample OBJ → GLB invocation (the `Blender` / `Convert` process node):**

```bash
blender --background --factory-startup --python convert.py -- input.obj output.glb
```

```python
# convert.py — run as: blender -b --factory-startup -P convert.py -- in.obj out.glb
import bpy, sys

argv = sys.argv[sys.argv.index("--") + 1:]   # args after the -- sentinel
in_path, out_path = argv[0], argv[1]

# start from an empty scene
bpy.ops.wm.read_factory_settings(use_empty=True)

# import (swap for the matching importer per extension: obj / fbx / etc.)
bpy.ops.wm.obj_import(filepath=in_path)       # Blender 4.x native OBJ importer

# emit a spec-valid, uncompressed GLB into godot/assets/vendor/...
bpy.ops.export_scene.gltf(
    filepath=out_path,
    export_format='GLB',
    export_apply=True,                        # bake modifiers
    export_yup=True,                          # glTF +Y up
    export_draco_mesh_compression_enable=False,  # keep validators/ingest simple
)
```

The node contract is: **in = source mesh path; out = a spec-valid GLB written under `godot/assets/vendor/<kit>/<file>.glb`.** The engine then ingests it unchanged via `_load_glb` / `GLTFDocument.append_from_file`, and the existing Khronos validator + three.js oracle check it exactly like any other GLB. For a Geometry-Nodes bake, the same node pattern applies but the script realizes instances + applies the modifier before export.

---

## 5. Risks / caveats

- **Blender version drift.** The glTF exporter changes across releases; a bake is only reproducible against a recorded Blender version. Mitigate: capture `blender --version` into node metadata; use `--factory-startup`.
- **`bpy` wheel size + Python lockstep (if we ever went that route).** 205–391 MB, single-Python-version. Avoided by choosing the spawn-the-binary route.
- **Draco compat with our validators.** Draco-compressed GLB needs Draco-aware decoders in Godot *and* in the three.js/Khronos oracles. Mitigate: default the Blender node to **uncompressed** GLB; apply Draco as an optional later `gltf-transform` pass.
- **Geometry Nodes instance export is rough.** Instances silently drop without Realize Instances ([glTF-Blender-IO #1537](https://github.com/KhronosGroup/glTF-Blender-IO/issues/1537)). Mitigate: always realize + `export_apply` in the bake script, and gate output through the validator.
- **GPU-less headless render limits.** A headless server may have no GPU; Cycles GPU render won't work and EEVEE may be limited. Irrelevant for *geometry* export (conversion/baking is CPU-side), but a caveat if we ever tried to bake textures/lightmaps headlessly.
- **Non-determinism.** DCC exports aren't bit-identical across versions/settings. Mitigate: pin version, `--factory-startup`, and treat the emitted GLB (not the process) as the committed, validated artifact.

---

## How this connects to the existing systems (parts catalog / node-wiring / cross-platform)

The engine's vocabulary today is the **13-shape primitive parts catalog** (`godot/assets/parts/catalog.json`) plus **ingested CC0 kits** (verified present: `godot/assets/vendor/kenney_nature`, `godot/assets/vendor/quaternius_nature`). Blender is simply **one way to MANUFACTURE more of that GLB vocabulary offline** — a content factory that emits new `res://assets/vendor/<kit>/<file>.glb` entries. It does not add a new ingest path; it feeds the one that already exists (`_load_glb` → `GLTFDocument.append_from_file`, `godot_scene_renderer.gd:516`). This is exactly the seam the sibling asset-sourcing note relies on when a CC0 kit ships OBJ/FBX only.

Under the **node-wiring simplicity law**, Blender never becomes a runtime dependency: it surfaces as a wired `Blender` / `Bake` / `Convert` **process node** with a dead-simple contract (mesh path in → validated GLB out), shelling out to `blender --background`. The live loop — node-wiring, WFC solve, painterly evolver, primitive parts, scene composition — stays fully in-engine and runs on a machine with no Blender installed. The runtime is never coupled to a DCC; only the *offline authoring* step is.

Because the seam is **GLB**, the whole thing stays **cross-platform / system-neutral**: Blender emits engine-neutral GLB that is validated by the **existing Khronos validator + three.js parity oracle** before ingest, identically to any other producer. Nothing about the runtime knows or cares whether a mesh came from Blender, obj2gltf, FBX2glTF, or hand-authored — which is precisely why the recommendation prefers the **lightweight converters for pure conversion** and reserves **Blender for genuine authoring/procedural jobs**: same output artifact, same validators, lowest possible coupling.
