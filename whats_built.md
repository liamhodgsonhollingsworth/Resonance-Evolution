# What's built — Apeiron

This page is Apeiron's index of what is implemented, what is partially implemented, and what is still open work. It is the canonical source for the project's current build state.

## What this index contains

Every load-bearing piece of Apeiron's implementation, grouped by area:

- **Engine core** — the precompute/assemble split, the manifest loader, the try/except isolation wrapper, the file-watch reload, the scene loader, the viewer state model.
- **Node types** — the catalog of node-type implementations under `node_types/`.
- **Renderers** — the catalog of renderer implementations under `renderers/`.
- **Bundle output** — the writer that emits color, depth, optional normal, optional ID, and a manifest, matching the painterly module engine's input contract.
- **Text-renderer surface** — the bidirectional LLM-facing interface for observation, action, inspection, and composition.
- **Build tooling** — scripts that run precompute, watch the graph for edits, and trigger incremental rebuilds.
- **Test suite** — tests covering node-type isolation, renderer-swap, topology walks, aggregator dispatch, and bundle output.

An item is "implemented" when it functions reliably and is in regular use. It is "partially implemented" when parts work but the full design is not in place. It is "open work" when the design exists but no implementation has been built yet.

## Engine core

- **Manifest, NodeInstance, View, Channels, EmitContext** — implemented. The core primitive types in `engine/node.py`. Channels is `Dict[str, Any]`, extensible by name; EmitContext gives nodes access to the engine for child lookup and renderer dispatch.
- **Engine.discover()** — implemented. Walks `node_types/` and `renderers/` for `.py` files, imports each, registers by `manifest().name`. Failures during discovery are recorded but don't crash discovery.
- **Engine.spawn()** — implemented. Creates a node instance from a type name and params. Wraps `build()` in try/except — failures mark the instance `dead` with an error message; the engine keeps running.
- **Engine.assemble()** — implemented. Walks the graph from a root id under a viewer, calls each node's `emit()`, composites results. Module isolation via try/except — broken nodes return placeholder channels.
- **Engine.precompute()** — implemented. Walks every spawned node; for any node-type module exposing `precompute_hook(state, engine, node)`, calls the hook and stores the result at `engine.cache[node_id]`. Wrapped in try/except — a broken hook doesn't block other nodes' precompute. New node-types that want build-time work just expose the hook; no engine change needed.
- **Engine `select_children` dispatch** — implemented in `_emit_node()`. A node-type module exposing `select_children(state, view, engine, node) -> List[str]` controls which connections the engine recurses into for this emit. Aggregator uses this to skip the target's full render at far views — runtime work is not done and thrown away when the precomputed impostor is in use.
- **Engine.reload_type()** — implemented. Hot-reloads a node-type module by re-importing its file and swapping the registration. Future work: file-watcher to auto-trigger.
- **Scene loader** — implemented as `Engine.load_scene()`. Reads `scenes/<name>.json` and spawns each node listed.
- **Default compositor** — implemented as `Engine._composite_children()`. Z-buffer for color/depth applies the same mask to normal/ids so all geometry channels stay consistent at each pixel (the depth-winner's normal and ids appear, not whoever happened to be composited last). List-concat for text. Future renderer-nodes override this for their sub-graph.
- **Topology transforms** — implemented as `Engine._apply_transform()`. Connections can carry an optional 4x4 transform applied when traversing; identity transforms are the no-op case. Non-identity transforms enable impossible-geometry node-types in future work.

## Node types

Implementations live in [node_types/](node_types/).

- **Cube** — implemented in `node_types/cube.py`. Axis-aligned cube with ray-cast emit() against AABB; produces `color`, `depth`, and `ids` channels. Lambertian-ish shading via dominant-axis approximation. Also exposes `describe()` for the text-renderer.
- **Group** — implemented in `node_types/group.py`. Container that composites its children using the engine's default compositor. No params; connections name children. Demonstrates composition-only node-types.
- **Portal** — implemented in `node_types/portal.py`. Rectangular doorway in the XY plane at z=0; ray-casts against the doorway and uses the "through" child's color for inside-doorway pixels. The 4x4 connection transform on "through" is applied automatically by the engine — the Portal node-type itself adds only rectangle masking on top of existing engine machinery. Demonstrates the topology-over-coordinates architectural commitment: impossible geometries are a node-type, not an engine feature. The `scenes/portal_demo.json` scene plus the `test_portal_renders_through_to_blue_cube` test verify both the parent-frame and through-portal rendering paths.
- **Aggregator** — implemented in `node_types/aggregator.py`. Observes its "target" sub-graph; `precompute_hook` walks the target collecting cube positions and colors, computes centroid + bounding-box + average-color (the BehaviorSummary), caches in `engine.cache`. At emit time, `select_children` returns `[]` when viewer-distance-to-centroid exceeds the threshold (skipping the target's runtime render entirely) and emit returns the colored AABB impostor; otherwise `select_children` returns `["target"]` and emit returns the target's full nine-cube composite. Demonstrates three architectural commitments simultaneously — aggregator-as-node, emergence-at-scale, and precomputation-moves-heavy-work-to-build-time. The `scenes/aggregator_demo.json` scene (3x3 grid of distinctly colored cubes wrapped in an Aggregator) plus four tests (`test_aggregator_precompute_populates_cache`, `test_aggregator_far_view_renders_impostor`, `test_aggregator_near_view_renders_individuals`, `test_aggregator_skips_target_render_at_far_view`) verify the precompute pipeline, the dispatch at both view ranges, and the runtime-work-skipping invariant.
- **Computer** — implemented in `node_types/computer.py`. Owns both a rectangular screen surface in outer world space (XY plane at z=0 in its local frame) AND the camera that renders its "running" sub-graph internally. `select_children` returns `[]` so the engine doesn't redundantly render the sub-graph under the outer view; emit() constructs an internal View from state (position, target, FOV, resolution sized to screen aspect), calls `ctx.engine.assemble(running, internal_view)` to render the sub-graph, then ray-casts the outer view against the screen rectangle and pastes the internal render via UV sampling onto inside-screen pixels. Outside pixels stay transparent so other outer-world geometry composites through naturally. Demonstrates renderer-as-node + screen-region-ownership + recursive worlds (unbounded — a Computer's sub-graph can contain another Computer; the recursion just falls out of the engine's normal traversal). The `scenes/computer_demo.json` scene (red cube in the outer world plus a Computer showing a blue cube on its screen) plus three tests (`test_computer_screen_shows_inner_cube`, `test_computer_skips_default_recursion`, `test_computer_recursion_two_levels`) verify the dispatch, the runtime-work-skipping invariant, and the unbounded-recursion claim with two nested computers.
- **Sphere** — implemented in `node_types/sphere.py`. Ray-cast against a sphere at the local origin; smooth shading from the surface normal's dot product with the camera-forward direction. Same channel contract as Cube. Demonstrates that geometric primitives are independent files; new shapes drop into `node_types/` without engine changes.
- **Plane** — implemented in `node_types/plane.py`. Bounded floor plane in local XZ at y=0; normal +Y; same channel contract. Walls and ceilings via rotation transforms on the connection. Completes the basic primitive set needed for grounded scenes (floor + objects).
- **Light** — implemented in `node_types/light.py`. Directional light source; no visual emit (renders empty channels). At precompute time, registers `{direction, color, intensity}` in the engine's shared `cache["__lights__"]` list. Other renderer-nodes (LambertianShader for now; future point/spot/area lights, shadow casters, etc.) consume from that cache. Demonstrates the "logic-as-node + cache as shared state" pattern: any node-type can register information at precompute that other node-types read at emit.
- **ChatInterface** — implemented in `node_types/chat_interface.py`. Owns a screen rectangle in the outer world that displays the contents of a chat log file. The "side channel" to Claude Code is the file itself: external LLM sessions read it to know what was said and write to it to add new turns; the node visualizes the current contents on each emit. Uses PIL ImageDraw for text-to-pixels with a system-font fallback chain. select_children returns [] (no children to render). Demonstrates the artist-authoring-loop pattern with the authoring tool living as a node inside the system being authored — closes the self-referential loop without engine-level Claude API integration. `scenes/chat_demo.json` plus `logs/sample_chat.txt` show the rendered conversation; `test_chat_interface_renders_log_text` verifies both background and text-stroke pixels are produced.

## Renderers

Implementations live in [renderers/](renderers/).

- **TextRenderer** — implemented in `renderers/text.py`. The first-class bidirectional LLM interface. Walks its wrapped sub-graph, calls each child's `describe()` (or falls back to type+params), produces structured text output via the `text` channel. Exposes `command_grammar()` listing the text commands the tools layer dispatches.
- **AsciiDebug** — implemented in `renderers/ascii_debug.py`. Renders the depth channel as ASCII art for text-mode topology debugging. Useful for verifying scene geometry from the viewer's position without opening a rendered PNG.
- **PainterlyPostProcessor** — implemented in `renderers/painterly.py`. The first bundle-consuming renderer: wraps a "source" sub-graph, reads its color + ids channels, applies palette reduction (color quantization to N levels per channel) and ID-edge darkening (pixels where the IDs channel changes get multiplied by an edge_darkening factor). Validates the bundle format as a pipeline seam — the same channel shape Apeiron writes to disk also flows through internal renderers. v1 has two effects baked in; v2 can factor each into its own renderer-node and chain them via composition. The `scenes/painterly_demo.json` scene plus `test_painterly_post_quantizes_color_and_marks_edges` verify both effects fire.
- **LambertianShader** — implemented in `renderers/lambertian.py`. Deferred-shading-style renderer-node: wraps a "source" sub-graph, reads its color + normal channels, reads the engine's `cache["__lights__"]` populated at precompute time by Light nodes, and outputs `base_color * (ambient + sum(light_color * intensity * max(0, n · -light_dir)))`. Adding new light types (point, spot, area) is a new node-type registering richer metadata in the same cache — the shader picks them up. The `scenes/lighting_demo.json` scene plus `test_lighting_demo_produces_lit_output` verify the full pipeline (Light registration, source channels consumed, lit output produced).
- **Software raster** — implemented inline as the engine's default compositor (Z-buffer over color/depth). Cubes and other geometric node-types ray-cast in their own `emit()` and the compositor stacks the results. A future explicit `SoftwareRaster` renderer-node can override this for sub-graphs that need different compositing.

## Bundle output

- **`write_bundle()`** — implemented in `engine/bundle.py`. Writes `color.png` (RGB or RGBA), `depth.png` (8-bit visualization), `depth.npy` (raw float depth), optional `normal.png`, optional `ids.png` (16-bit), and `manifest.json` (channel index, view metadata, scene metadata). Text channels land in the manifest directly. Unknown channels save as `.npy` plus a manifest reference, so new channel types pass through forward-compatibly.

## Text-renderer surface

- **Observation channel** — implemented via `TextRenderer.emit()` and `tools/text_test.describe_view()`. Produces a structured text description of the scene at the viewer's position.
- **Action channel** — implemented via `tools/text_test.dispatch_command()` plus the command grammar declared in `renderers/text.py`. Commands: describe, describe-subtree, list-types, list-nodes, spawn, connect, move, look-at, render, render-text.
- **Inspection channel** — implemented via `tools/text_test.describe_scene()` plus list-types and list-nodes commands. Surfaces node state, connection topology, and registered types as text.
- **Composition support** — implemented via the spawn and connect commands plus hot-reload (`Engine.reload_type()`). An LLM can write a new node-type file, trigger a discover/reload, spawn instances, and connect them — all through the text surface.
- **Bundle summary** — implemented as `tools/text_test.summarize_bundle()`. Reads a written bundle directory and produces a text summary of channel statistics for regression testing.

## Build tooling

- **`tools/render.py`** — implemented. CLI entry point that loads a scene, runs precompute/assemble, and writes a bundle to `output/`. Invocation: `python -m tools.render <scene>`.
- **`tools/text_test.py`** — implemented. CLI subcommands plus library functions for text-based testing: `describe`, `view`, `summary`, `command`. Designed so an LLM can verify scene state without opening a rendered image.

## Test suite

- **`tests/test_engine.py`** — implemented with 25 tests covering discovery, spawn, assemble, bundle output, the text-renderer, the command dispatcher, the visibility assertion, module isolation, Portal, Aggregator, Computer, and the PainterlyPostProcessor's quantization + edge-detection effects. Run with `pytest tests/`.

## How to modify this page

This page is an [evolving index](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/evolving_indexes.md).

- **Linking.** When a piece of implementation lands in the repo, add it under the appropriate area with a one-sentence description of what it does and its current state (implemented / partially implemented / open work).
- **Promoting.** A sub-area becomes its own page when it grows enough to warrant separate structure — for example, "Renderers" could split into a top-level Atlas entry once it has many renderer variants.

The trigger for an entry: a piece of work has changed state (implementation has started, is partial, has completed) or has been added to the project. State changes are tracked by appending a dated note rather than overwriting; the history of build state is itself part of the project's record.

## Deferred improvements

(Empty at first creation.)
