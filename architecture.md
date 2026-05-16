# Architecture

The load-bearing design commitments behind Apeiron. Each commitment is named, justified, and traced to the primitive it rests on. Future implementation work and review apply against this document.

## The unifying primitive

Every node implements one function:

    emit(viewer, state) → (named channels, transition hints)

The node decides internally whether to render itself, recurse to children, or return an aggregate impostor. Channels are extensible by name (`color`, `depth`, `normal`, `id`, plus arbitrary additional channels). Three independent prior-art lines — procedural node modeling (Houdini, Geometry Nodes, Grasshopper, TouchDesigner, Nuke), scale-invariant rendering (Nanite, terrain LOD, L-systems, No Man's Sky), and impossible geometries plus modular engines (Portal, HyperRogue, Bevy, Godot, Three.js) — converge on this primitive. Every capability in the engine is a choice of node-type, not an engine feature.

## Topology, not coordinates, is the position primitive

A node carries a local frame and typed connections to neighbors. Each connection is annotated with a transform. The viewer's position is "what node am I in plus what local-frame offset"; global coordinates are derived per-frame by walking adjacency from the viewer. Euclidean space is the specific case where connection-transforms compose to identity around every cycle; impossible geometries are the general case. Portals, world-wrapping, gravity-shifts, perspective tricks, hyperbolic tiling, and 4D-slicing are all regular nodes with non-identity-composing connection-transforms — no special-casing.

## Recursion depth is the level-of-detail mechanism

A node decides whether to render itself or recurse based on its projected screen-size at the current viewer. When a feature subtends less than a pixel, the node returns its aggregate form instead of expanding. This is the L-system pattern (stop expanding when the smallest feature is sub-pixel) and Nanite's cluster pattern (descend until cluster projects to less than one pixel) operating off the same primitive. There is no separate LOD step.

## Aggregation is a first-class node-type, not a method

Aggregation rules are `Aggregator` nodes that observe target nodes and produce coarse-scale output. A `Plant` node has its leaf-level rules; a separate `PlantCellularAggregator` node observes the Plant at a given scale and produces the aggregate appearance plus a behavior summary. New emergence approaches — statistical, learned, simulated, ML-derived — become new aggregator-node-types added without engine changes. Multiple aggregators can connect to the same target for experimentation. The general principle: any function of nodes is itself a node. Constraints, physics, dispatch tables, and the relationship between renderers and the objects they render all live as nodes in the same graph. There is no separate logic layer.

## The wire payload is a channel dictionary, extensible by name

Every `emit()` returns `{channel_name → array}` at the render resolution. A node consumes the channels it knows about, ignores the rest, and writes whatever it produces. The painterly module engine's input contract (color, depth, optional normal, optional ID) becomes one fixed channel-set in this richer space. New channels never break existing consumers.

## Module isolation is a try/except wrapper plus typed-zero fallback

Every `emit()` call is wrapped in try/except. A broken node returns a typed-zero placeholder; the rest of the scene renders. The same wrapper handles hot-reload via `importlib.reload`. A broken module never crashes the engine. A node added by Claude Code that contains a bug fails in isolation; debugging that one node fixes that one behavior, and the rest is already working because behavior is emergent and per-node.

## Renderers are nodes that own screen-regions, not just world-regions

A renderer-node carries both a scope-predicate (which world-nodes it owns) and a screen-region predicate (which output pixels it owns). The engine's traversal partitions nodes by their declared renderer and dispatches each partition; results composite by region. This is what lets sections of the screen render independently — a Paint window on a computer renders with a 2D-paint renderer while the world around it renders with a 3D renderer.

## Recursive worlds fall out of renderer-as-node

A `Computer` world-node has a screen-area (a rectangle in world-space) and a target sub-graph (the software running on it). The Computer's declared renderer renders the sub-graph into the screen-area as an image patch; the outer world's renderer composites that patch into the world view. When the viewer focuses on the screen, the outer world's renderer is no longer dispatched and the Computer's renderer takes the full output. The software running on the computer is one more sub-graph with its own renderer. Recursion is unbounded.

## Text-renderer is a first-class node-type, bidirectional

A `TextRenderer` node-type renders the graph into a text description of the world (what's visible, what's nearby, what state the world is in) AND accepts text commands that mutate the graph or move the viewer. This decouples functionality verification from human visual confirmation: once the visual renderers are confirmed working, Claude Code can build new features using only the text-renderer surface and trust that what works for text also works for visuals (because the graph is the same).

The text-renderer is the LLM-friendly interface. It exposes:

- **Observation** — descriptions of what's in the world at the viewer's current position and scale.
- **Action** — text commands the LLM can issue (move, add, edit, link, render-this-scene-now).
- **Inspection** — text representations of node state, connection topology, and dispatch tables.
- **Composition** — the ability to write new node-types and renderers, then use them immediately via hot-reload.

In the limit, an LLM interacting only through the text-renderer can build composite tools, verify them by their text output, and improve the system with no human in the loop on each iteration. The user's role becomes confirming aesthetics and direction rather than gating every feature.

## Precomputation moves the heavy work to build time

The engine has two phases:

- **Build** — walk the graph, precompute aggregations at every scale of interest, cache rendered intermediates, build dispatch tables.
- **Runtime** — viewer state assembles precomputed pieces from the cache.

Scale transitions happen slowly enough that build keeps up; if a transition reaches a scale not yet precomputed, the engine shows a placeholder and queues that scale for build. Claude Code edits trigger incremental rebuild of only the affected sub-graph. This is what makes "most logic worked out automatically prior to things happening" architecturally true — emergence is computed once at build, used many times at runtime.

## Forward-compatibility checks

Every requirement maps to architecture without retrofitting:

- **Scale-invariant rendering** — recursion-depth-by-projected-pixel-size.
- **Microscopic-to-macroscopic emergence** — aggregator-as-node, precomputed at build time.
- **Single-world spatial model with distance culling** — traversal stops when projected size drops below threshold; distant things cost nothing.
- **Impossible geometries** — connection-transforms that don't compose to identity.
- **Module-isolated failures** — try/except wrapper, typed-zero fallback.
- **Renderer-swap mid-walk** — per-node renderer-id, screen-region partitioning.
- **Recursive computers** — renderer-as-node, screen-region-ownership.
- **Claude Code chat as in-system feature** — chat is one more renderer-node with a side-channel.
- **Static-first, real-time-later** — same graph drives both; a future interactive renderer is one more renderer-node-type.
- **Claude-Code-builds-features** — new node-types and renderers are files that drop into directories the engine watches.
- **Text-only interaction** — TextRenderer node-type, bidirectional, exposes observation and action as text protocol.
- **Precomputation as engineering centerpiece** — build/runtime split, incremental rebuild.

## Minimum first build

Around 300 to 500 lines of Python. A node-type is one file in `node_types/` exposing `manifest()`, `build(params) → state`, optionally `step(state, dt, neighbors) → state'`, and `emit(state, view) → channels`. A scene is one JSON file in `scenes/` describing the node graph (`{type, params, connections}` per entry). The engine loads the scene, walks from the viewer's node, partitions by renderer, composites. Output is a bundle directory matching the painterly engine's expected input.

Starter renderers: software-raster (pure numpy plus Pillow), ASCII-debug (text-mode), and TextRenderer (LLM-facing bidirectional surface).

Starter node-types: Cube, Sphere, Group (geometry); Aggregator (logic-as-node demo); Renderer (renderer-as-node demo); Portal (topology-first demo); Computer (recursive-renderer demo); ChatInterface (Claude Code side-channel demo); TextRenderer (text-interaction demo).

Each is one file. The viewer is a dataclass; movement is a state mutation that triggers re-assemble without rebuild. Graph edits trigger incremental rebuild of the affected sub-graph.
