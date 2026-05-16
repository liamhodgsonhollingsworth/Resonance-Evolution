# 2026-05-16 — First renderer view: Tier A wish cluster granted

Wish-granting session that landed the maintainer's first interactive workflow surface — three live panels (Tasks, Ideas, Wishlist) composed via a DataSource + Renderer orthogonal primitive.

## Wishes granted

From [wishlist.md](../../wishlist.md):

- **#001 MCP adapter inside Apeiron** — landed as `MCPSource` node-type.
- **#002 TaskPanel** — landed as `FileSource(parser=tasks) + ListRenderer` composition.
- **#003 IdeaPanel** — landed as `FileSource(parser=ideas) + ListRenderer`. (Future swap to `MCPSource` once Alethea-cc moves to HTTP per Alethea pending #005.)
- **#004 WishPanel** — landed as `FileSource(parser=wishes) + ListRenderer`.
- **#005 WorkflowView composite** — landed as `WorkflowView` composition node-type + `scenes/workflow_view.json`.
- **#009 Text-compatibility verification suite** — landed as `tests/test_workflow_view.py` (21 tests) plus fresh-subagent verification of every panel surface via `describe_scene` and `dispatch_command`.
- **#014 mount_panel skill** — landed as `Alethea/skills/mount-panel.md`, the accumulator skill for future panel mounts.

## The BETTER-than-wish generalization

The wishlist asked for three concrete panel node-types. The session shipped a **DataSource + Renderer orthogonal primitive** that absorbs the original three AND:

- All seven Tier C panels (#016-#022: Email, Calendar, Journal, Corpus-browser, Finance, Diet/exercise/health, Reading-list) become one-line scene-JSON compositions (one source-config + one renderer-config + one connection), driven through the `mount-panel` skill rather than full implementation rounds.
- Tier E filter-node features (#038 gaze adaptation, #039 resonance-driven ordering) compose as additional node-types sitting between source and renderer on the same `items` channel — no architecture change required to reach them.
- A new visualization shape (TimelineRenderer for Calendar, GridRenderer for finance) is a single new renderer node-type that pairs with the existing FileSource/MCPSource — the data-side never changes.

The three BETTER-than-wish tests from the session-type doc:

1. **Absorbs other pending wishes?** YES — #014 (mount_panel skill) is granted as part of this work; #013 (Generic Queue node-type) becomes a thin FileSource-with-append-parser wrapper; Tier C's seven panels and Tier E's #038/#039 become composition exercises rather than implementations.
2. **Exposes a primitive future wishes compose against?** YES — the `items` channel shape `{id, title, body, status, meta}` is the load-bearing contract; any DataSource that emits it pairs with any Renderer that consumes it.
3. **Fresh reader understands the feature from one node-type file?** YES — `node_types/workflow_view.py` is 100 LOC and a fresh subagent (verified during Phase 4) used the feature end-to-end through the text-API without prior context.

## What landed

- `node_types/file_source.py` — DataSource that reads a file via named parser, caches via precompute_hook.
- `node_types/mcp_source.py` — DataSource that calls an Alethea-cc MCP tool via direct import + caches; graceful degrade.
- `node_types/list_renderer.py` — Renderer that owns a screen rectangle and draws a vertical list with status glyphs.
- `node_types/workflow_view.py` — composition node-type holding three panel children plus future top/chat-bar slots and a full-render-mode toggle.
- `node_types/parsers/{__init__.py,tasks.py,ideas.py,wishes.py}` — normalized item-list extractors auto-discoverable by short name.
- `scenes/workflow_view.json` — three-panel demo scene rendering Tasks / Ideas / Wishlist side-by-side.
- `tasks.md` — placeholder source file at project root; edit it to update the live TaskPanel content.
- `examples/ideas_queue_sample.md` — portable fallback for the Ideas panel; production swap is `MCPSource` against Alethea-cc.
- `tests/test_workflow_view.py` — 21 tests covering parsers, sources, renderer, WorkflowView, end-to-end scene, and failure isolation.
- `skills/mount-panel.md` (in the Alethea repo) — the accumulator-pattern skill codifying the next-panel procedure.

## Test status

84 tests pass (31 engine + 26 dream-features + 4 file-watcher + 21 workflow-view + 2 misc); zero regressions.

## Visual demo

`python -m tools.render scenes/workflow_view.json --output output/workflow_view` writes a bundle showing all three panels with item content, status glyphs, status colors, and the failure-isolation pattern (one panel's source-error rendered inline doesn't break the others).

## Suggested next-session priorities

Ranked by leverage given the new primitive:

1. **Wish #006 click-to-expand** — items already carry stable IDs (`wish:001`, `task:N`, `idea:N`) and a `body` field; the click-handler is the remaining work. Most natural shape: an `ExpandHandler` node-type that listens for a `click(item_id)` event channel, mutates a `focused_item` field on the WorkflowView, and the engine's `select_children` swaps to an expanded-view renderer for the focused panel.
2. **Wish #007 SessionRoster + ChatPanel** — the `chat_bar` and `top_bar` connection slots on WorkflowView are already wired; this is a new node-type + scene-JSON edit per the mount-panel skill.
3. **Wish #008 file-watcher integration for view-refresh** — the file-watcher already exists for node-type files; extending it to source-data file paths triggers precompute re-runs, making panels reactively update without re-render commands.
4. **One Tier C panel** to validate the mount-panel skill end-to-end — recommend Email panel (#016) since it exercises MCPSource against a not-yet-existing MCP tool.

## What this doesn't try to do yet

- The realtime renderer (wish #023) is the precondition for actual click/keyboard interaction; the current panels are observed via the text-API and the static-render bundle. Full interactivity comes when the realtime renderer lands.
- The MCPSource is wired but the workflow_view demo scene uses FileSource for ideas (with an Apeiron-local sample) for cross-machine portability. The MCPSource path is fully tested but not yet exercised by the demo scene.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — created during the wish-granting session, frozen at session close.
