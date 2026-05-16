# *"Any sufficiently immersive science fiction work is indistinguishable from reality."*

# Apeiron

A node-graph engine for building, rendering, and inhabiting worlds. Every world-object, every renderer, every aggregation rule, every text-interaction surface is a node. The graph is the medium; renderers are nodes that turn the graph into output (visual, textual, or compositional); aggregation nodes turn fine-scale structure into coarse-scale emergent behavior. Produces image bundles (color, depth, optional normal, optional ID) that feed the [painterly module engine](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/ideas/painterly_module_engine.md) and exposes a text-renderer surface so Claude Code can interact with the world as fully as a human could. A project in the [Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront) network.

## Atlas

- **[Current state](whats_built.md)** — canonical index of what is and is not implemented for Apeiron, listing every node-type, renderer, engine module, and tooling component with implementation status.
  - **[Tools and features that exist](#tools-and-features-that-exist)** — the working components of the engine: the engine core, the node-type catalog, the renderer catalog, the bundle output.
  - **[Features being developed](#features-being-developed)** — active in-progress work: the text-renderer surface, aggregator-as-node, recursive-renderer demos, the Claude Code chat interface.
- **[Architecture](architecture.md)** — the load-bearing design commitments: the single `emit` primitive, topology over coordinates, channels-by-name wires, aggregator-as-node, renderer-as-node, build-vs-runtime split, module isolation, text-renderer as first-class.
- **[Node types](#node-types)** — the catalog of node-type implementations; each is one file under `node_types/`.
- **[Renderers](#renderers)** — the catalog of renderer implementations; each is one file under `renderers/`.
- **[Scenes](#scenes)** — the data graphs that get rendered; each is one JSON file under `scenes/`.
- **[Engine](#engine)** — the core code that loads node-types, walks the graph, precomputes aggregations, and assembles frames.
- **[Conventions](#conventions)** — project-specific conventions; the meta-layer's apply by default.
- **[Meta-conventions](#meta-conventions)** — the meta-layer's apply directly; project-specific overrides land here.

This page is a [static index](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/index_pages.md).

## Tools and features that exist

Major working components of Apeiron. The high-level shape is here; detailed status, sub-features, and open issues live in [What's built](whats_built.md).

- **Engine core** — discovery of node-type files in `node_types/` and `renderers/`, spawn with try/except isolation, assemble walking the graph from a viewer with module-isolated emit() calls, default Z-buffer compositor plus list-concat text compositor, scene loader from JSON, hot-reload entry point.
- **Cube node-type** — axis-aligned cube with ray-cast emit() against AABB; produces color, depth, and IDs channels with Lambertian-ish shading.
- **Group node-type** — container that composites its children via the engine's default compositor.
- **Portal node-type** — rectangular doorway whose "through" connection's 4x4 transform places the far-side sub-graph at any pose; demonstrates topology-over-coordinates, since impossible geometries fall out of non-identity connection transforms rather than special-cased engine code.
- **TextRenderer** — the first-class bidirectional LLM-facing surface; walks its wrapped sub-graph, produces structured text output (view state, scene topology, observations, command grammar) via the `text` channel.
- **AsciiDebug renderer** — depth channel rendered as ASCII art for text-mode topology debugging.
- **Bundle writer** — emits `color.png`, `depth.png`, `depth.npy`, optional `normal.png` and `ids.png`, and `manifest.json` matching the painterly module engine's input contract.
- **CLI tools** — `python -m tools.render <scene>` writes a bundle; `python -m tools.text_test` provides describe/view/summary/command subcommands for text-based testing.
- **Text testing tools** — `describe_scene`, `describe_view`, `summarize_bundle`, `dispatch_command`, `assert_visible` — the LLM-facing verification surface; once visuals are confirmed, new features can be built and verified through these tools alone.
- **Test suite** — 15 pytest tests covering discovery, spawn, assemble, bundle output, text-renderer, command dispatcher, visibility, and module isolation (a deliberately-broken node-type doesn't crash the engine).
- **Starter scenes** — `scenes/hello_cube.json` (single cube, raster output) and `scenes/text_demo.json` (TextRenderer wrapping a group of cubes).

## Features being developed

Active in-progress work; detailed status in [What's built](whats_built.md).

- **Aggregator-as-node** — first-class node-type for coarse-scale emergence rules; precompute extension point exists in the engine but no Aggregator type yet.
- **Computer node-type** — recursive-renderer demo where the viewer can focus into a screen-region and the outer world stops rendering.
- **ChatInterface node-type** — Claude Code side-channel demo, instantiating the artist-authoring-loop pattern within the engine.
- **File-watch reload** — auto-trigger hot-reload when node-type files change on disk.
- **More node-types and renderers** — Sphere, Plane, Cylinder, painterly post-processor, OpenGL renderer, browser renderer, etc.

## Node types

(Skeleton — node-type implementations live in `node_types/` and migrate into individual page entries here as they stabilize.)

## Renderers

(Skeleton — renderer implementations live in `renderers/` and migrate into individual page entries here as they stabilize.)

## Scenes

(Skeleton — scene graphs live in `scenes/` and migrate into individual page entries here as they stabilize.)

## Engine

(Skeleton — engine code lives in `engine/` and migrates into individual page entries here as it stabilizes.)

## Conventions

Project-specific conventions iterate here through standard pull request. The [conventions of the Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/tree/main/conventions) apply by default; entries here override or extend them for this project.

(No project-specific conventions yet.)

## Meta-conventions

This project follows the [meta-conventions of the Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront#meta-conventions). Project-specific overrides or additions land here; the same maintainer-gating applies.

(No project-specific overrides yet.)

## License

[MIT License](LICENSE) — placeholder; the license stack is a deferred decision at the meta-layer.
