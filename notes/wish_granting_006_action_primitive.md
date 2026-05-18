# Wish-granting session — #006 click-to-expand → action primitive

Session's primary document. Working branch: `claude/wish-006-action-primitive`. Started 2026-05-18 from the affectionate-leakey-d4c0b1 Alethea worktree, following the planning-parallel-arc handoff which suggested Tier B as the next implementation target.

## The wish (verbatim from wishlist.md)

> **#006** [pending] — **Click-to-expand for panel items.** Generic expand action that takes any panel item and shows its full content plus connections in a sub-renderer overlay. Escape collapses back. (Items already carry stable IDs and a `body` field — the click-handler infrastructure is the remaining work.)

## Phase 1 — Frame and broaden

### What the wish literally asks for

A way to click on a panel item (TaskItem, IdeaItem, WishItem) and see its full `body` content plus connections in an overlay. Escape returns to the list view. Items already carry `id` + `title` + `body` + `status` + `meta` per the parser convention; what's missing is:

1. The interaction infrastructure — text-API command, eventually visual click handler.
2. The view-state that knows "panel X has item Y expanded right now."
3. The renderer support that shows the expanded view when state says so.

### What the maintainer NEEDS that the wish does not say

Click-to-expand is one specific instance of "an action on a panel item." Other already-named per-item actions are coming:

- **#015 add_button** — generic action-button-on-panel-item.
- **#013 make_queue skill** — implies actions on queue items (mark-done, delete, edit).
- **Future Tier C panels** — Email (read/reply/archive), Calendar (RSVP, reschedule), Reading-list (mark-read, annotate).

If #006 ships as a special-cased "expand" verb wired only into `ListRenderer`, the next wish has to repeat the wiring work. The accumulator-pattern principle says: produce the primitive that absorbs the next wish too.

### The generalization being explored

**Items expose available actions; renderers maintain per-item view-state; actions are invokable through text-API and (future) visual-API by a single dispatch path.**

What this absorbs:
- #006 click-to-expand (the `expand` action on a list item).
- #015 add_button (any custom action becomes a per-item button automatically).
- Future per-item interactions across all panel types.
- The expand action specifically is the FIRST instance — the next one (e.g. mark-done) becomes a one-action-definition addition.

What this composes with (further out):
- #041 input-as-channel — actions ride on the same channel as mouse/keyboard/voice.
- #042 mutation-with-inverse — actions become mutations with inverters for undo.
- #007 SessionRoster + ChatPanel — chat-send becomes one of the actions a ChatItem exposes.

### Exit condition for Phase 1

Met when the four subagents are dispatched with the framing above and a clear statement of what gets built lands in this document.

## Phase 2 — Dispatch + integrate

Dispatch shape: four subagents in parallel (single Agent-tool message). Each receives the wish, the framing, the relevant files, and an output-shape specification.

### Pre-named candidates for stress-test

The wish-granting type's standard dispatch has the dispatching session pre-name two strong candidates for the stress-test subagent. The two I'll name:

**A. Engine-cache view-state.** A reserved cache key like `engine.cache["__view_state__"][renderer_node_id]` holds per-renderer state dicts (e.g. `{"expanded_item": "tasks-0", "selected_item": null}`). The text-API gains commands like `expand <renderer_id> <item_id>` / `collapse <renderer_id>` that mutate the cache. ListRenderer.emit reads its own entry from engine.cache and renders the expanded view when an item is named. Simple, requires no node-type changes beyond ListRenderer.

**B. Per-item action specs + generic dispatch.** Parsers add an `actions` field to each item (default `["expand"]` for everything; per-parser overrides for custom actions). The engine grows a `dispatch_action(renderer_id, item_id, action_name, payload=None)` method. Renderers expose an optional `handle_action(state, action_name, payload, engine, node) -> state_update` hook. The text-API exposes a generic `invoke <renderer> <item> <action>` command. ListRenderer's handle_action populates the per-renderer view-state for expand/collapse; future renderers register their own actions. Generalizes farther (absorbs #015 cleanly); slightly more infrastructure now.

The subagents will tell me which one to build, or surface a third option I haven't seen.

## Phase 2 — Integrated plan (post-subagent)

Four subagents returned. The four reports converge on **Candidate B with three stress-test-driven refinements**.

### Convergence

- **Enumeration** (6 candidates) recommended A as floor, B as target; flagged C (ViewState-as-graph-node) as a fine future refactor from B.
- **Stress-test** (top-3 per candidate) named B more resilient under stress; both share the stale-item-id failure mode at score 25 (a parser problem, not a primitive problem); B has score-20 "where does view-state live" question that must be answered explicitly.
- **Generalization** named a more ambitious primitive — selection-channel + OverlayHost — and recommended a middle-ground form. The middle-ground absorbs more wishes (#019 corpus-browser full, #053 depth indicators partial) but at ~550 LOC vs B's ~350. The session takes a measured step: build B now in a way that composes cleanly toward OverlayHost later.
- **Backend-feasibility** quoted B at ~350 LOC (150 code + 200 tests). B's incremental cost over A if A ships first is ~200 LOC — so building B from scratch saves ~20% over A-then-B. The wishlist depth (#015, #013, Tier C actions) repays B's premium within 2-3 future wishes. No in-flight file conflicts.

### Chosen design

**The action primitive.** Items carry an `actions: list[str]` field declaring what actions they support. Renderers expose an optional `handle_action(state, action_name, payload, engine, node) -> dict` hook that returns a view-state delta. A free function `dispatch_action(engine, renderer_id, item_id, action_name, payload=None)` looks up the renderer, validates the action against the item's declared actions, calls the renderer's `handle_action`, merges the returned delta into the per-renderer view-state. Text-API gains generic `invoke` plus sugar `expand` / `collapse`.

### Stress-test mitigations baked in

1. **View-state storage is explicit.** `engine.cache["__view_state__"][renderer_node_id]: dict` — uses the existing reserved-namespace cache convention (`__lights__`, `__gravity_fields__`). Survives `precompute()` re-runs (precompute only writes to `cache[node_id]`). Survives `reload_type` (cache untouched). Does NOT live on `node.state` (which is the build-time output and not normally mutated).

2. **`dispatch_action` lives in `engine/actions.py` as a free function.** Not a method on `Engine` (avoids the "Engine becomes a state-mutator outside emit()" architectural conflict). Not in `tools/text_test.py` (so it's callable from the future mouse-click handler and MCP server without depending on the text-test module). Mirrors the `engine/inverse.py` location but without an `Engine.invert_edit`-style wrapper method — caller passes the engine instance explicitly.

3. **Defensive emit handles stale ids.** ListRenderer.emit checks that `view_state["expanded_item"]` exists in the current items list before rendering the expanded view. Stale ids (from a source-file edit shifting line numbers) silently fall back to the list view instead of expanding the wrong item. Parser-level content-hash ids are filed as a future wish, not included in this session.

### Item-shape extension

`parsers/__init__.py` exports an `attach_default_actions(items)` helper that adds `actions: ["expand"]` to any item that doesn't already have one. Each of the three parsers (tasks, ideas, wishes) calls this helper as the last step before returning. New parsers either call the helper or set actions explicitly.

### text-API verbs

- `invoke <renderer_id> <item_id> <action_name> [key=value ...]` — the generic verb. Routes through `dispatch_action`.
- `expand <renderer_id> <item_id>` — sugar: equivalent to `invoke <renderer_id> <item_id> expand`.
- `collapse <renderer_id>` — clears the renderer's `expanded_item`. Equivalent to `invoke <renderer_id> "" collapse` but accepted without a placeholder item-id.

The TextRenderer's `command_grammar()` lists all three.

### ListRenderer.handle_action

Two action handlers in v1:

- `expand`: payload includes the item-id (from dispatch_action's resolution). Returns `{"expanded_item": item_id}`.
- `collapse`: returns `{"expanded_item": None}`.

ListRenderer.emit reads `engine.cache.get("__view_state__", {}).get(node_id, {})` for its current expansion state. When `expanded_item` is set AND found in items, renders the expanded view in the screen-rectangle. Otherwise renders the list as today.

### Expanded view rendering

For v1, the expanded view replaces the panel contents (same screen-rectangle, same width/height) with:
- Title (using the larger title font).
- Status glyph + status word.
- Full body, word-wrapped.
- Meta dict as `key: value` lines at the bottom, if non-empty.
- A "press collapse to return" hint at the bottom.

Connections rendering is deferred — items don't carry connection info yet, and that's a separate wish-shape.

### Accumulator-tool

A new skill in Alethea's `skills/` catalog: **`add-panel-action.md`**. Codifies the procedure for adding a new action to any panel: (1) declare the action in the parser's output (or override `actions` per item), (2) add a handler clause to the renderer's `handle_action`, (3) optionally add a sugar verb to the text-API. Each new action becomes a one-skill-invocation away — exactly the procedural-tools accumulator the wish-granting type names.

Plus a short addition to Apeiron's `architecture.md` naming the actions channel as a named architectural surface, so a fresh reader can find it.

### What this absorbs (BETTER-than-wish test)

1. **Other pending wishes absorbed.** #015 (add_button) becomes "declare a new action in the parser plus a handler clause in the renderer" — no new infrastructure. Tier C panels (#016-#022) get expand for free and gain their domain-specific actions (email-reply, calendar-RSVP, mark-read) as parser+handler additions.

2. **Future-primitive composition.** The `dispatch_action` path is the natural integration point for #041 (input-as-channel — mouse-clicks call dispatch_action with the same args) and #042 (mutation-with-inverse — handle_action can return both forward and inverse deltas in a future revision).

3. **Fresh-reader test.** A reader of `list_renderer.py` sees `handle_action` defined alongside `emit`/`describe`; the architecture.md addendum names the actions channel. The primitive is observable from a single node-type file plus a one-paragraph architecture entry.

All three BETTER-than-wish tests pass.

### Build sequence (PR-shaped)

1. **Parsers emit `actions` field** + helper. Updates: `parsers/__init__.py` + `tasks.py` + `ideas.py` + `wishes.py` + per-parser tests. Gate: existing tests green, new `test_<parser>_emits_actions`.
2. **`engine/actions.py::dispatch_action`** + reserved-key view-state convention + module isolation + tests. Gate: 4-5 dispatch tests (routes / unknown-renderer / unknown-action / item-not-in-actions / broken-handler-isolated).
3. **ListRenderer.handle_action + defensive emit + expanded render path.** Updates: `list_renderer.py` + tests. Gate: handler tests + defensive-emit test + existing 21 tests green.
4. **Text-API verbs.** `invoke` / `expand` / `collapse` handlers + grammar update. Gate: text-API verb tests + grammar surfaces all three.
5. **End-to-end scene test.** Loads `workflow_view.json`, invokes expand via `invoke` and via `expand` sugar, asserts the expanded view renders, calls collapse, asserts the list view returns.
6. **Accumulator tool.** `skills/add-panel-action.md` in the Alethea repo + architecture.md addendum in Apeiron.
7. **Wishlist update + close.**

## Phase 3-5 — pending

Implementation proceeds per the build sequence above. Verification per Phase 4 of the wish-granting session-type doc. Close per Phase 5.

## Notes log

- 2026-05-18, session start, branch created, primary doc written.
- 2026-05-18, four planning subagents dispatched in parallel and returned.
- 2026-05-18, integrated plan written into this doc, chosen design = B+ with stress-test mitigations.
