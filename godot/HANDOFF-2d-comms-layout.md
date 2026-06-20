# MASTER HANDOFF — general-purpose 2D communication layout (read this FIRST)

Status 2026-06-20. **Every parallel session working on this initiative reads this doc first.** It
states the vision, the priority order, what already exists, and how the work is divided into
parallel tracks. Detailed thread handoffs: `HANDOFF-canvas-chat.md` (the substrate shipped so far),
`HANDOFF-no-fundamental-primitives.md` (the core architecture pivot, in `vibrant-elion-937d68`).

## The vision (Liam's words, hold these)
A **general-purpose 2D communication layout** with **many methods of serializing the information
according to context, instructions, and tools**. Not all of it has to be built at once — Liam needs
to **design and iterate on it ASAP**. Concretely:
- **ASAP:** a single **2D infinite canvas** Liam can start working on, **hotloaded and iterated in
  different areas**.
- **Fundamentally connected to the Godot engine, but SOURCE-INDEPENDENT**, so it works with **Claude
  Cowork as soon as possible**.
- **Modular / node-based** enough to support **automatic syncing + integration** between content on
  Cowork and content on this system (developed, coded, hotloaded), with **real-time cross-system
  work** through the connections (and the node system).

## Priority order (non-negotiable)
1. **CONNECTIONS FIRST.** The connections between nodes and between systems must be **as robust and
   filled-out as possible BEFORE extensive features**. Features come later, and **only if they work
   across the connections**.
2. **A 2D infinite canvas to work on ASAP** — source-independent, hotloadable, area-based.
3. **Live Cowork integration ASAP** via the public URL **resonancewavefront.org** (a tunnel is
   **already running** there).
4. **MVP = live integration + features across ONE domain**, with the other domains developed in
   parallel. I.e. one end-to-end loop working live across the connection fabric, not all features
   everywhere.

## What already exists (the substrate — shipped + verified, see HANDOFF-canvas-chat.md)
ONE canonical *arrangement* (the node graph) + a **graph↔text protocol** + a **typed graph-action
vocabulary**; every renderer/transport is a dumb delegate. Fractal **Chip** substrate (recursive,
lossless fold/unfold) carried on from `vibrant-elion` + completed. **Message** node taxonomy.
`ConvoProtocol` (GDScript) + parity Python port. A **no-key local stdio MCP server**
(`bridge/graph_mcp.py`) with read tools + approval-gated propose-then-commit writes + fractal tools.
Diagram/image nodes via the one `graph_propose` DSL. All green; project `.mcp.json` registers it.

This substrate IS the foundation the tracks below build on. **Connections + canvas + Cowork are the
priority; the substrate already gives you the shared data contract to connect across.**

---

## Parallel tracks (the division)

### Track 1 — CONNECTION FABRIC  ⟵ TOP PRIORITY, gates the others
**Goal:** node↔node and **system↔system** connections, as robust and complete as possible, with
**automatic real-time cross-system sync** (Cowork ↔ engine ↔ canvas, all editing the same graph
live). This is the spine; everything else plugs into it; features land only across it.
**Owns:** the protocol + transport contracts — `runtime/convo_protocol.gd`,
`bridge/convo_protocol.py` (+ `chip_ops.py`), `bridge/graph_mcp.py` — and a NEW **sync layer** that
keeps `live/arrangement.json` (engine hotload), the MCP server, and the remote/Cowork side in
real-time agreement (extend `runtime/live_host.gd`'s content-hash watch into a bidirectional sync;
conflict = append-only + approval gate; later CRDT for true multi-writer).
**First steps:** harden the action vocabulary + validation + conflict semantics; build the
bidirectional sync daemon (file-watch ↔ MCP ↔ remote); define the connection contract every other
track imports. **Done when:** two systems edit the same arrangement and see each other live, robustly.
**Branch:** `claude/comms-connections`.
**Slice 1 SHIPPED (2026-06-20):** the hardened, conflict-safe **connection contract** — read
`godot/CONNECTION-CONTRACT.md` (Track 2 + Track 3 import it). Adds a structural validation gate
(`convo_protocol.validate_actions(arr, actions)` + `validate_arrangement(arr)`, GD↔Py parity) and a
**conflict-safe rebasing commit** in `bridge/graph_mcp.py` (proposals store delta+base_hash; commit
re-derives against the current file — concurrent append-only edits rebase, structural ops require an
unchanged base, corrupting commits are rejected, never clobbered). Verified: `test_graph_logic.py`
19/19, `test_sync_logic.py` 14/14 (two-writer no-clobber proof), `headless_convo_test.gd` 17/17.
*Still open for Track 1:* the bidirectional sync daemon + `rev` ordering, and routing every writer
through the contract — **Track 2's adoption** (flagged in the contract doc §4).
**Slice 2 SHIPPED (2026-06-20):** the contract is now **importable** — `bridge/graph_store.py`
(stdlib) exposes `commit_actions(live_dir, actions)` (reload→validate→append-only apply→soundness→
atomic write); `graph_mcp.py` refactored onto it (one implementation, no duplication). Validation
gained **cycle rejection** (the parent graph must stay a DAG) in both ports. Verified:
`test_graph_logic.py` 22/22, `test_sync_logic.py` 17/17 (now incl. a direct-seam no-clobber test),
`headless_convo_test.gd` 19/19.
**⟹ Track 2 (`canvas_bridge.py`, worktree `vigorous-pike-edcf46`): adopt the seam** — call
`graph_store.commit_actions` for `/api/reply` (Claude's append-only contribution) instead of raw
`_load`/`_save`; that gives cross-process conflict-safety for free. Liam's direct authoring stays
self-approved but should validate against the shared gate. (Track 2 also independently added a cycle
check — now unified into `convo_protocol`, so it can drop its local one on adoption.)

### Track 2 — 2D INFINITE CANVAS  ⟵ the surface Liam works on, ASAP
**Goal:** a single **2D infinite canvas** in Godot that renders the canonical arrangement (a dumb,
source-independent delegate), supports infinite pan/zoom + place/move/connect, is **hotloadable**,
and is **iterated in different AREAS** (the areas model from `[[workflow-surface-decisions]]`:
switchable frames/areas, namespaced). Liam designs and iterates on THIS.
**Owns:** NEW `canvas/` (2D infinite canvas scene + area model), reusing `editor/graph_panel.gd`
(GraphEdit delegate) + `runtime/live_host.gd` (hotload). Keep ALL view/zoom/area UI state OUT of the
arrangement data (renderer-independence).
**First steps:** an infinite 2D canvas that loads `live/arrangement.json`, renders nodes/wires, and
hotloads on change; area namespacing (`?area=` / `user://areas/<id>/`). **Done when:** Liam opens the
canvas, lays out the graph, and it hotloads live as the data changes.
**Branch:** `claude/comms-2d-canvas`.

### Track 3 — COWORK @ resonancewavefront.org  ⟵ live public connection, ASAP
**Goal:** the SAME `graph_mcp.py` core exposed over **Streamable-HTTP at resonancewavefront.org**
(tunnel already running) as an OAuth custom connector for **Cowork + regular Claude web**, plus the
parallel methods (paste-the-link; hosted copy-paste bridge). No Anthropic key.
**Owns:** `bridge/graph_mcp.py --transport streamable-http` + OAuth, and the website pieces in the
**Resonance-Website** repo (the connector endpoint, paste UI) served at resonancewavefront.org.
**First steps:** run the server over the existing tunnel; add OAuth 2.1/PKCE/DCR; register as a
Cowork custom connector; verify no-key (`/mcp`, `/status`). **Done when:** Cowork edits the live
graph at resonancewavefront.org and changes round-trip through Track 1's sync into the engine/canvas.
**Branch:** `claude/comms-cowork-remote` (+ work in Resonance-Website).

### Track 0 — no-fundamental-primitives (EXISTING in-flight session — coordinate, don't recreate)
The frame-relative / type→definition core generalization (`HANDOFF-no-fundamental-primitives.md`,
6 open questions for Liam). Tracks 1–3 build on the **Chip seam**, which is forward-compatible
("gains generalization, no rework"). **Coordinate before any deep edit to `graph_runtime.gd` /
`prim_chip.gd` / `primitive.gd`** — they are this track's territory.

## The MVP (the one-domain end-to-end loop)
Track 1 (robust connections + sync) + Track 2 (canvas) + Track 3 (Cowork) converging so that **Liam
edits the 2D canvas and Cowork edits the same graph, live, across the connection fabric** — one
domain working end-to-end. THEN features (serialization variety, diagram/image rendering, linear
view, multi-user CRDT, the no-fundamental-primitives generalization) layer on, each **only if it
works across the connections**.

## Shared laws (every track)
Functionality is DATA (arrangements over primitives), never new code; renderers/transports are dumb
delegates; append-only; **nothing wired without Liam's approval** (propose-then-commit); **NO
Anthropic API keys** (Claude connects via MCP/connectors on Liam's subscription);
**source/renderer-independent** (UI/area state stays OUT of the arrangement); keep the GDScript and
Python protocol ports in **parity** (`headless_*_test.gd` ↔ `bridge/test_graph_logic.py`); website
code lives in **Resonance-Website**, the engine repo is engine-only.
