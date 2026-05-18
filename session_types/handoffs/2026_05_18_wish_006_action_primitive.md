# 2026-05-18 — Wish #006 granted: click-to-expand via per-item action primitive

Wish-granting session continued from the affectionate-leakey-d4c0b1 Alethea worktree following the [planning-parallel arc handoff](2026_05_16_planning_parallel_arc.md) and the [Tier A first-renderer-view handoff](2026_05_16_first_renderer_view_tier_a.md). The maintainer asked the session to "continue Apeiron development"; following the priority order in the prior handoff ("Continue wish-granting on Tier B"), the session selected wish #006 — the Tier B click-to-expand wish that the maintainer's `tasks.md` also flagged as a planning candidate ("Plan the wish #006 click-to-expand interaction shape").

## The wish

> **#006** [granted] — **Click-to-expand for panel items.** Generic expand action that takes any panel item and shows its full content plus connections in a sub-renderer overlay. Escape collapses back. (Items already carry stable IDs and a `body` field — the click-handler infrastructure is the remaining work.)

## What got built

The session shipped the **per-item action primitive** — a generalizable dispatch path that grants #006 directly and absorbs the surrounding cluster (#015 add_button, the seven Tier C panel-action wishes, and the future per-item action verbs).

Items declare an `actions: list[str]` field at parser-output time, defaulting to `["expand"]` via a new `attach_default_actions` helper in `node_types/parsers/__init__.py`. Each of the three existing parsers (tasks, ideas, wishes) now calls the helper as its last step. A renderer that wants to react to actions exposes `handle_action(state, action_name, payload, engine, node) -> state_delta`; the free function `engine.actions.dispatch_action(engine, renderer_id, action_name, item_id=None, payload=None)` validates the action against the item's declared list when item-scoped, calls `handle_action` under module isolation, and merges the returned delta into the per-renderer view-state at `engine.cache["__view_state__"][renderer_id]` — a reserved-namespace cache key matching the existing `__lights__` / `__gravity_fields__` pattern.

`ListRenderer.handle_action` implements two actions in v1: `expand` (item-scoped, sets `expanded_item`) and `collapse` (renderer-scoped, clears it). `ListRenderer.emit` reads the per-renderer view-state and renders a single-item detail view (title at the larger font, status glyph, full body word-wrapped, meta dict as key:value lines, "press collapse to return" hint) in the same screen-rectangle when `expanded_item` is set AND found in the current items. Defensive emit silently falls through to the list view when the id is stale (a source-file edit that shifts line numbers no longer expands the wrong item).

The text-API gains three verbs: `invoke <renderer> <item> <action> [k=v ...]` (the generic dispatcher), plus the sugar verbs `expand <renderer> <item>` and `collapse <renderer>`. All three appear in `TextRenderer.command_grammar()`. The `tools/text_test.py` CLI also gained an automatic `engine.precompute()` call after `load_scene` so source-cache entries are populated before any subcommand runs (a latent bug surfaced while exercising the new verbs end-to-end).

A new architecture.md section names actions as a load-bearing dispatch surface alongside the existing channels, isolation, and renderer-as-node commitments.

## BETTER-than-wish notes

All three named tests pass.

- **Other pending wishes absorbed.** #015 (add_button) inherits the primitive directly — adding a button is now a parser declaration + a renderer handler clause + an optional text-API sugar verb (the [add-panel-action skill](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/skills/add-panel-action.md) codifies the procedure). The Tier C panel-action wishes (#016 email-reply, #017 calendar-RSVP, #018 journal-compose, #019 corpus-search, etc.) plug into the same dispatch path.
- **A primitive future wishes compose against.** The action layer is forward-compatible with #041 (input-as-channel — mouse-clicks will call dispatch_action with the same args) and #042 (mutation-with-inverse — handle_action can return both forward and inverse deltas in a future revision).
- **Fresh-reader test passes.** A reader of `list_renderer.py` sees `handle_action` defined alongside `emit`/`describe`; the architecture.md addendum names the actions channel; a single dispatched fresh subagent successfully drove the feature end-to-end through the text-API alone without reading source code.

## Accumulator-tool produced

[add-panel-action skill](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/skills/add-panel-action.md) in Alethea's `skills/` catalog. Codifies the procedure for adding a new per-item or renderer-scoped action: (1) decide item-scoped vs renderer-scoped, (2) declare the verb in the parser (or per-item override), (3) add a clause to the renderer's `handle_action`, (4) optionally add a sugar verb to `tools/text_test.py` and a line to `command_grammar()`, (5) extend the renderer's emit if the action changes visuals, (6) test, (7) update wishlist. The skill's first-revision cost target is "new action lands in 30-60 LOC" — if a follow-on action takes more, the primitive needs an evolution before more actions land.

Pairs with the existing [mount-panel skill](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/skills/mount-panel.md). Together they form the panel-mounting + panel-action-adding accumulator pair: any new domain panel becomes one mount-panel invocation plus zero or more add-panel-action invocations.

## Wishlist updates

- **#006** moved to `[granted]` with a note on what the implementation absorbed plus a summary entry in the `Granted` section linking to the merged PR.
- **#015** stays `[pending]` but its body now notes that the underlying dispatch already exists; only the visual layer remains.
- Three new wishes filed under Tier R (refactor/engine polish):
  - **#059** — Content-hash item ids in tasks and ideas parsers (mitigates the score-25 stale-id stress-test vulnerability).
  - **#060** — text_test CLI multi-command / scripting mode (gap surfaced by fresh-subagent verification — state-mutating verbs can't be observed via a follow-up render in the same process today).
  - **#061** — `list-commands` text-API verb (gap surfaced by fresh-subagent verification — verbs are discoverable today only via error messages or by rendering a TextRenderer-wrapped scene; a direct CLI verb would close it).

## Next-session candidates

Wishes whose implementation context is now freshest because of what just landed:

1. **#015 add_button (visual layer only)** — the dispatch path is built; the remaining work is the per-item button glyph and an eventual click-binding when the realtime renderer (#023) lands. Could be small enough to ship alongside the realtime renderer wish.
2. **A Tier C domain panel + a domain-specific action** — picking a panel (Email #016, Calendar #017, Reading-list #022, etc.) and demonstrating the mount-panel + add-panel-action pair in sequence proves both accumulator skills compose. The strongest Tier C candidate for next is probably Reading-list (#022) — it has the simplest item shape (title + status), the cleanest action set (mark-read, archive, annotate), and exercises both skills in one session.
3. **#059 content-hash item ids** — bounded refactor that improves the resilience of any per-item state (including the action primitive's view-state). Estimated 30-50 LOC.
4. **#061 `list-commands` verb** — 5-line fix; closes a real CLI discoverability gap; should probably ship as a tiny refactor commit even outside a wish-granting session.

## Open architectural questions

- **Per-renderer view-state durability across `engine.reload_type`.** The cache survives hot-reload by design (only sys.modules is touched), but if a future renderer revision changes the state-key vocabulary (renames `expanded_item` to `selected_item`, say), the new module reads against the old keys and silently does nothing. A schema-versioning convention for view-state keys may be worth designing before more renderers grow handler tables.
- **Cross-renderer mutations.** The current primitive scopes view-state per renderer. The add-panel-action skill notes that cross-renderer chains stay short, with 3+ hops implying a router-node belongs in between. The Router node-type (wish #012) is the natural primitive that absorbs this when it lands.
- **Selection-as-channel framing (from generalization subagent).** The session deliberately chose a per-renderer view-state model over the more ambitious "selection-channel + OverlayHost" framing that the generalization subagent recommended. The current model composes upward to selection-as-channel cleanly (the cache key becomes viewer-keyed when #033 co-presence lands), but the framing decision is worth re-visiting if a wish surfaces that the OverlayHost shape would grant more easily than the current handler-per-renderer shape.

## Stress-test vulnerabilities — status

The Phase 2 stress-test subagent reported 12-14 vulnerabilities per candidate ranked by severity × likelihood. Status of the top-3 per candidate at session close:

- **Stale item-id (score 25, both candidates).** Defensive emit ships in v1; parser-level content-hash ids filed as wish #059.
- **Action-state storage undefined (score 20, candidate B).** Resolved in v1: state lives at `engine.cache["__view_state__"][renderer_id]` with the storage location named explicitly in `engine/actions.py`'s module docstring and in the architecture.md addendum.
- **`dispatch_action` on Engine violates architectural commitment (score 16, candidate B).** Resolved in v1: dispatch_action is a free function in `engine/actions.py`, not a method on Engine. Engine class surface is unchanged.
- **Hot-reload state-shape mismatch (score 12, candidate A; equivalent risk in B).** Partially addressed by defensive reads in emit; full schema-versioning of view-state keys is the open architectural question above.
- **Visual-API translation gap (score 12, candidate A).** Deferred — the dispatch path is forward-compatible with #023 realtime renderer's click handler (pixel → item-id via the `ids` channel, then call dispatch_action with the resolved id).

All score-20+ vulnerabilities are addressed. Score-12 items have documented mitigations or are forward-compatible deferrals.
