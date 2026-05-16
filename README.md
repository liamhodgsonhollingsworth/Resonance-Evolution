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

(Skeleton — entries land here as components ship.)

## Features being developed

Active in-progress work; detailed status in [What's built](whats_built.md).

- **Engine core** — the precompute/assemble split, the manifest loader, the try/except isolation wrapper, the file-watch reload.
- **Starter node-types** — Cube, Sphere, Group (geometry); Aggregator (logic-as-node); Renderer (renderer-as-node); Portal (topology-first); Computer (recursive-renderer demo); ChatInterface (Claude Code side-channel).
- **Software-raster renderer** — pure numpy plus Pillow, runs anywhere, no GPU dependency; outputs the bundle that the painterly module engine consumes.
- **Text renderer** — bidirectional text surface so an LLM can read the world's state and issue commands; the most ambitious near-term commitment, since it decouples functionality verification from human visual confirmation.
- **ASCII-debug renderer** — text-mode visualization for testing topology before the visuals work.

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
