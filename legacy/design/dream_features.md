# Dream-mode features — architecture-fit plan

A planning document mapping the maintainer's eleven proposed features (dream-mode, lucid-dream, dreamlike-traversal) onto Apeiron's existing architecture and naming the skeleton infrastructure being added this session.

The premise is that the engine's existing commitments — single `emit` primitive, topology over coordinates, channels-by-name wires, aggregator-as-node, renderer-as-node, build/runtime split, recursive worlds, text-renderer as first-class — already absorb most of the feature surface. The remaining work is mostly **new node-types and renderers added as files**, plus four small additive engine extensions, all backward-compatible.

## The eleven features mapped to architecture

### 1. Look around with mouse, zoom in/out with scroll wheel

**Already there.** The `View` dataclass carries `position`, `orientation` (3x3 matrix), `scale`, and `fov_y_radians`. Mouse look mutates `orientation`; scroll mutates `scale`. The current renderer pipeline is offline (CLI emits a bundle to `output/`), so the gap is not the camera — it is the **realtime loop with input events**.

**Skeleton added this session.** `engine/input.py` defines `InputEvent` (key/mouse/scroll/text) and `Binding` (event-pattern → view-mutation) types, plus a default `Bindings.default()` mapping that recreates Minecraft controls. No window/loop yet — the realtime renderer is left as a future drop-in.

**Future drop-in.** A `renderers/interactive.py` real-time renderer-node wraps a windowing library (moderngl-window, pygame, or a browser via WebGL) and pumps `InputEvent`s through the bindings, mutating the viewer between frames. The text-renderer's command grammar (`move`, `look-at`) already covers the same surface for headless testing.

### 2. Zooming = scale, not position (microscopic-to-macroscopic)

**Already there.** The architecture commitment "Recursion depth is the level-of-detail mechanism" says "a node decides whether to render itself or recurse based on its projected screen-size at the current viewer." `View.scale` is exactly this knob. The Aggregator node-type already dispatches between impostor (far/small) and full render (near/large) via `select_children`.

**Skeleton added this session.** `View.scale` semantics formalized in a docstring: `scale` is the world-to-screen multiplier — `scale > 1` zooms in (objects subtend more pixels, aggregators expand), `scale < 1` zooms out (aggregators collapse). The aggregator's distance threshold is replaced with a `projected_size = world_size * scale / distance` comparison so the existing aggregator works against both zoom and translation uniformly.

**Future drop-in.** Every existing aggregator's threshold expression migrates from raw distance to `projected_size`. Same code, additive change.

### 3. Arbitrary dimensions, rendered via 3D projection

**Architectural fit.** Channels-by-name wires accept arbitrary channel content. An N-D primitive's `emit` produces a list of N-D vertices and edges; a projector renderer-node consumes that channel and produces ordinary 3D channels (`color`, `depth`, `ids`).

**Skeleton added this session.**
- `node_types/dimension_n.py` — `DimensionN` node-type. Manifest declares `outputs: {"verts_nd": "ndarray", "edges": "ndarray"}`. Build accepts `dims: int` and `shape: str` (initial support: `"hypercube"`); produces vertices and edge index pairs. Emit returns the N-D verts/edges on named channels.
- `renderers/projector_n.py` — `ProjectorN` renderer-node. Manifest declares `inputs: {"verts_nd", "edges"}`. Emit projects N-D verts down to 3D using a configurable projection matrix (default: drop dims beyond 3, optional 4D→3D perspective stereographic projection), then rasterizes edges into the standard `color`/`depth` channels.
- `scenes/dim4_cube_demo.json` — tesseract via `DimensionN(dims=4, shape="hypercube")` wrapped in `ProjectorN`.

**Future drop-in.** Replace `ProjectorN`'s projection function with a library import (e.g. someone's `nd-projection` package). The node-type stays the same; only its implementation file changes. Other shapes (simplex, cross-polytope, hopf-fibered hypersphere) are new `shape:` options or new node-type files.

### 4. Node-graph rooms with arbitrary topology

**Already there.** Apeiron's commitment "Topology, not coordinates, is the position primitive" delivers this directly: every connection carries a 4x4 transform, and impossible geometries are connections whose transforms don't compose to identity around cycles. `Portal` already demonstrates this.

**Skeleton added this session.**
- `scenes/hypercube_rooms_demo.json` — 8 rooms (each a `Group` of `Plane` floor + 4 `Plane` walls + a `Cube` for furniture) connected pairwise by `Portal`s whose transforms together form a 4D hypercube traversal pattern. Walking from room to room moves the viewer through portals; the topology is the hypercube of an 8-vertex 4-cube graph regardless of physical position.

**Future drop-in.** A `node_types/room.py` and `node_types/hallway.py` are naming conveniences over `Group + Plane + Portal`; they can be added as syntactic sugar later without architectural impact.

### 5. Minecraft-like controls + gravity toggle

**Skeleton added this session.**
- `engine/input.py` defines bindings:
  - WASD → planar move along `view.gravity_up`-perpendicular plane
  - Mouse → mutate `view.orientation`
  - Scroll → mutate `view.scale`
  - Space → jump impulse (gravity mode) / no-op (free mode)
  - Double-tap Space → toggle `view.gravity_mode` between `"world"` and `"free"`
  - T → open chat (raises a `ChatOpen` event consumed by `ChatInterface`)
- `View` gains optional fields: `gravity_mode: str = "world"`, `gravity_up: np.ndarray = [0,1,0]`, `time: float = 0.0`. All additive; existing emit()s ignore them.
- `node_types/gravity_field.py` — region with a gravity vector. `precompute_hook` registers the region+vector pair in `engine.cache["__gravity_fields__"]`; the input system queries the list to find which field the viewer is in and overrides `view.gravity_up` accordingly.
- `node_types/key_bindings.py` — a node-shaped Settings holder; `state` is a dict mapping input-event-patterns → action-names. The input system reads from the active `KeyBindings` node.

**Future drop-in.** The interactive renderer reads `KeyBindings`, dispatches `InputEvent`s, and applies the named mutations to `View`. Sensitivity sliders, controller support, accessibility settings — all are fields in the `KeyBindings` state dict; new fields are additive.

**The escherian-traversal choice (reset gravity to viewer's down vs. region's down).** A `view.gravity_mode` value of `"snap_to_region"` resets to the region's gravity; `"snap_to_viewer"` resets to the viewer's down. The double-tap Space behavior queries a sub-mode in `KeyBindings`. Three settings cover the user's described cases (1, 2, 3).

### 6. Procedural world seeds with inverse-update

**Architectural fit.** A Seed node carries a parameter dict and an RNG sequence. Generator nodes consume the Seed (via connection) and produce content. When the viewer edits content, the Generator's **inverse hook** computes a parameter delta on the Seed that "would have generated" the new content. This composes with the existing precompute architecture.

**Skeleton added this session.**
- `node_types/seed.py` — `Seed` node-type. State is a `dict` of named parameters plus a `seed: int` for RNG. Emit returns no visual channels (it is a data node); exposes `describe()` for the text-renderer.
- `node_types/generator.py` — `Generator` node-type. `precompute_hook` reads the connected Seed, generates child node descriptions, and spawns them into the engine. `emit` returns the composite of spawned children. **Critical addition:** modules can expose `invert_hook(state, edit, engine) → param_delta` that the engine's new `Engine.invert_edit(node_id, edit)` method calls when the viewer mutates a generated child. The delta is applied to the connected Seed and the affected sub-graph re-precomputes.
- `engine/inverse.py` — registry and dispatch for inverse-pass. `Engine.invert_edit(node_id, edit)` walks up from the edited node to the nearest Generator, calls its `invert_hook`, applies the delta, and triggers re-precompute of the sub-graph.
- `scenes/seed_world_demo.json` — a Seed → Generator → 3-cube row scene; the generator's invert hook is stubbed (rejects non-trivial edits and returns null delta in v1) but its dispatch is wired so the surface is callable.

**Seed-zoom visual (sphere-from-outside, world-from-inside).** This is a renderer-side trick: outside the sphere, render the seed metadata + a "small world" thumbnail (Apeiron's existing `Computer` node-type already does the inside→outside compositing). Inside, the sphere is treated as a Portal whose `through:` target is the generator's spawned root, with the camera positioned at a default zoom. No new architecture needed; a `node_types/world_sphere.py` future file composes `Sphere + Computer + Portal + Seed`.

**Future drop-in.** Each Generator subtype defines its own `invert_hook` describing what parameter dimensions are tunable. The "good system for figuring out which parameter to tune" is the invert hook's algorithm — initial heuristic: gradient over (param → output) computed numerically via re-precompute; mature: learned models per Generator subtype.

### 7. Pre-simulated interactions for emergent behavior

**Already there.** Architecture commitment "Precomputation moves the heavy work to build time" with `precompute_hook(state, engine, node)` already exists. Aggregators use it to compute centroid + bbox + avg-color before runtime.

**Skeleton added this session.**
- `node_types/simulation_probe.py` — `SimulationProbe` node-type. State is `{horizon: int, dt: float, observed: list[node_id]}`. `precompute_hook` runs `horizon` steps of `node.step(state, dt, neighbors)` calls across observed nodes, recording the trajectory in `engine.cache[node_id]`. At emit time, the SimulationProbe surfaces the precomputed trajectory on a `simulation` channel; renderers consuming it (none yet — future work) display predicted paths, collision points, equilibrium states.

**Future drop-in.** Per-interaction caches; nested SimulationProbes (one probe runs another); mature node-types implement `step()` so the probe has interactions to simulate.

### 8. Chat-driven world building with novelty fallthrough

**Already there.** `node_types/chat_interface.py` reads/writes a chat log file. The TextRenderer's command grammar already accepts `spawn`, `connect`, `move`, `look-at`, `render`. The hot-reload entry point lets new node-types drop into `node_types/` and become live.

**Skeleton added this session.**
- `node_types/chat_interpreter.py` — `ChatInterpreter` node-type. Owns a parse pipeline as a sub-graph of `Token`-shaped child nodes. State holds the known-command list (initially populated from `TextRenderer.command_grammar()`). When a chat message arrives:
  1. Parse: try known commands first.
  2. If novel and Claude Code is connected (detected via the presence of an active `ChatInterface` log writer that recently posted): write a request line `requested: <novel command>` to the log; await Claude Code's reply with a new node-type file or a known-command synthesis.
  3. If novel and Claude Code is not connected: surface a `not yet learned` text response on the chat log.
- The "make it so the program would have known how to do this procedurally" is achieved by Claude Code dropping a new file into `node_types/` (which the engine's discovery picks up via hot-reload) AND by the `ChatInterpreter`'s known-command list appending the new pattern.

**Future drop-in.** Phrasing-disambiguator nodes; multi-turn parse contexts; type-system over commands so spawn-commands type-check before dispatch.

### 9. Evolving interpreter as a node-graph

**Skeleton added this session.** `ChatInterpreter` exposes its parse pipeline as connectable child nodes (token classifier, command matcher, novelty detector, response formatter). Each is a `node_types/interpreter_*.py` file; new parse layers are new files. The catalog of layers IS the language's grammar; growing the grammar is editing the graph.

**Future drop-in.** Token-by-token learning; per-user grammars (each user's `ChatInterpreter` graph diverges from a shared base); grammar inheritance via fork links.

### 10. Multi-user federation

**Skeleton added this session.** Design-only — no code, because the network surface depends on infrastructure that doesn't exist yet (a hosted MCP server is pending per Alethea's pending #005). Architectural commitment: a future `node_types/federated_registry.py` reads a shared remote node-type catalog (initially: a git URL listing other users' Apeiron repos) and lets the local engine import node-types from peers. Each user's contributions are git commits; the federated registry composes them.

**Future drop-in.** The MCP-hosted Apeiron registry (paralleling Alethea's pending HTTP/SSE MCP plan) gives every user the same node-type catalog. Queue + Claude Code on demand: a `FederationQueue` node-type holds requests; when a user requests a novel command, their local Claude Code session picks it up; when no session is available, the request waits.

### 11. Standalone operation (works without Claude Code)

**Already there.** Apeiron's engine is pure Python — no Claude Code dependency. Claude Code is one external editor of node-type files; the engine has no awareness of it. Removing Claude Code only loses the "novelty fallthrough" of feature 8; everything else still works.

**Skeleton added this session.** A `node_types/chat_interpreter.py` `claude_connected: bool` flag in state defaults to `False`. When `False`, novel commands surface "not yet learned"; everything else proceeds unchanged.

## Engine extensions this session adds

All four are **purely additive** — no existing code paths change.

1. **`View` gains three optional fields:** `gravity_mode`, `gravity_up`, `time`. Default values preserve current behavior.
2. **`engine/input.py`** — InputEvent / Binding / Bindings types; no input source wired (waiting on interactive renderer); the types are usable by tools/text_test for headless input simulation.
3. **`engine/inverse.py`** — `Engine.invert_edit(node_id, edit)` and the `invert_hook` discovery; no-op when no Generator with an invert_hook is on the path.
4. **`Engine.sim_precompute()`** — companion to `precompute()`, walks for `sim_precompute_hook` and dispatches. SimulationProbe uses it.

## Naming

`Apeiron` reads as the boundless-source primitive — fitting for the architecture but not the dream-mode aesthetic the maintainer describes. Candidates proposed in [name_suggestions.md](../name_suggestions.md).

## What this session does NOT do

- The realtime renderer (window + input loop) — design only; depends on a windowing library decision.
- Full N-D projection (only the 4D-hypercube path is wired; higher dimensions follow the same shape).
- Realistic invert hooks (the Generator's hook is stubbed; per-generator-subtype logic is future work).
- The federation registry (design only; depends on Alethea pending #005).
- The world-sphere zoom effect (composable from existing primitives; future scene).

## Tests added

One per new node-type (load + emit returns expected channel shape) plus one scene-composition test per demo scene confirming the engine assembles without errors. Existing 31 tests continue to pass.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — created as the session's design output, frozen at session close.
