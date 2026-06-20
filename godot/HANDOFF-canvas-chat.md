# Handoff — canvas chat (nonlinear conversation/idea graph) + no-key MCP

Status 2026-06-20 (worktree `clever-hellman-e85337`). A thread distinct from the evolver/painterly
roadmap in `PROGRESS.md`. Plan: `~/.claude/plans/in-parallel-with-work-quiet-moth.md`.

## What this is
Move Liam's Claude chats into the engine as a **nonlinear conversation/idea GRAPH** that Claude
(regular, Claude Code, Cowork) coworks inside — **NO API keys**, many parallel transports,
renderer-independent. ONE canonical *arrangement* + a **graph↔text protocol** + a **typed
graph-action vocabulary**; every renderer/transport is a dumb delegate over that core.

## Done + verified (Phases A–E core)
- **A — fractal substrate, carried on from `vibrant-elion-937d68` (fast-forward merge to `4b89a98`)
  + completed.** Added a recursion **DEPTH GUARD** (`PrimChip.MAX_DEPTH` + `GraphRuntime.depth`) so
  deep / (future) self-referencing nesting halts gracefully. New tests: same-instance
  hotload-into-changed-child, kept-not-rebuilt chip instance, **lossless full-output round-trip**,
  deep-nest halt. `headless_chip_test.gd` 14/14.
- **B — conversation/idea taxonomy as DATA.** `primitives/prim_message.gd` (**Message**:
  role/content/author/created_at; `parent`-in / `reply`-out ports; a multi-parent node is a MERGE).
  New `message` port type; registered in `graph_runtime.gd`. Edge intent lives on ports/params
  (wires are schema-strict). Top-level `current_node` = active tip.
- **C — graph↔text protocol (the substrate-independent core).** `runtime/convo_protocol.gd`:
  `ancestors`/`context_nodes`/`to_messages`/`to_xml`/`to_prompt` (FORWARD) +
  `interpret_reply`/`apply` (BACKWARD, append-only, approval-gated). Powers linear↔graph duality AND
  the **copy-paste bridge** (zero infra: paste `to_prompt` into claude.ai, `interpret_reply` the
  reply). `headless_convo_test.gd` 12/12.
- **D — local stdio MCP server (Claude Code, no key).** `bridge/graph_mcp.py` (FastMCP, successor to
  `scene_bridge.py`, operates on `live/arrangement.json`). Read tools
  (`graph_read`/`get_subgraph`/`assemble_context`/`find`/`validate`); approval-gated writes via
  **propose-then-commit** (`graph_propose` / `graph_propose_abstract` / `graph_propose_decompose` →
  `graph_commit` / `graph_discard` / `graph_list_proposals`). `bridge/convo_protocol.py` +
  `bridge/chip_ops.py` = Python **parity ports**; `bridge/test_graph_logic.py` 14/14 (engine ↔
  transport agree over the same data). Project `.mcp.json` registers it.
- **E (data level) — diagrams / images / build-structure via ONE DSL.** `graph_propose` handles
  `add_node` roles `diagram` (svg/mermaid/dot/plantuml/d2/excalidraw/tldraw) + `image`
  (svg/url/ref); `created_at` stamped server-side. No bespoke `add_*` sprawl. **RENDERING
  (svg→texture) DEFERRED** to when a conversation VIEW exists.

## Verify
- GDScript: `godot --headless --path godot -s res://headless_chip_test.gd` (and `headless_convo_test.gd`,
  plus demo/primitive/compose/transform/editor). Rebuild the class cache first if class scripts changed:
  `godot --headless --path godot --editor --quit-after 60`.
- Python: `python godot/bridge/test_graph_logic.py`.
- MCP: approve the project `.mcp.json` in Claude Code (or
  `claude mcp add --transport stdio resonance-graph -- python <abs>/godot/bridge/graph_mcp.py`);
  verify `/mcp` (connected) + `/status` (subscription auth, NOT an API key). No stray
  `ANTHROPIC_API_KEY`/`apiKeyHelper`/Bedrock/Vertex env var (silently disables the no-key path).

## ⚠️ Coordination — the "no fundamental primitives" pivot
The fractal-primitive law Liam asked about IS the tracked **[[no-fundamental-primitives]]** core law
(see `godot/HANDOFF-no-fundamental-primitives.md` in `vibrant-elion-937d68`). I **carried on** the
Chip substrate (compatible — that handoff says shipped Chip work "gains generalization, no rework")
and made a **MINIMAL core edit** (the depth guard on `graph_runtime.gd` + `prim_chip.gd`) — flagged
here because the handoff marks those files as the in-flight session's territory. I did **NOT**
implement the full generalization (`type → definition` resolver, frame-relative evaluation,
retroactive decomposition) — it has **6 open questions for Liam** in that handoff. Coordinate before
that deeper core change so the canvas-chat substrate and the generalization converge.

## Next (not built)
- **Phase F — Resonance-Website / resonancewavefront.org (other repo):** the SAME `graph_mcp.py`
  core over `--transport streamable-http`, public HTTPS + OAuth 2.1/PKCE/DCR, added as a custom
  connector for regular Claude (web) + Cowork; plus paste-the-link and a hosted copy-paste bridge.
  Build via the Claude-Code connection. (localhost is invisible to web/Cowork — needs a public
  URL/tunnel.)
- **Conversation VIEWS** (Godot GraphEdit panel + linear transcript; later web) — also unlocks
  diagram/image rendering.
- **Phase G (optional):** typed-hole node; a cross-substrate parity test for the protocol.
- **Multi-user CRDT** (Yjs/Loro; Claude as a peer author) — deferred subsystem; `{id,parent,author,
  created_at}` schema is unchanged, so it adds later with no migration.

## Repo state
Working tree (uncommitted): the canvas-chat files above + this doc + project `.mcp.json`. Branch was
fast-forwarded `0b48e10 → 4b89a98` to carry on `vibrant-elion`'s substrate. Nothing committed by this
thread yet (commit on Liam's say-so).
