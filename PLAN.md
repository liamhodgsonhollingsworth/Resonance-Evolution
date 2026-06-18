# Plan: an in-game homoiconic node editor in Godot — functionality is an arrangement of primitives you wire as physical objects

## ✦ READ THIS — what you'll be able to do (everything below this section is reference)

**The one rule.** Nothing the system does is "new code." **Every function is an arrangement of
already-loaded primitive nodes** wired together as *data*. A behavior, a condition, a renderer, an
image effect — each is a primitive node with standard inputs/outputs, and you build anything by
**wiring primitives into arrangements**. When Claude Code "writes a function," it just emits a new
*arrangement* of primitives that the running game applies live — never new code. People share
functionality by sending each other these arrangements.

**It's a physical, in-game editor.** Functionality is represented as **physical objects you can open**.
You point at the glasses, open their "control panel," and see the nodes inside them — a renderer-object
wired to a lens-object — and you rewire it by connecting standardized parts (lighting flares, shaders,
grain, vignette) into an optical/image-processing pipeline. Every object abstracts down to the same
shared primitives; any object can be opened to reveal and re-wire the smaller nodes that compose it.
(This is the "node-is-a-body / control-panel" idea from your Apeiron transcript, and it's exactly what
*Dreams* (Media Molecule) shipped as "microchips" — which is the closest existing thing to your vision.)

**Clusters are portable plugins.** A cluster of wired nodes is itself a node — a reusable, named,
typed-port "chip" you can drop onto another object, open up, nest inside other chips, and **send to
someone else as a shareable plugin**. Plugins can contain plugins. Because a shared thing is *data over
shared primitives* (not code), it's portable and safe to pass around.

**The approval gate.** Nothing is added, imported, or wired without your say-so. Each external tool we
adopt (listed at the bottom) is shown to you before it becomes a primitive. No AI-chosen functionality
enters your graph unless you approved it.

**What you'll be able to do when v1 is done:**
- **Iterate live, in parallel, by hotloading** *(first essential capability)* — the game runs in Godot;
  Claude Code (or you) change the *arrangement data* and the running game **re-wires its already-loaded
  primitives live, with no restart.** Several things can progress in parallel this way.
- **Add any 3D model into the live game** — including a model **made from a photo** — and it becomes a
  wire-able node.
- **Open any object's control panel and rewire it** — see the primitive nodes inside, connect/disconnect
  them with typed ports, and watch the behavior change live. The glasses example works end to end.
- **Build behaviors and relationships purely by wiring primitives** — attach a behavior to a model, wire
  a relationship between two models, build an optical pipeline — all as arrangements, all from in-game.
- **Group a wiring into a reusable chip and (later) share it** as a portable plugin.
- **Evolve a model — under your control** — the general evolver capability exists, but *you* define the
  free variables per model: what changes, what stays fixed, how. Nothing is pre-wired.

**What you'll be able to do after each phase:**
- **After Phase 1 — live data-driven hotloading in Godot (the spine):** run the game, add any model as a
  node, and watch arrangement changes re-wire the loaded primitives live, screenshot-confirmed.
- **After Phase 2 — the in-game editor + control panels:** open any object, see its internal node graph,
  and rewire it by connecting typed ports in-game; group a wiring into a chip and nest chips.
- **After Phase 3 — the glasses (canonical demo) + photo→model + image pipeline:** make a model from a
  photo, wire the glasses chip (worn-condition → renderer/lens → flare/shader/grain/vignette pipeline),
  open and rewire its optics live.
- **After Phase 4 — portability + supervised evolver:** serialize a chip to a portable string and load it
  back (the sharing primitive); evolve models with free variables you control. (Web/three.js as a second
  engine, and the polished visual editor UI, come later — both additive.)

**The v1 primitives** (each a separate, portable node; an interaction between two is also a node/chip):
- *Asset/IO:* PhotoInput · ImageTo3D (backend-swappable) · MeshOptimize · Model · Transform.
- *Logic/behavior:* Condition/Trigger · Signal · Math/Logic · Relationship.
- *Render/optics:* Renderer/Environment · Lens · EffectLayer (flare / shader / grain / vignette).
- *System:* Chip (cluster) · ControlPanel (open-an-object) · Hotload/Watcher · ScreenshotVerify ·
  ClaudeIterate · Evolver(capability base).

**External tools we propose to adopt — each needs your approval before it is wired:** Godot 4 + a Godot
MCP (godot-mcp / gdai-mcp) · the MIT graph-editor starters (`liggiorgio/graph-edit-demo`,
`tehelka-gamedev/godot-custom-graph-editor`) · the official `gui_in_3d` demo · a hosted image→3D API
(Tripo3D *or* Meshy) · local TripoSR (offline fallback) · glTF-Transform · Khronos glTF-Validator ·
(later) model-viewer / three.js. Nothing here enters your graph until you approve it.

---

# Details (reference — skip unless you want the internals)

## Context — why this, and what we are NOT doing

Goal (Liam): *work with 3D models from photos, evolved under my control, improved live with Claude +
hotloading, from within Godot — where ALL functionality is an arrangement of already-loaded primitive
nodes wired in an in-game editor that represents functionality as physical objects you can open to
reveal and rewire their internals. People send each other arrangements (chips), so the system is a
portable, plugin-based, shareable, homoiconic node editor.*

Design lineage: the **Apeiron transcript** (`f1454c20`) — "a component is a node with a physical 3D
form; putting it on the lathe opens its control panel, a homoiconic interface where the object exposes
its own node graph; functional realism (the form predicts the behavior)." The **worldbuilding
transcript** (`bc4f9d8f`) — hotloading IS the world's metaphysics. And the single best *existing* system
to study is **Dreams (Media Molecule)**: physical 3D-wired gadgets, **microchips** (group→reusable chip
with edge port-nodes = your shareable plugin), scope-in drill-down, recursive nesting, and a remix
economy that shares *arrangements*, not code.

Confirmed directives:
- **All functionality = arrangement of already-loaded primitives, wired as data.** "New function" =
  new arrangement, not new code. The in-game editor is the thing that makes functionality happen, and
  everything abstracts to shared primitives with standard I/O.
- **Godot first.** The editor and runtime are in Godot. (A web/three.js delegate is a later additive
  target via the same GLB-portable models.)
- **Do as little as possible / reuse.** Build the minimal connective tissue over existing primitives;
  do not redo what exists; do not build a genuinely-new engine; **do not use the Apeiron Python engine.**
- **Plugin portability.** Nodes and clusters are portable plugins; chips nest (plugins-of-plugins);
  maximize portability now, build the sharing layer later. Sharing is declarative data → inherently
  safer than code-sharing.
- **Evolver = supervised capability base** with per-model free variables you author; nothing pre-wired.
- **Both image→3D backends, swappable.**

Hardware: **GTX 1080 (8 GB, 2016)** → image→3D is **hosted by default** (TRELLIS/latent breeding needs
16 GB+); evolution is parametric/geometry, the more future-proof genome anyway. (A used RTX 3090 24 GB
later unlocks local latent breeding as a clean additive backend — see the separate GPU note.)

## Why this is mostly REUSE, not build (the research result)

Godot's built-ins fit this almost exactly; the only real builds are thin glue + the primitive library.

| Need | Reuse (Godot built-in / addon / demo) | Build (thin glue) |
|---|---|---|
| In-game node editor UI | **`GraphEdit`/`GraphNode` run at runtime** (Control nodes, ship in exports). Starters: **`liggiorgio/graph-edit-demo`** (runtime DAG + topo-sort executor), **`tehelka-gamedev/godot-custom-graph-editor`** (MIT, "load graph data for runtime") | connection→adjacency mirror (dodge O(n) lookups) |
| Typed ports / "anything connects to anything compatible" | **`GraphNode.set_slot(type_left/right:int)` + `GraphEdit.add_valid_connection_type()`**; mirror `VisualShaderNode.PortType`; port payloads = custom `Resource` subclasses | the type/compat table + payload Resource types |
| The graph **is data** | Godot **doesn't auto-connect** — `connection_request` → you `connect_node`. Serialize `get_connection_list()` + per-node `position_offset` to JSON/Resource | the arrangement schema |
| Wire primitives from data | **`source.connect(signal, Callable(target, method), flags)`** all from StringNames in data; instance via `PackedScene`/`ClassName.new()` | the **data→nodes interpreter** |
| **Hotload (the spine)** | **`ResourceLoader.load(path,"",CACHE_MODE_IGNORE)`** to re-read; keep swappable data top-level | re-read data → **disconnect old wiring set → connect new** (no script reload) |
| Add any model live as a node | **`GLTFDocument.append_from_file/buffer` + `generate_scene`** → normal `Node3D` subtree | wrap as a Model primitive with ports |
| "Control panel inside a physical object" | **official `gui_in_3d` demo**: `SubViewport`(hosting GraphEdit) → `ViewportTexture` on a `QuadMesh`; `Area3D` + `push_input` for interaction (lock GraphEdit zoom=1.0). Fallback: `GodotNodeGraph3D` (3D node graph) | the open/close + drill-down binding |
| Optical / image pipeline | **screen-space shader stack** (`CanvasLayer`+`ColorRect`+`ShaderMaterial`, order = node arrangement, `BackBufferCopy` between passes); knobs = **uniforms** (`set_shader_parameter`, no recompile); `WorldEnvironment` glow/tonemap base. (Avoid CompositorEffect — experimental/Forward+ only; avoid runtime VisualShader graphs — compose GLSL strings from data) | the node-ordered pass stack |
| Claude ↔ Godot verify | **`godot-mcp`/`gdai-mcp`** (MIT) run→read-errors→**screenshot** | — |
| Cluster encapsulation + sharing model | **Dreams microchips** (pattern) · **Factorio blueprint strings** (serialize cluster → paste-able string, auto-lay on import) · **Houdini HDA** (name-spaced coexisting versions = append-only) | chip = subgraph + edge port-nodes; string (de)serializer |
| Image→3D, evolver, transport | Tripo3D/Meshy + TripoSR + glTF-Transform; existing `window.Evolve` core; existing Python bridge + SSE `/api/dev/reload` + `chat_relay.py` | image→3D adapter; model3d evolver domain |

## The substrate (engine-agnostic, portable, declarative)

- **Arrangement = a graph of primitive-node instances + typed connections**, stored as data
  (JSON or nested `Resource`). Content-addressed; serializable; no arbitrary code — only references to
  shared primitives + parameters. This is what hotloads, what an object's control panel shows, and what
  gets shared.
- **Primitive = a small node with standard typed I/O ports.** Heterogeneous primitives (Model, Lens,
  EffectLayer, Condition, Renderer, Math…) all expose the same uniform port interface so anything
  connects to anything compatible (widening-style typing). 3D models load via `GLTFDocument` and become
  Model primitives. Each primitive is a self-contained, portable plugin.
- **Chip (cluster) = a subgraph wrapped as a single node**, its interface declared by edge port-nodes
  (Dreams pattern). Chips nest (plugins-of-plugins). A chip serializes to a portable string and can be
  dropped onto any object, opened, and rewired. Versioned for coexistence (Houdini HDA-style), which is
  this project's append-only "every edit is a new node."
- **GLB/glTF 2.0** remains the model interchange so the same Model primitive ports to a future
  web/three.js delegate unchanged.

## Phased build (the in-game node spine first; image→3D + evolver plug in as primitives)

**Phase 0 — contracts (tiny).** Define: the arrangement schema (JSON/Resource); the standard typed-port
contract (port-type ids + payload `Resource` types); the primitive base class; the chip
(subgraph + edge-ports) format; the portable-string (de)serializer scaffold + coexistence version stamp.
Adopt glTF-Transform + Khronos validator. A few placeholder primitives.

**Phase 1 — live data-driven node runtime + hotload in Godot (THE SPINE).** A Godot project that:
instances pre-loaded primitives and wires them from arrangement data (`connect` via `Callable`); adds
any GLB live (`GLTFDocument`) as a Model primitive; and **hotloads by re-reading the arrangement and
diffing the wiring (disconnect old / connect new) with no restart.** Adopt `godot-mcp`/`gdai-mcp` for
run→read-errors→screenshot; `/api/scene/*` relay on the existing Python bridge. *Verify:* change
arrangement data → the running game re-wires loaded primitives live + a GLB appears live, both
screenshot-confirmed.

**Phase 2 — the in-game editor + control panels.** `GraphEdit` in a diegetic `SubViewport` on a 3D
object's quad (clone `gui_in_3d`); **open any object → see its internal arrangement → rewire by
connecting typed ports** (`set_slot` + `add_valid_connection_type` + the connection→adjacency mirror);
**group a selection into a Chip**, scope-in to edit internals, nest chips. Reuse `graph-edit-demo` +
`custom-graph-editor`. *Verify:* open an object in-game, rewire its primitives, group into a chip, and
see the behavior change live, screenshot-confirmed.

**Phase 3 — photo→model + the glasses (canonical acceptance demo) + image pipeline.**
`tools/image_to_3d.py` + `POST /api/model/from-image` (hosted Tripo3D/Meshy default, local TripoSR
behind a flag) → glTF-Transform → GLB → Model primitive. Build the **glasses chip** from primitives:
glasses Model + "worn" Condition + Renderer/Lens + a node-ordered EffectLayer pipeline
(flare/shader/grain/vignette via the screen-space stack); open the glasses' control panel in-game and
rewire the optical pipeline live. *Verify:* photo → GLB (Khronos-valid) → glasses chip works; opening +
rewiring the optics changes the image live, screenshot-confirmed.

**Phase 4 — portability + supervised evolver.** Serialize a chip to a portable string and load it back
(the sharing primitive; auto-lay on import, version-coexistence). The evolver **capability base**:
`static/evolve/domain_model3d.js` on the existing `window.Evolve` core, with mutation driven by a
**per-model free-variable declaration Liam authors** (what may change, ranges, how) — not hardcoded;
genome = generator-agnostic spec (facets + mods, stamped `generator_id@version`, GLB as cache).
*Verify:* round-trip a chip through a string; with a small Liam-authored free-var set, breed a few
generations and drop a variant into the live game.

### Growth axes (additive, not built now)
- **Web/three.js delegate** as a second engine (same arrangement + same GLB models; behaviors port when
  expressed as **KHR_interactivity** graphs — additive extension thread).
- **Polished visual editor UX** (stealth-create progressive depth, preview-at-any-node, contextual tweak
  menus) — layered onto the Phase-2 editor.
- **Sharing/discovery layer** (paste-able strings + attribution + ranking, Factorio/Mindustry-style) on
  top of the Phase-4 serializer.
- **Latent breeding** via a new `generator_id` once a 16 GB+/24 GB GPU exists; **animated/rigged**
  evolution via `rig`/`clips` facets; **server lineage** by swapping the store (already an append-only DAG).

## Critical files / where things go
- New (Godot): `godot/` project · `godot/runtime/` (arrangement interpreter + hotload diff) ·
  `godot/primitives/` (the primitive library, each a portable plugin) · `godot/editor/` (in-game
  GraphEdit control-panel, cloned from `gui_in_3d`) · `godot/chips/` (serializer + version stamp) ·
  `godot/delegate.gd` (WS to the bridge).
- New (Python/web): `tools/image_to_3d.py`; routes `POST /api/model/from-image` + `/api/scene/*` in
  `tools/terminal_bridge.py`; `static/evolve/domain_model3d.js` + the evolve `feature_registry.json` entry.
- New data: arrangement schema · typed-port/payload Resource types · chip portable-string format.
- Adopt (installed/vendored): Godot 4, godot-mcp/gdai-mcp, `graph-edit-demo`, `custom-graph-editor`,
  `gui_in_3d` demo, glTF-Transform, Khronos validator, Tripo3D/Meshy client, TripoSR; (later) model-viewer/three.js.
- Reuse as-is: `window.Evolve` core, Python bridge + SSE `/api/dev/reload`, `chat_relay.py`.

## Verification (end-to-end, the glasses thesis)
**Run the Godot game → make a model from a photo → it appears live as a node → wire the glasses chip
(worn-condition → renderer/lens → flare/shader/grain/vignette pipeline) → open the glasses' control
panel in-game and rewire the optics → the image changes live → group the wiring into a chip, serialize
it to a string, load it back → (Phase 4) evolve a variant with a Liam-authored free-var set and drop it
in — all with no restart, each step screenshot-confirmed (godot-mcp).** Per phase: hotload re-wire
screenshot (P1), in-game rewire+chip screenshot (P2), Khronos validator + glasses screenshot (P3),
chip round-trip + `playwright.evolve.config.js` (P4).

## Honest risks / known leaks
- **Hotload is data-driven, not script-driven** — we re-wire loaded primitives from data
  (`disconnect`/`connect`), never live-reload scripts (Godot script hot-reload is flaky, #72825). New
  *primitive types* (rare) still need a reinstantiate/restart; new *functions* are just new arrangements.
- **GraphEdit is marked experimental** (reworked in 4.2) and has gotchas: O(n) connection lookups (keep
  an adjacency mirror), horizontal-only ports, zoom-sensitive dragging (lock zoom=1.0 in the panel).
- **Diegetic panel input mapping** (3D hit → viewport pixels) is fiddly on tilted/scaled quads — keep the
  SubViewport at native pixel size; 3D-node-graph fallback exists.
- **Visual-language scaling** (Deutsch limit ~50 nodes; hidden-dependency & order-dependence pitfalls,
  e.g. grain-then-blur ≠ blur-then-grain) → mitigate with chips/encapsulation, typed/colored ports,
  preview-at-any-node, and flagging hidden state. (Lessons from Dreams/Nuke/Cognitive-Dimensions.)
- **Hosted image→3D = cloud + per-use cost**, no latent → parametric evolution v1 (spec-genome makes
  local latent a clean later swap); local TripoSR on the 1080 is marginal (offline fallback only).
- **Portability is a discipline:** arrangements must stay declarative (data over shared primitives, no
  embedded arbitrary code) to remain safe + liftable — enforce with a `static-replay` conformance check
  and keep capability/port names engine-neutral so the substrate ports to the web delegate later.
