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
  unknown id; a `set_active_tip` to an unknown node; **a batch that would close a cycle** in the
  parent graph (a conversation/idea graph is a DAG). Unknown *kinds* are **allowed** (engine-neutral,
  forward-compatible; new TYPES register in `GraphRuntime`). A failed action does not enter the
  id-set, so dependents are flagged too.
- **`validate_arrangement(arr) → {ok, counts, dangling_wires, active_tip_exists, acyclic}`** —
  whole-graph **soundness**: every wire endpoint exists; `current_node` (if set) exists; the parent
  graph is acyclic. (`graph_validate` delegates here.)

Both are GD↔Py parity functions in `convo_protocol`. **Do not re-implement validation in a transport
— import these.**
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

**The conflict-safe write is importable** — `bridge/graph_store.py` (stdlib, no `mcp` dependency) is
the contract as code. Any transport lands agent/Claude contributions with one call:
```python
import graph_store as gs
res = gs.commit_actions(live_dir, actions)   # reload current → validate → append-only apply → soundness → atomic write
# res = {"ok": True, "result", "counts"}  |  {"ok": False, "error", "errors"|"sound"}
```
**Any writer (engine canvas, MCP, the 2D-canvas bridge, the remote connector) MUST land
agent/append-only edits through `graph_store.commit_actions` (the MCP server already does).** An
in-process lock guards one server's threads, not two processes editing the same file — blindly
writing the whole arrangement is a cross-process clobber bug.
> ⚠️ Known adoption gaps (each track routes its writes through the seam):
> - `bridge/canvas_bridge.py` (Track 2) writes via its own `_load`/`_save` under a thread lock — its
>   `/api/reply` (Claude's contribution) should call `graph_store.commit_actions`; Liam's own direct
>   authoring (create/move/edit) is self-approved but should still validate against the shared gate.
> - `editor/graph_panel.gd::_commit()` (Godot editor) still whole-file-overwrites — route through the
>   contract too (a thin GD `graph_store` equivalent, or commit deltas).

## 5. Change observation + the remote plug-point (how systems see + join each other's edits)
Two top-level fields, **stamped by `graph_store.save` on every write** (so every writer through the
seam advances ONE shared counter), let any observer order changes and detect it is behind:
- **`rev`** — a monotonic integer; `rev = max(on-disk rev, incoming rev) + 1`, so it never goes
  backwards even across concurrent writers. The authority for ordering.
- **`updated_at`** — ms wall-clock of the write (display / coarse recency only).

The change *signal* is the **content hash** of the raw bytes (`graph_store.live_hash()` ↔
`runtime/live_host.gd`'s `sha256_text` poll — hash, not mtime, so sub-second edits and idempotent
re-saves are correct). On change a reader reloads, re-evaluates/re-renders, and reads the new `rev`
(the engine exposes it as `LiveHost.rev`; `commit_actions` and `graph_commit` return it).

**Remote plug-point (Track 3 — no engine/Track-1 changes needed):** a remote/Cowork transport joins
the SAME fabric by (a) **writing** through `graph_store.commit_actions` (conflict-safe, append-only)
and (b) **observing** the `rev`/hash of `arrangement.json` — exactly what the local transports do.
Track 3 only adds the network skin (Streamable-HTTP + OAuth) over those two operations.

**Deferred:** an optional base-`rev` optimistic-concurrency token in the propose/commit API (a client
sends the rev it based on) for stricter staleness detection; and **CRDT** true multi-writer — the
`{id, parent, author, created_at}` + `rev` schema needs no migration to add either later.

## 6. The laws every connecting track holds
Functionality is DATA (arrangements over primitives), never new code · renderers/transports are dumb
delegates · append-only · **nothing lands without approval** (propose-then-commit) · **no Anthropic
API keys** · source/renderer-independent (no UI/view state in the arrangement) · GDScript ↔ Python
ports stay in parity.
