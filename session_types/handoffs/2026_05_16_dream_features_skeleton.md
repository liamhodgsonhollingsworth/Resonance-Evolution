# 2026-05-16 — Dream-features skeleton session

The second session of the Apeiron project, immediately after the bootstrap session of the same date. The maintainer described eleven proposed features for the engine framed around "dreams, lucid dreaming, dreamlike visuals" and asked for a planning + skeleton-implementation pass: every planned feature must fit the existing architecture such that future implementation drops in as modules without rewriting.

## What this session was

A parallel-development session — design plus operational implementation. Designed how each of the maintainer's eleven features maps to the bootstrap session's architectural commitments; identified what's already there, what additive engine extensions support the remaining surface, and what skeleton node-types and renderers establish the future-implementation entry points. Built the skeleton end-to-end, including tests and three demo scenes that render correctly.

## What got built

- **Design document.** [`design/dream_features.md`](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/design/dream_features.md) — the eleven features mapped to architecture. For each: what's already there, the skeleton added this session, and the future drop-in path.

- **Engine extensions (all additive, all existing tests still pass):**
  - `engine/node.py`: `View` gains optional `gravity_mode`, `gravity_up`, `time` fields with defaults that preserve existing behavior.
  - `engine/input.py`: `InputEvent`, `Binding`, `Bindings` (with a Minecraft-style `default()` profile), `BindingContext`, `ViewMutation`, `apply_mutation()` — usable for headless input simulation now; the future interactive renderer plugs in here.
  - `engine/inverse.py`: `Engine.invert_edit(node_id, edit)` walks to the nearest node with `invert_hook`, calls it, applies the parameter delta to the connected Seed, re-precomputes. Lazy import in `engine/core.py` avoids a circular dependency.
  - `engine/core.py`: `Engine.sim_precompute()` companion to `precompute()`, walking `sim_precompute_hook` and storing trajectories at `cache[node_id + "__sim__"]`.

- **Seven new node-types** (`node_types/`):
  - `dimension_n.py` — N-dimensional shape primitive emitting raw N-D verts/edges on named channels. v1 shapes: `hypercube`, `simplex`, `cross_polytope`.
  - `seed.py` — parameter holder for procedural generation; no visual emit; consumed by Generator.
  - `generator.py` — reads connected Seed at precompute time, produces a content spec, inline-rasterizes via emit, exposes `invert_hook` for the inverse-pass dispatch.
  - `gravity_field.py` — region with its own gravity vector; registers in `cache["__gravity_fields__"]`; helper `active_field(engine, position)` for the input system to query.
  - `key_bindings.py` — Settings-shaped node wrapping `engine.input.Bindings`; registers active scheme in `cache["__active_key_bindings__"]`.
  - `simulation_probe.py` — pre-simulates `step()` interactions over a horizon at sim_precompute time; emit exposes trajectory on a `simulation` channel.
  - `chat_interpreter.py` — parses chat-log messages into engine commands; classifies known/novel/noise; when `claude_connected: true`, writes `requested:` lines back to the log for Claude Code to pick up.

- **One new renderer** (`renderers/`):
  - `projector_n.py` — ProjectorN. Wraps an N-D sub-graph, projects N-D vertices into 3D (orthogonal `drop` or `perspective_4d`), rasterizes edges via Bresenham line draw into standard color/depth/ids. The dim4_cube demo's tesseract renders cleanly.

- **Three new scene demos** (`scenes/`):
  - `dim4_cube_demo.json` — tesseract via DimensionN + ProjectorN. Renders the classic 4D-cube perspective projection.
  - `seed_world_demo.json` — three green cubes generated from a Seed via Generator. Verified the precompute → emit path and the invert_edit dispatch via test.
  - `dream_topology_demo.json` — viewer room with portals connecting to three differently-colored rooms with non-Euclidean transforms. Builds on the existing Portal architecture commitment.

- **26 new tests** in `tests/test_dream_features.py` — covers every new component and every demo scene. All 57 tests pass (31 bootstrap + 26 dream-features).

- **Name suggestions** in `name_suggestions.md` — dream-related candidates with reasoning. Recommendation: Oneiron (one-letter shift from Apeiron preserving Greek-philosophy lineage and pairing with Alethea). The maintainer's call stands.

- **whats_built.md updates** — every new piece tagged with its implementation status; the engine-extension entries reflect the View extension fields, sim_precompute, invert_edit, and the input-system surface.

## Coverage of the maintainer's eleven features

Each is now backed by either existing architecture or this session's skeleton:

1. **Mouse look + scroll zoom** — covered by existing View fields + the new engine/input.py bindings + Bindings.default(). Realtime renderer (window + input pump) deferred to a future session — depends on a windowing-library choice.
2. **Zoom = scale, not position** — already there. View.scale is the LOD/zoom parameter; aggregators dispatch by projected size.
3. **Arbitrary dimensions, rendered via 3D projection** — DimensionN + ProjectorN cover the architecture; v1 ships 4D-hypercube with perspective projection. Higher dimensions and other shapes are new params on DimensionN or new projection branches on ProjectorN.
4. **Node-graph rooms with arbitrary topology** — already there. Portal + non-identity connection transforms. dream_topology_demo.json composes it.
5. **Minecraft-like controls + gravity toggle** — covered by Bindings.default() + the View extension fields + GravityField + KeyBindings. Realtime renderer plugs into this surface.
6. **Procedural world seeds with inverse-update** — covered by Seed + Generator + Engine.invert_edit + invert_hook. v1 demonstrates trivial direct-update inversion; future Generators implement gradient/learned inverters.
7. **Pre-simulated interactions** — covered by Engine.sim_precompute + SimulationProbe + sim_precompute_hook. Future step()-implementing node-types populate richer trajectories.
8. **Chat-driven world building with novelty fallthrough** — covered by ChatInterpreter. v1 surfaces `requested:` lines when claude_connected; future parse-pipeline layers chain via connections.
9. **Evolving interpreter as node-graph** — ChatInterpreter's design names the future layer-chaining; v1 ships an inline classifier.
10. **Multi-user federation** — design-only this session. Depends on hosted MCP / federated registry, which depends on Alethea pending #005.
11. **Standalone operation (works without Claude Code)** — already there. Claude Code is one external editor; the engine has no awareness of it. ChatInterpreter's `claude_connected: false` mode confirms novelty surfaces "not yet learned" without Claude Code.

## Tests and stress-testing

- 57 tests pass on Python 3.14.5 (`pytest tests/`).
- All three new demo scenes render to bundles cleanly (`python -m tools.render scenes/dim4_cube_demo.json --output output/dim4_cube` and the other two).
- The tesseract render visually verifies the perspective-4d projection (classic cube-inside-cube hypercube projection).
- The seed_world render shows three green cubes from the Generator's precompute.
- The dream_topology render shows the viewer room with the through-portal view of an adjacent room.

## Architecture choices worth flagging

- **Generator inline-rasterizes rather than dynamically spawning child Cube nodes.** Dynamic spawning during precompute would require either snapshotting `engine.nodes.items()` (an engine change) or re-architecting precompute to handle spawn-during-iteration. v1 sidesteps with inline ray-cast inside Generator.emit(). Future Generator versions can refactor to spawn real Cube nodes if needed; the interface (`invert_hook`, the `seed` connection convention) doesn't change.

- **invert_edit checks the starting node first, then walks parents.** Initial implementation only walked parents, which broke the API when callers pass the Generator id directly. The fix is in `_nearest_inverting_ancestor` — the starting node is now in the frontier. Both edit-the-output (start at Generator) and edit-a-descendant (start at a child) work.

- **The cache key for sim_precompute is `node_id + "__sim__"` rather than overwriting `node_id`.** A node can carry both a regular precompute result (Aggregator impostor) and a simulation trajectory side-by-side. Separate slots prevent collision.

## What's deferred to future sessions

- **The realtime interactive renderer.** `renderers/interactive.py` — wraps a windowing library, pumps `InputEvent`s through the active KeyBindings, applies ViewMutations between frames, calls the existing assemble pipeline at the framerate. Needs a windowing-library decision (moderngl-window, pygame, browser-via-WebGL). Skeleton present in `engine/input.py`; the renderer is the missing piece.
- **Generator subtypes with rich inversion.** v1's invert_hook handles direct-update on `cube_position`; future Generator subtypes (terrain, plants, agents) implement gradient-based inversion or learned inverters.
- **The world-sphere zoom effect.** Composable from existing Sphere + Computer + Portal + Seed; a future `node_types/world_sphere.py` packages them together.
- **The federation registry.** Depends on hosted MCP (Alethea pending #005). Naming proposed in the design doc.
- **L-systems, point/spot/area lights, focus-state for Computer.** All on the bootstrap session's suggested-next-session list, all still open.

## Suggested next-session priorities

The maintainer's call. Most-leverage candidates:

1. **Realtime interactive renderer.** Pick a windowing library (recommendation: moderngl-window for hardware-accel, or pygame for portability), wrap the engine, plug into `engine/input.py`. Closes the loop from input → view-mutation → render. The skeleton this session built makes the wiring straightforward.
2. **File-watch hot-reload + interactive viewer.** From the bootstrap session's #1 suggestion. Pairs naturally with the realtime renderer above; both share the run-loop architecture.
3. **A second Generator subtype.** Demonstrate the architecture's "different generators have different inversion algorithms" promise — e.g. a `TerrainGenerator` that tunes a `roughness` parameter via gradient when the user edits a height.
4. **Trajectory renderer.** Consumes SimulationProbe's `simulation` channel and overlays predicted paths. Validates the sim_precompute pipeline end-to-end with a visible artifact.
5. **L-systems node-type** (still open from bootstrap).
6. **The world-sphere zoom effect.** Compose Sphere + Computer + Portal + Seed into a single node-type. Establishes a pattern for "complex visual effect as a composite node-type."

## Memory entries this session would propose

(None promoted to MEMORY.md this turn — the work falls cleanly under existing rules. The `apply_mutation`'s local-frame translation convention is repo-specific; the `__sim__` cache-key convention is engine-internal; both are documented in code comments where they apply.)

## Open questions for the maintainer

Routed via the Communication block of the final response. The name suggestion is the only thing requiring maintainer judgment this session; the implementation choices fell inside the standing authorization.
