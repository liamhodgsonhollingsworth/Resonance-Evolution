# The Connection Contract (Track 1 — Connection Fabric)

Status 2026-06-20. **Every track that connects to the shared graph imports this.** It is the
single agreement that lets the engine, the in-game canvas (Track 2), the local MCP server, and the
remote/Cowork connector (Track 3) all edit *one* graph, concurrently, without corrupting or
clobbering each other. Connections first: this contract is robust **before** any feature is built on
it; a feature only ships if it works *across* this contract.

The contract is **DATA + a handful of pure functions** — no engine, UI, or network types. The
GDScript port (`runtime/convo_protocol.gd`) and the Python port (`bridge/convo_protocol.py`) are kept
in **parity** (`headless_convo_test.gd` ↔ `bridge/test_graph_logic.py`); `bridge/test_sync_logic.py`
proves the conflict-safe write path. No Anthropic API keys anywhere.

## 1. The canonical artifact — `live/arrangement.json`
One file is the shared truth. Every system reads and writes *this*; every renderer is a dumb
delegate over it.

```jsonc
{
  "format": "resonance.arrangement/v1",
  "nodes": [ { "id": "n1", "type": "Message", "params": { "role": "user", "content": "…",
                                                          "author": "", "created_at": 1700000000000 } } ],
  "wires": [ { "from": "n1", "out": "reply", "to": "n2", "in": "parent" } ],
  "current_node": "n2"            // optional: the active tip
}
```
- A conversation/idea **edge** is a wire `A.reply → B.parent`. A node with several incoming `parent`
  wires is a **MERGE**. Edge *intent* lives on ports/params, never on the wire shape (wires are
  schema-strict: `{from, out, to, in}`).
- **No renderer/UI/view state in here** (no camera, zoom, area, selection). Layout hints like a
  node's `pos` are tolerated but never required for correctness — source/renderer independence.
- **Append-only.** Edits add nodes/wires/versions; they do not rewrite history.

## 2. The action vocabulary (how every system proposes an edit)
Exactly three ops — one DSL, no bespoke `add_*` sprawl:
- `add_node {kind, params, parent?, id?}` — a new node; if `parent` is given, also a `reply→parent`
  wire from it. `kind` defaults to `Message`. Message roles include `user`/`assistant`/`system`,
  `idea`/`note`, `diagram` (+`diagram_kind`), `image` (+`image_kind`). `created_at` is stamped
  server-side if omitted.
- `wire {from, to, out?, in?}` — defaults `out:"reply"`, `in:"parent"`.
- `set_active_tip {node}` — moves the `current_node` pointer.

## 3. Validation — the gatekeeper (one definition, every transport)
`convo_protocol`:
- **`validate_actions(arr, actions) → {actions, errors}`** — the **structural gate**. Simulates the
  batch against `arr` with a running id-set (existing ids ∪ ids added earlier in the *same* batch)
  and rejects, with a clear message: an `add_node` with empty `kind`, non-object `params`, a Message
  with no `role`, or an unknown `parent`; a `wire` missing an endpoint, self-wired, or referencing an
  unknown id; a `set_active_tip` to an unknown node. Unknown *kinds* are **allowed** (engine-neutral,
  forward-compatible; new TYPES register in `GraphRuntime`). A failed action does not enter the
  id-set, so dependents are flagged too.
- **`validate_arrangement(arr) → {ok, counts, dangling_wires, active_tip_exists}`** — whole-graph
  **soundness**: every wire endpoint exists; `current_node` (if set) exists. (`graph_validate`
  delegates here.)
- `interpret_reply(text) → {actions, errors}` — extracts candidate actions from a fenced
  ```` ```resonance-actions ```` block (parse + op-allowlist only); the structural gate above is
  applied at propose/commit, so every entry path validates identically.

## 4. The approval gate + conflict-safe writes (how an edit lands)
**Propose-then-commit; nothing auto-applies.** A write tool *stages* a proposal; a separate commit
applies it. The MCP server (`bridge/graph_mcp.py`) is the reference implementation:

1. **Propose** validates eagerly (`validate_actions`), then stages the proposal as the **delta +
   base** — `{kind, base_hash, actions | args, result(preview)}` — where `base_hash` is the content
   hash of `arrangement.json` at propose time. The stored `result` is preview-only.
2. **Commit is conflict-safe — it re-derives against the CURRENT file, never blindly overwrites:**
   - *action batches* — reload current, **re-validate + re-apply (append-only) onto current**, then
     `validate_arrangement` the result. Concurrent adds **rebase** cleanly; the only true conflict
     (`set_active_tip` vs `set_active_tip`) is last-writer-wins. If a referenced node was concurrently
     removed, the commit is **rejected** (the proposal stays staged) rather than corrupting the graph.
   - *structural ops* (`abstract`/`decompose`, i.e. Chip fold/unfold) — require an **unchanged base**:
     if the file moved since the proposal, the commit is **rejected** with a re-propose hint.
   - The result is written **atomically** (`tmp`+`os.replace`). Commit returns `{rebased}` so a caller
     can tell whether it rebased over a concurrent edit.

**Any writer (engine canvas, MCP, remote) MUST go through this same propose→validate→conflict-safe-
apply→atomic-write path.** Blindly writing the whole file is a clobber bug.
> ⚠️ Known gap: `editor/graph_panel.gd::_commit()` still does a whole-file overwrite. Track 2 must
> route the in-game canvas's writes through this contract (the seam this doc defines).

## 5. Change observation (how a system sees others' edits)
The signal is the **content hash** of `arrangement.json`'s raw bytes (`graph_mcp._live_hash()` ↔
`runtime/live_host.gd`'s `sha256_text` poll). On change, a reader reloads and re-evaluates/re-renders.
Hash-based (not mtime) → sub-second edits and idempotent re-saves are handled correctly. A monotonic
`rev` field is reserved for ordering once a remote multi-writer (Track 3) lands; **CRDT** true
multi-writer is deferred (the `{id, parent, author, created_at}` schema needs no migration to add it).

## 6. The laws every connecting track holds
Functionality is DATA (arrangements over primitives), never new code · renderers/transports are dumb
delegates · append-only · **nothing lands without approval** (propose-then-commit) · **no Anthropic
API keys** · source/renderer-independent (no UI/view state in the arrangement) · GDScript ↔ Python
ports stay in parity.
