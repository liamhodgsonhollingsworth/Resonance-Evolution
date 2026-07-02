# Progress / handoff — Resonance-Evolution (Godot)

Status 2026-06-24. Read `README.md` for the architecture + design law (functionality =
arrangements of already-loaded primitives, wired as data; never new code). Full design plan:
`~/.claude/plans/review-handoff-and-next-whimsical-raven.md` (the ✦ READ THIS section is the
user-facing summary; the rest is implementation detail). This file is self-contained for dev.

## Done + verified
**Stereogram + VR viewer foundation (stereogram-vr-viewer lane, NEW 2026-07-02, verified).** ONE
renderer-neutral viewing-geometry dict (viewer-to-screen distance / IPD / focal-convergence plane /
depth budget / screen size+DPI — all DATA on the wire) drives FOUR stereo output modes from the same
`scene_node` scene: cyclopean depth map → autostereogram (classic SIRDS, cross AND parallel
free-viewing), off-axis side-by-side stereo pair (converged exactly at the focal plane, never
toe-in), red/cyan anaglyph, and the live/VR camera rig. New primitive
`godot/primitives/prim_stereo_render.gd` (`StereoRender`, registered in GraphRuntime; inputs
`scene` + optional `geometry` wire override so a knob node can drive IPD live; emits a
JSON-serializable descriptor — PNG paths + derived geometry + depth stats, no Image on the wire);
new `godot/renderers/stereo_rig.gd` (`StereoRig`) turns the SAME dict into two live off-axis
`PROJECTION_FRUSTUM` Camera3Ds (`eye_descriptors()` is the single geometry source a future OpenXR
adapter reads — headset bring-up documented as a seam, out of scope). CPU raycast over the analytic
primitive subset (sphere + box) so every expectation is exact; GPU depth readback is the documented
follow-up that unlocks arbitrary scenes. Demo arrangement `godot/examples/stereogram_demo.json`
(floating shapes at known depths) writes committed artifacts `godot/docs/stereogram_demo_{sirds,
depth,pair,anaglyph}.png`. Test: `godot --headless --path godot -s res://headless_stereo_test.gd`
(**RESULT: ALL PASS**, 58 assertions, ~20 s) — the proof is DECODER-based: hand-computed formula
anchors; sphere depth reads Z−r exactly; band stereograms RELOADED from PNG decode to the predicted
periods in both viewing modes ([81,71,60,39] px parallel, [13,24,36,58] px cross — inverted
relation caught); pair centroid disparity matches ppm·e·(D−Z)/Z within 0.8 px at three depths incl.
zero at the focal plane; anaglyph channels exact; rig frustum offsets ±e/2·zn/D exact; the demo
artifact's background window decodes to the far-plane period 13 px. Second, independent Python
oracle `godot/oracle/decode_stereogram.py` (PIL, zero shared code) agrees on every band + the
committed artifact: `py godot/oracle/decode_stereogram.py godot/docs/stereogram_demo_sirds.png
40:560:13`. Design note + geometry diagram: `notes/design/stereogram_vr_viewer_2026-07-02.md` +
`stereogram_geometry_2026-07-02.svg`. No regression: `headless_primitive_test` + `headless_view_test`
still ALL PASS.
**Projection-mapping simulation foundation — projector-as-data + camera-feedback calibration
(NEW 2026-07-02, verified).** The shared substrate the drum-teaching / laser / projection-audio-sync
arcs inherit: SIX new primitives (own files, one-line registrations) — `Projector` (pose/fov-or-
throw-ratio/resolution/aspect as DATA; content = a wired `pattern` warped by a wired `map`),
`ProjectionSurface` (plane OR cylindrical-section screen; emits the analytic `surface` descriptor
AND its scene_node visual twin at the same pose), `CalibrationPattern` (fiducial grid),
`ProjectionMap` (the reusable 2D-homography warp node the loop writes), `ProjectionObserve` (the
SIMULATED witness camera: projector→surface→camera transport via the exact CPU pinhole model;
mode-swappable for a real camera+detector later — the camera-swappable seam), and
`ProjectionCalibration` (fit the physical map from what the camera saw, invert the targets through
it, refit, damped step). Shared math seam `runtime/projection_math.gd` (pinhole, ray-plane/cylinder,
Hartley-normalized DLT homography least-squares); `renderers/projection_realizer.gd` rasterizes the
warped pattern + CPU-renders the observed view headless (no GPU under --headless), and realizes the
projector LIVE as a SpotLight3D + light_projector cookie (chosen over Decal = orthographic-only
optics, and over per-material projector shaders = material surgery; the CPU seam stays the source
of truth). The feedback loop is DATA-driven: the driver copies `calib.warp` into `map.params.matrix`
each iteration (the evolver-tick pattern). **Numbers (deterministic):** angled-plane grid, gain 0.7:
75.06 → 21.67 → 6.46 → 1.92 → **0.60 px** (converged < 1 px in 4 corrections); gain 1.0 one-shots to
**0.095 px** (planar transport IS a homography — solved, not fudged); cylindrical screen: 48.15 →
**1.07 px** best-fit floor. Test: `godot --headless --path godot -s res://headless_projection_test.gd`
(**RESULT: ALL PASS**, 19 assertions incl. determinism = exact error-sequence reproduction) — writes
before/after observed-view proofs → `godot/docs/projection_calibration_{before,after,proof}.png`.
**Open (windowed demo):** `<Godot> --path godot res://examples/projection_sim_demo.tscn` — the angled
screen + green target pins + the beam self-calibrating live with an error HUD, hot-reloading from THE
one file to edit `godot/examples/projection_sim.json` (move the projector / tilt or curve the screen /
retune gain and SAVE); `-- --shot` proof → `godot/docs/projection_sim_demo.png`.

**Focus simulation — camera focus / depth-of-field as a detail field (GZ-3D / GZ-RENDER, NEW 2026-07-02, verified).** An openable DOF demo (`godot/examples/focus_scene.tscn` + `.gd`) over a receding colonnade: per-pixel DEPTH is captured from the real render (fullscreen `hint_depth_texture` quad, linear-tonemap grab + CPU sRGB decode) and `renderers/focus_field.gd` (`FocusField`) turns it into the SAME detail-field seam the painterly example ships — d(x,y) = detail_knob x focus(depth), focus = plateau-at-focal-plane response from `focal_distance` + `focal_depth` (aperture-like), all DATA in the hot-reload `godot/examples/focus_params.json` (`focus`, `blur_radius`, `shots`, plus the standing always-on `sky`+clouds block). Sharp/blur poles blended per pixel by the field (the PainterlyFalloff two-pole shape); slide `focal_distance` and the sharp band walks down the colonnade. Verified: `headless_focus_test.gd` 20/20 PASS; windowed `--shot` writes near/far focus proofs (committed `docs/focus_near.png` + `docs/focus_far.png` + depth/field debug views). Known simplification: two-pole blend (no per-pixel CoC kernel yet) -> hard sharp/blur halo at strong foreground/background boundaries; a variable-kernel delegate plugs into the same field seam later.
**Creative-mode buildable sandbox MVP (NEW 2026-07-02, verified).** Openable MC-creative-style sandbox `godot/examples/sandbox_creative.tscn` + `.gd`: free-fly cam (WASD+mouse+Space/Shift), grid-snapped left-click place / right-click remove backed by a `Vector3i→record` world Dict, a 9-slot hotbar + E-toggle paged inventory (Blocks/Shapes/Structures tabs) over the 13-shape primitive palette (untextured; per-block `material` seam for later live-texturing), hotloads from `examples/sandbox_params.json`. Open: `<Godot> --path godot res://examples/sandbox_creative.tscn` (`-- --shot` proof → `godot/docs/sandbox_creative.png`, `-- --shot --inv` → `..._inventory.png`). Test: `godot --headless --path godot -s res://headless_sandbox_test.gd` (18/18 PASS).
**Openable painterly example — a single detail-knob with a generic falloff (GZ-3D / GZ-RENDER, NEW
2026-07-01, verified).** An OPENABLE example scene (`godot/examples/painterly_scene.tscn` + `.gd`) that
COMPOSES a small 3D scene from CATALOG PARTS (arch + stairs + pillars + sphere/torus/cone + ground, via
`PartsCatalog.part_node` → Const→Transform→Group, all merged systems reused), PAINTS it with a painterly
effect stack (`EffectStackCpu`, reused verbatim), and — the new spec
(project-generic-detail-falloff-2026-07-01) — VARIES the brush detail across the frame by a SINGLE
detail-knob × a generic FALLOFF CURVE. Two thin new renderer-neutral modules, no foundation edit:
`renderers/detail_field.gd` (`DetailField`) builds a per-pixel budget field `d(x,y)=knob×falloff(x,y)`
from ONE `detail_knob` slider and a DATA falloff curve (`radial` / `vertical` / `horizontal` / `uniform`,
unknown→uniform); `renderers/painterly_falloff.gd` (`PainterlyFalloff`) renders the stack fine AND coarse
and blends per pixel by the field, so strokes are fine/dense where `d≈1` and coarse where `d≈0` — the
field is the durable Truncate/foveation seam (later wires to camera-distance/gaze unchanged), the two-pass
blend the simple first algorithm behind it. It is EASY TO OPEN + ITERATE: it HOT-RELOADS from
`godot/examples/painterly_params.json` (the live_demo watcher pattern) — edit the knob, the falloff curve,
the scene parts, or the effect stack and SAVE → the painted frame re-renders live, no restart. **Open:**
`<Godot> --path godot res://examples/painterly_scene.tscn` (live) or `... -- --shot` (proof PNG →
`godot/docs/painterly_example.png`; raw + field debug PNGs to gitignored `live/`). Test:
`headless_detail_falloff_test.gd` (**RESULT: ALL PASS**, 16 assertions) — uniform==knob; radial peaks at
center + falls to the edge floor; the knob linearly scales the whole field; vertical/horizontal ramps;
unknown curve degrades to uniform; the painted high-detail region DIFFERS from an all-coarse paint (Δ=0.24
— the field is load-bearing); knob=0 collapses to the coarse pass; coarsen pushes Kuwahara radius up +
posterize levels down. Run: `godot --headless --path godot -s res://headless_detail_falloff_test.gd`.

**Basic-parts 3D shape library + catalog (GZ-3D.3, NEW 2026-07-01, verified).** A library of basic
building-block 3D parts, built by EXPANDING the existing asset-free primitive seam — NOT a new
foundation. `renderers/godot_scene_renderer.gd` `_primitive_mesh(shape, params)` now covers a
**13-shape vocabulary**: box, sphere, cylinder, cone, torus, plane/quad, capsule, prism, wedge/ramp,
pyramid, tube/ring (hollow cylinder), and two composite blocks **stairs** + **arch**. Built-in
`PrimitiveMesh` subclasses cover box/sphere/cylinder/cone/torus/plane/capsule/prism; wedge, pyramid,
tube, stairs, arch are built as `ArrayMesh` from surface arrays (`SurfaceTool`, POSITION+NORMAL,
solid + closed + CCW-wound). Each shape takes an OPTIONAL `params` dict (dimensions/segments) that
rides as pure DATA on the `mesh:{source:"primitive", shape, params}` scene_node — renderer-neutral,
zero foundation edit; `mesh_key` now keys on shape+params so a hotload that tunes a dimension re-wires.
A renderer-neutral **parts catalog manifest** `godot/assets/parts/catalog.json` lists every part: its
`shape`, tunable params (default + min/max), aliases, and a one-line description — the DISCOVERABLE,
node-WIREABLE vocabulary the evolver / procgen / the Lathe draw from (node-wiring simplicity law: a
part = drop a Model/primitive node with this shape, wire it). A tiny helper `assets/parts/parts_catalog.gd`
(`PartsCatalog`) loads the manifest and emits a `scene_node` for a part BY NAME in one call
(`PartsCatalog.part_node("arch", {height:3}, [x,0,0])`), with `shapes()`/`defaults_for()`/`shape_for()`
for discovery. Test: `headless_parts_test.gd` (**RESULT: ALL PASS**, 70 assertions, nonzero exit on
fail) — catalog parses + lists 13 parts; every catalog shape builds a non-empty mesh, the one-call
helper emits a valid scene_node the delegate builds to exactly one mesh instance, and each part exports
to a GLB that re-imports with a mesh; params flow through (bigger box → bigger AABB; stairs steps 8>4
verts); unknown part name degrades to `{}`; legacy box/sphere/cylinder still build (no regression).
Cross-renderer: a MULTI-PART GLB of all 13 parts (`live/parts.glb`) passes the **Khronos validator
(errors=0, warnings=0)** and **three.js `GLTFLoader` agrees exactly** (meshes=13, vertices=4005 —
PARITY OK). No regression: `headless_primitive_test` still **RESULT: ALL PASS**. Run:
`godot --headless --path godot -s res://headless_parts_test.gd`,
`node godot/oracle/validate_glb.mjs godot/live/parts.glb`,
`node godot/oracle/three_parity.mjs godot/live/parts.glb godot/live/parts.counts.json`.

**Supervised painterly evolver loop — Aperture human-in-loop fitness (GZ-EVOLVE.1, NEW 2026-06-30,
verified).** The engine's supervised-evolver loop closed as a NODE SYSTEM, with the Aperture as the
human-in-loop fitness surface, breeding PAINTERLY LOOKS first. Full contract: `EVOLVER-LOOP.md`. The
loop is FOUR new primitives wired as DATA — `EvolverPopulation` (genome store: a generation of
lineage-bearing genomes + the evolver's own `meta_genome`, all in `params`) → `Render2D` (genome → PNG
thumbnail via `EffectStackCpu.apply` over a fixed source — REUSED, no pixel math rebuilt) →
`ApertureSurface` (the fitness seam: `op=push` records cards with the **X / Evolve / Save** buttons via
`aperture_push.py --action evolve:Evolve --action save:Save`; `op=readback` reads each card's decision
via `aperture_feedback.py`; `mode=live` hits the real Aperture, `mode=mock` is the headless dry-run) →
`Breed` (a decided generation → the next `population` via the pure `EvolverBreed` algebra). The
action grammar maps **Evolve→KEEP** (survive + breed), **Save→PIN** (frozen archive + breed; pinned =
the crossover pool), **X/skip→CULL** (drop); next gen = KEEP survivors + CROSSOVER pinned pairs +
INJECT 1–2 fresh mutated genomes (the genome's own `mutate`/`crossover`, REUSED), sized to
`meta_genome.population_size`. Lineage is **append-only** (`EvolverGenome` records `id`/`generation`/
`parent_ids`/`origin`; a source is never mutated). The loop is **human-paced + persistent**: all
generation/lineage/card state lives under a **GITIGNORED** dir (`godot/state/evolver/` in `.gitignore`;
test/CLI default `user://evolver/painterly/`) — never a tracked file (host `git reset --hard` would wipe
Liam's pins; load-bearing lesson). `EvolverTick` (CLI `evolver_tick_cli.gd`) is an **idempotent**,
resumable one-step tick: it advances only when the generation is fully decided, else a no-op.
**META-EVOLUTION SEAM provided (not built):** the evolver's params live in DATA as `meta_genome`,
merged at the single read point `PrimEvolverPopulation.meta_genome()` and ridden by every descriptor, so
a future driver that mutates them is picked up with zero code change — the policy itself is a sequenced
follow-on. **EXTENSIBILITY:** a new gene = an `EFFECT_TYPES` entry; a new operator = a `breed` branch; a
new fitness action = a `meta_genome.actions` `{id,label}` + a `disposition_for` branch — all additive.
Test: `headless_evolver_test.gd` (**RESULT: ALL PASS**, 42 assertions, nonzero exit on fail) proves the
FULL data-path cycle headlessly with **mock feedback + a live-inbox guard — it never touches Liam's live
Aperture**: seed → render to valid non-empty PNGs → mock the three actions → breed → next gen has the
right size with KEEP/CROSSOVER/INJECT applied → every child renderable → lineage append-only → state
persists under the gitignored dir → re-run resumes (idempotent). No regression: `headless_effect_test`,
`headless_effect_evolve_test`, `headless_demo` still green. **The live top-row Aperture UI + the
X/Evolve/Save button rendering is the Aperture session's separate work** — this is the engine-side data
path (push via `--action`/readback via feedback) + the breeding, built + verified. Run:
`godot --headless --path godot -s res://headless_evolver_test.gd`.

**Procedural-texture genome on the general-purpose evolver (NEW 2026-07-02, verified).** A SECOND
genome KIND rides the SAME evolver loop (no new primitives; no graph_runtime edit): a **texture
genome** whose genes are an ordered list of **mathematical construction ops** — `value_noise`, `fbm`
(octave stacking), `sine` (two-wave interference), `stripes`/`checker`/`radial`/`voronoi` (geometric
partitions) — each fused with **palette-by-handle color** (handles into `TextureSynthCpu.PALETTES`,
the ONE relinkable palette registry; never raw RGB in a genome), a **blend op**
(replace/mix/multiply/add/screen + opacity), and **domain warping** (`warp_amp/scale/seed` on every
generator). `renderers/texture_synth_cpu.gd` is the CPU synthesis delegate (`OP_TYPES` registry +
`synthesize(desc,w,h)`; NO RNG anywhere in the render layer — every lattice value is an integer-hash
function of coords+seed, so a genome renders **byte-identical** every time); `evolver/texture_genome.gd`
is the genome (per-GENE-TYPE operators: numeric ranges re-sample in-range, handle genes re-link from
their options list, list-level reorder/add/drop; one-point crossover closed over valid ops).
`EvolverGenome` is now genome-kind-POLYMORPHIC (payload key `texture_ops` vs `stack` is the
discriminator; `random_seed(..., kind)`; kinds never interbreed — mixed crossover degrades to a clone),
`Render2D` kind-dispatches (texture → synthesize, effect → EffectStackCpu.apply), and
`meta_genome.genome_kind: "texture"` selects the family for gen-0 seeding + fully-culled recovery —
all defaults preserve the painterly path byte-for-byte. Material seam proof:
`examples/texture_block_material.gd` applies a generated 256px tile to the sandbox "Cube" block mesh
(`GodotSceneRenderer._primitive_mesh("box")` + `StandardMaterial3D.albedo_texture`) — the exact
`material` slot `sandbox_creative.gd` reserves (the live-texturing node system remains its own arc).
Gen-0 driver: `texture_gen0_cli.gd` seeds + renders full-size tiles under the gitignored state dir and
prints `CANDIDATE <genome_id> <png> <caption>` lines for an Aperture-push driver. Test:
`headless_texture_evolver_test.gd` (**RESULT: ALL PASS**, 47 assertions) — gene-algebra closure over
30 chained mutations, byte-identical determinism, full node cycle (render → mock cards → injected
evolve/save/skip → breed KEEP/PIN/INJECT with elite carry byte-identical + injected blood a real
genome change (EFFECTIVE-MUTATION invariant: a mutation never silently no-ops — reorder picks
distinct slots, perturb re-samples until the gene changes)), texture-kind tick persistence +
idempotent resume, live-inbox guard (snapshot-based: proves the RUN added no live rows — the old
absent-tag guard in `headless_evolver_test.gd` false-failed once the production path had pushed a
real live generation; both tests now use the snapshot form). No regression: `headless_evolver_test`
(42) + `headless_effect_evolve_test` (21) + `headless_effect_test` (11) still green.

**Godot Aperture — node-graph renderer for {nodes,edges} (GZ-3D.3, NEW 2026-06-30, verified).** A
read-only IN-ENGINE renderer for the SAME system-neutral `{nodes, edges}` artifact the WEB Aperture
shows — the Godot Aperture. A pure-DATA adapter `aperture/aperture_graph.gd` (`ApertureGraph`, no Godot
type on the data path) normalizes an incoming graph into the canonical internal arrangement, accepting
BOTH the RE-native `{nodes:[{id,type,params}], wires:[{from,out,to,in}]}` AND a generic `{nodes:[{id,
type?/label?}], edges:[{from,to}|{source,target}]}` shape (field-name-tolerant: `edges` OR `wires`;
`from/to`, `source/target`; optional `out/in` ports defaulting to a generic `out`/`in`). The field map
is a configurable override (`ApertureGraph.default_field_map()`), so the as-yet-unfinalized peer file
`big_projects_graph.json` renders with at most a tiny field-map tweak — nothing is hardcoded to one
schema. `aperture/aperture_board.gd` (`ApertureBoard`, extends GraphEdit) is the dumb delegate: it
loads a JSON graph, normalizes via the adapter, and draws each node as a labeled GraphNode (id/type/
label) with its edges as wires, auto-laying-out unpositioned graphs and SHARING PortTypes + the
slot-color scheme with `editor/graph_panel.gd` (the editable twin — reuse, not rebuild). Generic
Aperture nodes render with generic `in`/`out` ports so ANY graph draws, not only graphs of registered
primitives. `aperture/aperture_board.tscn` + `aperture_board_scene.gd` boot it windowed and support the
`-- --shot` one-shot (render -> `godot/live/aperture_board.png`, quit) plus a `--graph <path>` arg.
Bundled sample `aperture/sample_graph.json` (6 nodes / 6 edges) so it renders something meaningful out
of the box. Tests: `headless_aperture_board_test.gd` (32/32, **RESULT: ALL PASS**, nonzero-exit-on-fail)
proves the adapter headlessly — RE-native normalizes to the expected shape; generic `{nodes,edges}`
from/to normalizes IDENTICALLY (same wires); `source/target` maps; malformed/empty/null/array inputs
degrade to a valid empty board (no crash); a field-map override retargets a foreign schema; ports_for_node
unions generic+explicit ports; edges to unknown nodes are dropped. The RENDER is proven by the windowed
`--shot` PNG (committed proof: `godot/docs/aperture_board.png` — 6 labeled GraphNodes + 6 wires; `godot/
live/*` is gitignored). `headless_editor_test.gd` (6/6) green = no GraphEdit regression. Run:
`godot --headless --path godot -s res://headless_aperture_board_test.gd` and
`godot --path godot res://aperture/aperture_board.tscn -- --shot`.

**In-game chat seam — 3 SELECTABLE channels (GZ-3D.2, NEW 2026-06-30, verified).** The `connector`
Context handler — communication with the outside world (`COMMUNICATION-ARCHITECTURE.md` §2.4) as an
in-game chat seam whose far endpoint is a `channel` PARAM (DATA), not three hardcoded foundation paths.
ONE handler, three modes selectable on one seam: **`in_world`** (an in-scene Message inbox: messages
flow between Message nodes inside the running scene), **`dev_console`** (stdout + a console log: the dev
typing chat into the engine), **`external_bridge`** (an external Connector to a Claude Code session,
REUSING the existing `bridge/` arrangement-file mechanism — append a Message node to
`live_dir/arrangement.json`, read it back). It is a DUMB DELEGATE over the new transport-neutral
`runtime/comm_channel.gd` (the §2.4 narrow waist: one canonical envelope `{identity, routing, payload,
interaction_pattern}` + the universal verbs connect/send/receive/close/describe) + the Message envelope —
the connector reads a Message record from its implicit `message` input and publishes the sent/received
envelope on its `sent`/`received`/`envelope` output ports. The SAME wired Message arrangement routes
differently purely by the channel param ("same modules, different channel") with ZERO Message-node
changes; an unconfigured/unknown channel emits a SURFACED diagnostic envelope, never a silent no-op.
**Zero new primitive TYPES** (one new Context handler + one transport module; the foundation is
unchanged). Test: `headless_comm_test.gd` (32/32) — same arrangement routes under all 3 channels, the
§2.4 envelope crosses the seam, external_bridge round-trips a message through the bridge file, and an
unconfigured channel fails loudly. `headless_context_test.gd` (31/31) + `headless_convo_test.gd` green
(no regression). `event` was the last planned Context handler; `connector` now ships too — the edge-level
`Channel` (capacity/backpressure) is the remaining COMMUNICATION-ARCHITECTURE follow-on.

**End-to-end LIVE 3D ITERATION demo — verified by live effect (NEW 2026-06-30).** `live_demo.gd`
+ `live_demo.tscn` prove the whole hot-reload loop in ONE running process: write the arrangement
JSON to disk → `LiveHost` content-hash watcher detects the change → re-wires the already-loaded
primitives → `runtime.evaluate()` → `GodotSceneRenderer` rebuilds the live scene — NO restart, NO
recompile. Three successive on-disk edits each render a visibly different scene (box → sphere
turned+scaled → box+sphere+cylinder via a `Group`), a frame captured after each. Run:
`Godot ... --path godot res://live_demo.tscn` → `godot/live/demo_step{1,2,3}.png`. Montage proof:
`godot/docs/live_iteration_demo.png` (the only committed artifact; `godot/live/*` is gitignored).
This is the GZ-3D.1 milestone: the live-iteration loop is demonstrably working.

**Character Increment A — a FLAME-style genome on a wire, two style_modes (NEW 2026-06-25, verified).**
The first character proof-slice (research: `notes/research/character_*_2026-06-25.md` in Wavelet). A
character = a parameter VECTOR (FLAME-style identity βs + expression ψs) that resolves to a GLB **with
morph targets**, surfaced on the *already-shipped* `mesh.source` seam as `mesh.source="character"` —
ADDITIVE sibling of `"glb"`/`"primitive"`, **zero floor/primitive edits**.
- `tools/character_resolver.py` — the one new piece of real code: a ~60-line-core linear resolver
  (`mean + Σ βᵢ·basisᵢ` → vertices; per-expression deltas → morph targets) + a self-contained glTF-2.0
  GLB emitter (no pygltflib; numpy only). `stylize_amount ∈ [0,1]` applies a fixed PCA-space
  `stylize_delta` (eyes↑/jaw↓/cranium↑/nose↓) — 0=realistic, 1=arcane "boil-down", BOTH valid GLBs, no
  remodeling, continuous. Emits the renderer-neutral `scene_node{source:"character", genome, glb,
  morph_weights}`. **FLAME weights are behind a registration form → ships against a SMALL SYNTHETIC PCA
  basis (deterministic); the real-FLAME swap is one function in `load_basis()`, no other code change.**
- `renderers/godot_scene_renderer.gd` — `build_node` gains a `"character"` branch (reuses the glb
  loader on `mesh.glb`) + `_apply_morph_weights` (drives blend-shape values from `morph_weights`, live
  tunable, re-applied each render); `mesh_key` keys characters on the glb path (hotload re-wires).
- **glTF morph-target gap (research §5): CLOSED with no exporter code.** Godot's `append_from_scene`
  already preserves the imported blend shapes, so `gltf_exporter.gd` round-trips morph targets as-is —
  verified by re-import + the external Khronos validator on the Godot-exported GLB.
- `contexts/style_mode_realistic.json` + `style_mode_arcane.json` — TWO `modulate` Context configs
  (built BOTH per implement-both) over the SAME character node + SAME painterly effect node; only the
  overrides differ (`realistic`={stylize_amount:0, effect_stack:[]}, `arcane`={stylize_amount:1,
  effect_stack:[kuwahara,edge_darken,outline,posterize,paper_grain]}). `arcane` is the DEFAULT target.
- Tests: `headless_character_test.gd` (22/22) — descriptor is data, delegate builds a mesh that carries
  morph targets, morph_weights drive blend shapes, exporter round-trips the targets, two genomes →
  distinct faces, same genome under the two style_mode Contexts → two distinct frames.
  `tests/test_character_resolver.py` (8/8, pytest). Cross-renderer: `oracle/validate_glb.mjs` (errors=0
  on the Godot-exported character GLB) + `oracle/character_oracle.mjs` (three.js loads all faces, sees 4
  morph targets each, asserts pairwise-distinct). Run lines added under "How to run" below.

**Communication is a module (NEW 2026-06-24, verified) — `COMMUNICATION-ARCHITECTURE.md`.**
The runtime no longer bakes in a single communication discipline. `primitives/prim_context.gd` —
**Context** = a Chip that ALSO supplies the *handler* for how its scoped modules communicate:
`dataflow` (default, == a plain Chip), `gate` (the powered scope — the whole scope is dormant
unless its `enabled` input is truthy), `modulate` (per-inner-node param overrides, so the SAME
modules compute different values per context), `abstract` (treat the pure scope as a primitive:
compute once, content-address, shortcut forever after — §2.5), `proximity` (the **spatial gate**:
the scope is live only while its two `pos_a`/`pos_b` vector inputs are within a static `radius` —
the per-pair 3D "use X on Y" interaction, and the first handler to realize "observer/spatial state
is just an INPUT a handler reads"), and `tick`/`sim` (**time-stepped propagation** over the new
`State` module — the one stateful primitive, a unit-delay holding cross-tick memory; `tick` is
continuous/living, `sim` is reproducible/fresh → content-addressable for precompute/bake; two
semantics, one stepping core, picked per context by the handler). The realization of
"scenes/contexts/menus/sims are methods of communication; the same nodes behave differently depending
on what is going on" — and it lives entirely in a MODULE (the foundation gained only registry entries
for `Context` + `State`). `event`/`connector` handlers + the edge-level `Channel`
(capacity/backpressure) are the sequenced follow-ons (each a new module, never a foundation edit).
Test: `headless_context_test.gd` (31/31) — one shared scope proven to behave differently under each
handler; modulate/proximity non-destructive; abstract compute-once; tick accumulates while sim resets.

**Phase 0 + 1:** arrangement data substrate (`schema/`), diff-based hotload runtime
(`runtime/graph_runtime.gd`), content-hash watcher (`runtime/live_host.gd`), primitives
`Const/Math/Log/Model/Transform`, bootable game (`main.*`), Claude↔game bridge
(`bridge/scene_bridge.py`). 4 headless suites green.

**Phase 2 — recursive substrate + editor (NEW this session, verified):**
- `primitives/prim_chip.gd` — **Chip** = a cluster wrapped as one primitive; `params.arrangement`
  is a nested graph, `params.ports` maps outer↔inner ports; `evaluate()` runs a recursive
  `GraphRuntime`. Nesting / "procedural all the way down" is free. Registered in `graph_runtime.gd`.
- `editor/chip_ops.gd` — **engine-neutral** `group(arr,ids)`/`ungroup(arr,id)`/serialize (pure
  data→data, no Godot-UI imports; a three.js delegate reuses it verbatim).
- `editor/graph_panel.gd` — **GraphEdit delegate**: renders an arrangement as typed GraphNodes,
  rewire→reserialize→commit to the live file, group-selection into a Chip.
- Runtime seams in `graph_runtime.gd`: `set_external_inputs`, `port_type`, `ports_of`.
- Tests: `headless_chip_test.gd` (10/10), `headless_editor_test.gd` (6/6); `headless_demo` regression green.

**Phase 2.5 — portable 3D via glTF + the renderer-delegate seam (NEW this session, verified):**
- The 3D path is now SUBSTRATE-INDEPENDENT. `Model`/`Transform` no longer emit a live `Node3D`; they
  emit a renderer-neutral, glTF-aligned `scene_node` descriptor (DATA: `{name, translation, rotation
  (quaternion [x,y,z,w]), scale, mesh:{source,path}, children}`) — JSON-serializable, no Godot object
  on any wire. New port type `scene_node` (PortTypes id 9).
- `renderers/godot_scene_renderer.gd` — **GodotSceneRenderer**, the ONLY Godot-coupled piece of the 3D
  path: builds/updates `Node3D`s from the descriptors (instance-reuse keeps live models across
  hotloads), applies glTF TRS→`Transform3D`. `main.gd` mounts it and drives `evaluate→render` off a
  new `LiveHost.reloaded` signal.
- `renderers/gltf_exporter.gd` — **GltfExporter**, exports the SAME eval output to a GLB (shares
  GodotSceneRenderer's tree builder, so what is exported == what is rendered). GLB is the portability
  artifact: any glTF consumer is "another renderer".
- `oracle/validate_glb.mjs` (+ `package.json`) — the **cross-renderer oracle**: Khronos `gltf-validator`
  (an independent glTF implementation) confirms the export is spec-valid → any glTF renderer can consume
  the same data. Real gate (exit 0 valid / exit 1 corrupt). Small `npm install` footprint under
  `godot/oracle/` (node_modules git-ignored).
- Test: `headless_portable_test.gd` (20/20) — pure-data assertions + delegate-builds + hotload
  re-wire + glTF export→reimport round-trip with a 2-mesh fixture and BIJECTIVE per-mesh match on
  vertex count, surface count, and full transform (rotation+scale+translation within epsilon).
  `headless_model` / `headless_transform` updated to the data contract (transform test asserts the
  real quaternion + rendered basis). Live windowed `--shot` renders the box via the delegate (visual proof).
- Adversarially reviewed (18 agents): no must-fix; the three should-fix items were applied (stable
  node_id-keyed instance reuse; full-basis + 2-mesh round-trip assertions; null-descriptor export guard).
  Deferred (low, latent, untriggered): root identity is node-granular (a dangling sibling output on a
  multi-output node would be dropped); the renderer-neutral root-selection logic currently lives on the
  Godot delegate — move it to a neutral file (beside `editor/chip_ops.gd`) when the three.js delegate lands.
- **Multi-object + hierarchical composition:** `primitives/prim_group.gd` (**Group**) combines N
  scene_node inputs into one transform-only parent node (children) — pure data, recursive (Groups of
  Groups → scenes "all the way down": building→walls, city→buildings). Registered in `graph_runtime.gd`.
  `headless_compose_test.gd` (verified): a grouped 2-object scene is pure data, the delegate builds both
  meshes at the right world positions, the whole scene round-trips through glTF with both objects intact,
  and a flat multi-object scene (2 terminal nodes, no group) also renders.
- **three.js web renderer (real 2nd engine, headless):** `oracle/three_parity.mjs` loads the SAME
  exported GLB via three.js `GLTFLoader` (node-three-gltf) and asserts geometry PARITY against Godot's
  counts sidecar (`portable.counts.json`). VERIFIED: Godot + Khronos validator + three.js all agree
  (meshes=2, vertices=2234). The literal "same data, different renderer" proof, and the seed of the
  browser three.js delegate / evolver surface.
- **Primitive mesh source (portable, asset-free):** `GodotSceneRenderer.build_node` also builds
  box/sphere/cylinder for `mesh:{source:"primitive",shape:...}` — renders in Godot, exports to glTF,
  loads in three.js. `headless_primitive_test.gd` (verified); its GLB passes the validator + three.js
  (meshes=3). This is the evolver's genome vocabulary (asset-free, renderable in both engines).
- **Evolver connected (Phase 4 start):** the general-purpose `window.Evolve` (Resonance-Website,
  `static/evolve/`) is REUSED AS-IS via a new domain plugin `static/evolve/domain_node.js` whose genome
  IS a `scene_node` tree. `tools/test_evolve_node_domain.js` (Node, headless, VERIFIED): window.Evolve
  evolves 10 valid scene_node genomes via its own mutate+crossover (choose-1-of-2) strategy — pure data
  the engine + three.js render. The connection IS the shared scene_node data contract; nothing in the
  evolver was rebuilt. NEXT: the three.js browser SURFACE (render two candidates → click to pick →
  evolve) — the interactive loop, which lives in Resonance-Website (the evolver app, the WHERE seam).

## How to run
Godot: `C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe` (console exe for stdout).
```
# REQUIRED after adding/renaming any class_name script (builds the class cache):
godot --headless --path godot --editor --quit-after 120
# headless tests (all 8 green):
godot --headless --path godot -s res://headless_demo.gd
godot --headless --path godot -s res://headless_live_test.gd
godot --headless --path godot -s res://headless_model_test.gd
godot --headless --path godot -s res://headless_transform_test.gd
godot --headless --path godot -s res://headless_chip_test.gd
godot --headless --path godot -s res://headless_editor_test.gd
godot --headless --path godot -s res://headless_portable_test.gd
godot --headless --path godot -s res://headless_compose_test.gd
godot --headless --path godot -s res://headless_primitive_test.gd
# basic-parts 3D shape library + catalog (GZ-3D.3): 13-shape vocabulary + assets/parts/catalog.json + PartsCatalog helper:
godot --headless --path godot -s res://headless_parts_test.gd            # RESULT: ALL PASS (70 assertions) — every catalog part builds + exports + re-imports; params flow as DATA; unknown->{}; no regression
node godot/oracle/validate_glb.mjs godot/live/parts.glb                  # all 13 parts in one GLB — Khronos validator: errors=0
node godot/oracle/three_parity.mjs godot/live/parts.glb godot/live/parts.counts.json  # three.js agrees: meshes=13 vertices=4005 (PARITY OK)
# in-game chat seam — 3 selectable channels (connector Context handler over runtime/comm_channel.gd):
godot --headless --path godot -s res://headless_comm_test.gd              # 32/32: in_world/dev_console/external_bridge route the SAME arrangement; bridge round-trip; loud-fail
# supervised painterly evolver loop — Aperture human-in-loop fitness (GZ-EVOLVE.1; full data-path cycle, mock-only, never touches the live Aperture):
godot --headless --path godot -s res://headless_evolver_test.gd           # RESULT: ALL PASS (42 assertions) — seed->render PNG->mock evolve/save/skip->breed (KEEP/CROSSOVER/INJECT)->next gen; lineage append-only; state persists gitignored; idempotent re-run; live-inbox guard
godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode mock --state-dir user://evolver/painterly --feedback <fake.json>  # one human-paced tick (mock dry-run)
godot --headless --path godot -s res://evolver_tick_cli.gd -- --mode live --state-dir godot/state/evolver/painterly               # LIVE: pushes real cards + polls real decisions
# procedural-texture genome on the same evolver loop (second genome kind; mock-only test, never touches the live Aperture):
godot --headless --path godot -s res://headless_texture_evolver_test.gd   # RESULT: ALL PASS — gene-algebra closure; byte-identical determinism; full cycle render->mock cards->breed; texture tick persistence; live-inbox guard
godot --headless --path godot -s res://examples/texture_block_material.gd # genome -> 256px tile -> StandardMaterial3D on the sandbox Cube block (the material seam proof)
godot --headless --path godot -s res://texture_gen0_cli.gd -- --count 8 --size 256 --state-dir res://state/evolver/textures       # seed+render gen-0 tiles for an Aperture-push driver
# Godot Aperture — read-only node-graph renderer for the system-neutral {nodes,edges} artifact (GZ-3D.3):
godot --headless --path godot -s res://headless_aperture_board_test.gd    # 32/32 RESULT: ALL PASS — adapter normalizes RE-native {nodes,wires} + generic {nodes,edges}(from/to, source/target) identically; malformed degrades gracefully
godot --path godot res://aperture/aperture_board.tscn -- --shot           # windowed: render the bundled sample -> godot/live/aperture_board.png (committed proof: godot/docs/aperture_board.png)
godot --path godot res://aperture/aperture_board.tscn -- --graph res://aperture/sample_graph.json  # render a chosen {nodes,edges} graph file
# View/Camera as DATA — the "single scene -> static view" keystone (View primitive + renderer camera
# branch + glTF camera round-trip; render() and walkabout/gallery cameras unchanged via fallback):
godot --headless --path godot -s res://headless_view_test.gd              # 26/26: descriptor + framing parity + fallback + glTF camera round-trip
godot --headless --path godot res://render_view.tscn                      # headless smoke: assemble(Group+View)->render->apply_view runs
godot --path godot res://render_view.tscn -- --shot                       # windowed: render(scene,view) -> godot/live/render_view.png (one still through the View camera)
node godot/oracle/validate_glb.mjs godot/live/view.glb                    # the camera-bearing GLB is spec-valid (0 errors)
node godot/oracle/three_parity.mjs godot/live/view.glb                    # three.js loads it; parses 1 PerspectiveCamera (fov 75, near 0.05, far 4000)
# painterly effect-stack (renderer-neutral {type,params} DATA + its applier twins):
godot --headless --path godot -s res://headless_effect_test.gd            # the effect-stack seam (11/11)
godot --headless --path godot -s res://headless_effect_library_test.gd    # the L0-L4 effect library (40/40)
godot --headless --path godot -s res://headless_effect_evolve_test.gd     # the EffectGenome evolver (21/21)
godot --headless --path godot -s res://headless_effect_gpu_test.gd        # L1 GPU parity: EffectStackGpu == EffectStackCpu within tol (25/25)
# cross-renderer gates (the portable test writes godot/live/portable.glb + portable.counts.json):
#   one-time:  npm --prefix godot/oracle install
node godot/oracle/validate_glb.mjs godot/live/portable.glb                              # spec-valid => any renderer
node godot/oracle/three_parity.mjs godot/live/portable.glb godot/live/portable.counts.json  # three.js agrees
# character increment A (FLAME-style genome -> GLB w/ morph targets -> scene_node{source:character}):
godot --headless --path godot -s res://headless_character_test.gd          # 22/22, runs the resolver via `py`
py -m pytest tests/test_character_resolver.py -q                            # 8/8, resolver unit tests
py tools/character_resolver.py --identity 1.5 0 -0.8 --stylize-amount 1.0 --out godot/live/char.glb  # one face
node godot/oracle/character_oracle.mjs godot/live/char_a.glb godot/live/char_b.glb  # three.js: morph targets + distinct
# evolver<->engine connection (lives in the Resonance-Website repo; reuses window.Evolve as-is):
#   node tools/test_evolve_node_domain.js   # window.Evolve evolves valid scene_node genomes (headless)
# windowed screenshot -> godot/shot.png:
godot --path godot -- --shot
# run the live game / the live bridge:
godot --path godot
python godot/bridge/scene_bridge.py --port 8210
```

## ★ Next — highest-value unblocker first
*Foundation now in place (this session): 3D arrangements are substrate-independent DATA, the renderer is
a swappable delegate (GodotSceneRenderer), glTF/GLB is the proven portability artifact, and an external
glTF validator is the cross-renderer oracle. The render-style swap in #1 now has a clean seam to plug
into; a three.js delegate (web) is now a small fast-follow — it consumes the same `scene_node`/GLB data.*

**1. The evolvable modular composition seam (START HERE — unblocks the most).** One seam every
visual + evolved feature plugs into. Three pieces, as a thin vertical slice:
  - **Render/effect stack as reorderable arrangement DATA** — an `EffectLayer`/`RenderStack` whose
    `params.layers = [{type, params}]` is rendered by Godot Compositor/CompositorEffect. REUSE
    **PPMagic** (github.com/peterprickarz/PPMagic, multi-pass compositor) + CC0 painterly shaders
    (godotshaders.com: Kuwahara, generalized-Kuwahara, watercolor; Scony/godot-sugar: blur/outline/
    pixelate/grain). Painterly = this stack (the old `EffectLayer` spec: CanvasLayer+ColorRect+
    ShaderMaterial+BackBufferCopy, order = arrangement, uniforms = knobs).
  - **`Surface2D` primitive** — 2D-in-3D as composable nodes: Sprite3D/billboard, `ViewportTexture`
    on a `QuadMesh` (2D-on-3D overlay), `Parallax2D` backdrops. Distant scenery becomes 2D via the
    iteration/LOD-by-distance function (legacy "distance-as-recursion-depth": <1px → aggregate/2D).
  - **Wire the existing `window.Evolve` core to the engine** as a NEW *surface + store* (REUSE, do
    not rebuild — it already has renderer-independent domains/strategies/surfaces + bindings-as-data
    + pluggable store; lives in Resonance-Website worktree `admiring-ptolemy-0d49ab`,
    `static/evolve/*`). A `domain_*` whose genome is the layer-stack (or a procgen genome), driven
    **choose-1-of-2** over the bridge, scored by a shared **validator** (silhouette-IoU→SSIM inner,
    CLIP/LPIPS episodic). Per-domain free-variables are Liam-authored.
  - *Proof slice:* evolve a painterly effect-stack look on a 3D object, pick 1 of 2 → screenshot.
  - *Why first:* it stands up the four shared interfaces (composition-as-data, 2D↔3D surfaces, the
    evolver, the validator) that procgen, painterly, reconstruction, 2D backgrounds, and orbs all
    depend on — so those then proceed IN PARALLEL as new domains/genomes + new layer modules.

**2. In-world 3D editor panel** — mount `editor/graph_panel.gd` in a `SubViewport`→`ViewportTexture`
on a quad (`gui_in_3d` pattern; vendor it, MIT), 3D-hit→pixel, scope-in/out (= the orb-entry seam).

**3. Generative substrate** — `Generator`/`PartSpec`/`evaluateParts` + rule plugins (`LSystem` plants
→ independent GLB parts; `fBmField` clouds → density texture/FogVolume). Evolve a grove + a sky.

**4. Capability library (the ratchet)** — content-addressed, descriptor-indexed store of validated
generator-chips; staged validators (hash→embedding→metric→in-vivo); repeats retrieve-and-tune.

**5. Image reconstruction** — assembly-from-existing-parts + the shared validator + solution caching.

**6. Orbs/zoom** — orb = a Chip (seed mesh far → SubViewport portal mid → camera `reparent()` in).

Phase 3/4 (photo→3D backend or parts-assembly; chip portable string; three.js delegate;
KHR_interactivity; natural evolution) follow.

## Reuse pointers (don't rebuild)
Evolver: `window.Evolve` (Resonance-Website). 2D↔3D: Sprite3D billboard (CC0), `ViewportTexture`+quad,
`Parallax2D`, `Decal`; three.js: pmndrs/postprocessing (MIT), TSL, threejs-billboard, twopoint5d.
Painterly stack: PPMagic, godot-sugar, godotshaders Kuwahara/watercolor (CC0). Evolution of shaders:
KoltesDigital/shader-evolution. Editor panel: official `gui_in_3d` (MIT). Procgen LOD: Godot
`visibility_range_*`, `MultiMeshInstance3D`, `VisibleOnScreenNotifier3D`. Validator: CLIP/LPIPS/SSIM.

## Design law (hold these)
Functionality is never new code — it's an arrangement of primitives wired as data; new TYPES are
rare, new FUNCTIONS are new arrangements. Engine-neutral core + thin swappable delegates. Build
foundations + evaluation harnesses, then EVOLVE toward criteria (not hand-code-then-check). Every job
emits a generalizing capability + validator into a growing library (the ratchet). Build INSIDE the
running software (hot-loaded data, no restart). Nothing imported/wired without Liam's approval. Liam
authors behaviors; Claude builds capabilities. Nothing committed yet.
