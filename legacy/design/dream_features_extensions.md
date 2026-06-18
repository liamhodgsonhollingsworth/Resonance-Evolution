# Dream-features extensions — additional features + generalizations

Continuation of [dream_features.md](dream_features.md). Produced during the same session's remaining-context-budget pass per the [use-full-context-budget convention](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/discipline.md). Two sections: (A) additional features in the dream-mode direction that compose with the existing architecture, and (B) more generalizable variants of the original eleven features.

## A. Additional features

Each entry: what the feature is, how it composes with existing architecture, future-implementation shape.

### 1. Time as a navigable dimension

`View.time` already exists. Combined with the append-only per-edit-creates-new-node convention, a `TimeRewinder` node-type reads the project's git history (or a local "Seed-versions" log) and exposes scrub controls. Walking backward through time means viewing the scene-at-revision-N rather than scene-current. Composes with the inverse-pass: every Seed mutation produces a new version; the rewinder navigates the version sequence.

### 2. Sound as channels

A new channel name (`audio`) carrying mono/stereo waveforms or frequency-domain data. A `SoundNode` node-type emits to it; a `SpeakerRenderer` renderer-node consumes it (and the existing image renderers ignore it). Spatial audio falls out of the topology primitive: a sound emitted in room B and heard through a Portal from room A is just the Portal's `_apply_transform` applied to the audio source's position the way it's applied to a visual source's. Same engine machinery.

### 3. Co-presence — multiple viewers in one engine

Multiple `View` instances in one engine; each one renders its own perspective; other viewers appear in each other's renders as `Avatar` nodes that take a view-id and render its position+orientation as a humanoid (or any) shape. Composes with renderer-as-node — each viewer's rendering is a renderer-node owning a screen-region. Federation (feature 10 of the original eleven) is co-presence across machines; same primitive.

### 4. Persistent dreams — engine state across sessions

A `cache_persist_hook(state, engine, node) → bytes` companion to `precompute_hook`. Engine writes the bytes to disk at session close; reads them at session start. Nodes that produce persistent state (Generator's specs, ChatInterpreter's output_log) implement the hook; others don't. The cache-as-shared-state pattern extends naturally to disk.

### 5. Forces and fields beyond gravity

`GravityField` generalizes to `ForceField` — gravity is one force-vector type. Magnetism, fluid currents, attractor points, repulsor regions: each is a new node-type registering in `cache["__force_fields__"]` with a `kind` field. A future physics-step renderer-node reads the list and applies the union of forces to any node-type with mass. The current GravityField becomes `ForceField(kind="gravity")`.

### 6. Constraints as nodes

A `ConstraintNode` observes two or more target nodes and enforces a relationship (distance, orientation, color-match, semantic-equivalence). The relationship is itself a node. Generalizes aggregator-as-node from "summary of children" to "relation between siblings." Many emergent dream-mode effects (objects that move together, walls that stay parallel, lights that match across rooms) become constraint-nodes rather than ad-hoc emit logic.

### 7. Dream-logic transitions between scenes

A `DreamTransition` node-type interpolates between two scenes via cross-fading both image and topology over a configurable duration. Composes with the multi-scene file system already present (a transition is just a node-type that loads two scene files and weights their outputs). Walking between dreams isn't a cut — it's a slow morph that feels like dream-logic substitution.

### 8. The dream is rendering you — gaze-driven adaptation

A reverse channel where the renderer reports which pixels the viewer is looking at (from gaze tracking, head pose, or click-attention as a proxy). A `GazeReader` node consumes this and feeds back into the world: nodes that detect the viewer's attention modify their own state. Composes with cache-as-shared-state — gaze data flows through `cache["__viewer_attention__"]`.

### 9. Resonance-driven node ordering

From the meta-layer's [resonance-based link ordering](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/ideas/resonance_based_link_ordering.md) idea applied locally: nodes that are visited often by users get rendered with more detail (impostor stays expanded longer); nodes that are rarely visited get coarse impostors even at close-up views. Aggregator's threshold becomes a function of `visit_count` rather than just distance. Closes the loop with truth-as-resonance from the theory of everything.

### 10. Dreams about dreams — scene as content

A `SceneEmbed` node-type whose `content` connection points to another scene file. At precompute, the embedded scene is loaded into the parent engine; at emit, it composes as a sub-graph. Recursion-via-Computer already supports this architecturally; SceneEmbed is the convenience wrapper. Combined with the federation primitive: the embedded scene can live in another user's repo.

## B. More generalizable variants

For each of the original eleven features, the underlying primitive that absorbs it plus a wider future. Most are already shaped at the right generality; three have room to push further.

### B1. Input-as-channel (generalizing original feature 1, 5, 8/9)

The current `engine/input.py` is an explicit subsystem with `InputEvent` and `Bindings`. The more general primitive: input is a channel. A `Mouse` node-type emits `input` channel; a `Keyboard` emits the same channel; a `Gamepad` emits the same; a `Voice` emits the same; a `BCI` emits the same. Any node consuming input subscribes by reading the channel. Bindings become a node-type that transforms input channels into mutation channels. The realtime renderer subscribes to mutation channels and applies them.

This unifies features 1 (mouse-look), 5 (Minecraft controls), and 8/9 (chat input) — all are different sources writing to one channel name. The `Bindings` table generalizes from "keyboard map" to "channel rewriter."

**Migration cost:** small. The current `InputEvent` dataclass is already the channel content type; making it a channel just means swapping which side of the engine it flows through. The hot-reload of bindings becomes hot-reload of a `Bindings` node-type — already supported.

### B2. Mutation-with-inverse as first-class (generalizing original feature 6)

The current invert_hook is on Generator. The more general primitive: any mutation has an associated inverse. The engine carries a `MutationLog` (append-only); each entry is a `(node_id, change, inverter_id)` triple. Undo is replay of the log in reverse; redo is forward replay. The current invert_edit is a special case where the inverter happens to be a Generator and the mutation happens to be a content edit.

Unlocks: full undo/redo across the entire engine state; time-as-navigable-dimension (feature A1 above); cross-session reverts at any granularity; collaborative editing with conflict resolution via mutation ordering.

**Migration cost:** medium. Existing edits go through ad-hoc paths; routing them all through MutationLog needs a discipline pass. Worth it because every other "history-related" feature (timeline, federation, undo) snaps to this primitive once it exists.

### B3. Federated node-types as first-class import (generalizing original feature 10)

The current federation design is "register a remote URL → mirror its node-types." The more general primitive: node-types ARE importable like Python modules — `import some_user.dream_renderer` resolves through a peer registry the same way `import os` resolves through `sys.path`. A user adding a new node-type doesn't republish a registry; their git repo is the registry. The engine's discovery pass walks not just local `node_types/` but also `peers/*/node_types/` (or equivalent).

Unlocks: any user's node-type becomes available to any other user transparently; the "Claude Code drops a file" loop from feature 8 extends across users; per-NPC grammars from feature A6 propagate naturally.

**Migration cost:** depends on hosted infrastructure. Same dependency as Alethea pending #005. The architectural primitive doesn't require it — local checkouts of peers' repos work today.

## The meta-generalization

Across both sections, one pattern recurs: **named channels carry everything**. Input is a channel. Output is a channel. Forces are a channel-list in cache. Gaze is a channel-write-back. The mutation log is a channel-on-edit. Federation makes node-types channel-consumers in a wider namespace.

The current `Channels = Dict[str, Any]` extensible-by-name primitive is already correct. Future Apeiron features should be evaluated against the test: *does this work as a new channel name + a node-type that produces it + a node-type that consumes it?* If yes, the architecture already supports it without engine changes. If no, the architecture needs an extension; the extension itself should be a new channel or a new hook, not a special-case subsystem.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — produced once during the dream-features skeleton session, frozen at session close.
