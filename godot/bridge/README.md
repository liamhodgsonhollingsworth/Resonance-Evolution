# godot/bridge — Claude ⇄ graph transports (no API keys)

Thin relays over the canonical `live/arrangement.json` (the file the running game hotloads), so
the engine + every renderer stay dumb delegates and Claude coworks over plain DATA.

- **`scene_bridge.py`** — the original live *scene* relay (`/api/scene/load|get|screenshot|status`).
- **`graph_mcp.py`** — the **MCP server** that lets Claude cowork inside the conversation/idea
  graph. Authorized by your Claude session/subscription — **no Anthropic API key, ever**. (An
  MCP server's auth axis is orthogonal to the model-API key.)

## Tools (namespace `graph_*`)
- **Read** (side-effect-free): `graph_read`, `graph_get_subgraph`, `graph_assemble_context`
  (`fmt=messages|xml`), `graph_find`, `graph_validate`.
- **Write** (APPROVAL-GATED, propose-then-commit): `graph_propose` (typed actions),
  `graph_propose_abstract` (fold nodes into a Chip), `graph_propose_decompose` (open a Chip) →
  each STAGES a proposal with a preview; `graph_commit` / `graph_discard` / `graph_list_proposals`.
  Nothing mutates `arrangement.json` until `graph_commit` — the running game then hotloads it.

The action vocabulary (`add_node` / `wire` / `set_active_tip`) and the assemble/interpret logic
are the same ones the **copy-paste bridge** uses (`convo_protocol.to_prompt` /
`interpret_reply`), so claude.ai (no connector) and the MCP server share one protocol.

## Diagrams, images & building structure (one DSL, no key)
`graph_propose` is the single build tool — messages, ideas, diagrams, images and whole
structures all flow through it as `add_node`/`wire` actions (deliberately NOT a sprawl of
bespoke `add_*` tools). Node roles:
- `user`/`assistant`/`system` — chat turns; `idea`/`note` — your own structure.
- `diagram` — Claude authors the diagram **as text** (`params.diagram_kind` =
  `svg`|`mermaid`|`dot`|`plantuml`|`d2`|`excalidraw`|`tldraw`, `content` = the source). **No
  image API/key** is needed; a renderer rasterizes it later (SVG imports natively in Godot;
  source→SVG via bundled `mermaid-cli`/`dot`).
- `image` — `params.image_kind` = `svg`|`url`|`ref`, `content` = the SVG/url/ref. Raster
  generation, if ever wanted, uses the USER's own (non-Anthropic) generator — the graph still
  stores only the SVG/source/ref, so it stays portable.

`created_at` is stamped server-side when omitted, so the linear projection stays ordered.
(Rendering a diagram/image needs a conversation VIEW; that arrives with the Godot/web view —
the data-level support is here now.)

## Register in Claude Code (no key)
A project `.mcp.json` (server `resonance-graph`, stdio) is included at the repo root — Claude
Code will offer to enable it; approve it. Equivalent CLI:

    claude mcp add --transport stdio resonance-graph -- python <abs path>/godot/bridge/graph_mcp.py

If the server doesn't appear, use the absolute path to `graph_mcp.py` in `.mcp.json`/the command
(the relative path assumes Claude Code launches it from the project root). Verify with `/mcp`
(server connected) and `/status` (subscription auth, NOT an API key).

> **No-key gotcha:** a stray `ANTHROPIC_API_KEY` / `ANTHROPIC_AUTH_TOKEN` / `apiKeyHelper` /
> Bedrock / Vertex env var silently disables Claude Code's no-key subscription connector path.

## Later (Phase F — in Resonance-Website / resonancewavefront.org)
The SAME core runs over the network for regular Claude (web) + Cowork:
`python godot/bridge/graph_mcp.py --transport streamable-http`, behind public HTTPS + OAuth
2.1/PKCE/DCR, added as a custom connector. Plus paste-the-link and a hosted copy-paste bridge.
**localhost is invisible to web/Cowork** (their connectors run from Anthropic's cloud) — they
need a public URL or a named tunnel.

## Logic + cross-substrate parity
`convo_protocol.py` (+ `chip_ops.py`) are parity ports of `godot/runtime/convo_protocol.gd`
(+ `godot/editor/chip_ops.gd`). Both read the same arrangement format, so the engine and the
Claude-facing transports agree. Keep them in sync:

    python godot/bridge/test_graph_logic.py          # Python side
    godot --headless --path godot -s res://headless_convo_test.gd   # GDScript side
    godot --headless --path godot -s res://headless_chip_test.gd
