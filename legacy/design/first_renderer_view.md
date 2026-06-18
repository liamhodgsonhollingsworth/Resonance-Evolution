# First renderer view — the workflow surface

The plan for Apeiron's first non-demo renderer: a three-panel task management view that becomes the maintainer's daily workflow surface. Composes the [hot-reload + file-watcher](workflow_from_within_apeiron.md) feasibility proof with the existing node-types catalog into a usable workspace.

A separate implementation session picks up this plan; this document is the spec.

## What this renderer is

A single Apeiron scene whose root composes three panels side-by-side: **Tasks**, **Ideas**, **Wishlist**. Each panel is itself a Computer-node — a renderer-as-node sub-graph that owns its screen region. A persistent ChatInterface sits along the bottom edge of the page; the active-session indicator and full-render toggle sit along the top.

The maintainer's daily workflow lives inside this scene. They see what's pending, what's queued, and what's wished-for. They click any item to expand it. They type into the chat to talk with active sessions. They press Escape to switch to a full-render mode where the dream-mode 3D world takes over the full screen; Escape again returns to the three-panel layout.

## Layout

```
┌────────────────────────────────────────────────────────────────┐
│  active session: <name>     [Esc] full-render mode             │  <- top bar
├──────────────────┬──────────────────┬──────────────────────────┤
│  Tasks           │  Ideas           │  Wishlist                │
│                  │                  │                          │
│  - task 1        │  - idea A        │  - wish #1               │
│  - task 2 ●      │  - idea B        │  - wish #2 (granting)    │
│  - task 3        │  - idea C ●      │  - wish #3               │
│  - task 4        │  - idea D        │  - wish #4               │
│                  │                  │  - wish #5               │
│                  │                  │  - wish #6               │
│                  │                  │                          │
├──────────────────┴──────────────────┴──────────────────────────┤
│  > _                              session: dream-features-impl │  <- chat bar
└────────────────────────────────────────────────────────────────┘
```

(● marks the item currently focused/selected. Each panel scrolls independently.)

## The three panels

### Tasks panel

Source: a task list file, format TBD by the implementation session. Each task is a line with `[ ]` / `[x]` / `[~]` (open/done/in-progress) plus a short title plus an optional inline note.

Rendered as a vertical list of `TaskItem` nodes inside a `TaskPanel` Computer-node. Clicking a task expands it into a sub-panel showing the full text plus related-node links. Pressing Escape from the expanded view collapses back.

Source-of-truth file: `tasks.md` at project root, plain markdown so it's editable from outside the renderer too.

### Ideas panel

Source: Alethea's existing [ideas_queue.md](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/ideas_queue.md), accessed via the MCP adapter (Phase 1 of the workflow-from-within plan). Each entry in the queue is an `IdeaItem` node. Clicking opens the full idea text plus its connections.

Future: replaces with a live query against the corpus rather than a static file read. The MCP adapter's `semantic_search` and `unified_search` tools let the Ideas panel update reactively based on what the maintainer is working on.

### Wishlist panel

Source: `wishlist.md` at the Apeiron project root. Each entry is a `WishItem` node with `pending` / `granting` / `granted` status. The implementation session for any wish updates the entry's status.

The wishlist is created and maintained by sessions, not the maintainer. When the maintainer says "I want X feature," a session files it as a new wish. When a wish-granting session lands an implementation, the wish moves to `granted`.

## Open-any-node interaction

Clicking any item in any panel opens it in expanded view. The expanded view is a sub-renderer that takes over the clicked panel's region and shows:

- The item's full text.
- Its connections (related tasks, ideas, wishes, or other corpus nodes).
- Its action buttons (mark done, escalate to wish, attach to session, etc.).
- A back arrow / Escape-key handler to collapse back to the panel.

"Any node" generalizes beyond panel items. The same expand-on-click mechanism opens any corpus node referenced from any item. The Alethea corpus is browsable through the panel system; the panel system is a particular UI on top of the same node graph that contains everything else.

## Full-render mode

Pressing Escape from the three-panel layout switches the scene's renderer to the dream-mode 3D root (the same scene used by `dream_topology_demo.json` and friends). Escape again switches back to the three-panel layout.

Implementation: a top-level `WorkflowView` node-type with a `mode` state field (`"panels"` or `"full_render"`). Its `select_children` returns either the three panels or the full-render subtree depending on mode. A keyboard binding (via the existing `engine/input.py` Bindings.default mapping; future Escape binding to be added) toggles the field.

## Messaging system

A persistent chat bar along the bottom of the panel layout. Typed input routes to the currently-active session via the existing `ChatInterface` log-file pattern.

### Session roster

Multiple Claude Code sessions may be running concurrently. A `SessionRoster` node owns the bottom-right corner of the chat bar; it displays the list of active sessions plus their statuses (active, waiting-for-input, idle). The maintainer cycles through with Tab or clicks a name to switch focus.

Each session's chat log lives at `Alethea-cc/nodes/inbox_msg_*.md` per the existing parallel-development inbox convention, OR at a per-session file like `logs/session_<id>.md`. The implementation session picks the convention; the choice is bounded and reversible.

### Subagent messaging

When a subagent needs the maintainer's input, it posts to the same channel its parent session uses. The `SessionRoster` shows the subagent as a sub-entry under the parent session. The maintainer's response routes back via the parent session for context preservation.

The generalization: ANY entity that wants to message the maintainer writes to a chat log file. The renderer surfaces it. The system doesn't distinguish Claude Code sessions from subagents from future-humans-on-the-team. All are entries in the same roster.

### Hot-update on incoming message

When a new line appears in any chat log file, the file-watcher (already shipped) triggers re-precompute of the `SessionRoster` and the `ChatPanel` for the affected session. The view updates without manual refresh.

### Message routing

A `Router` node-type sits between the chat input and the session log files. State holds the routing rules. Default: input goes to the currently-focused session. Future: rules like "messages starting with @<subagent_name> route directly to that subagent" or "messages tagged #wishlist file as wish instead of session-message."

## Hot-reload guarantee

The file-watcher landed in [Apeiron PR #14](https://github.com/liamhodgsonhollingsworth/Apeiron/pull/14) makes the load-bearing claim concrete: a new node-type file dropped into `node_types/` is picked up at runtime without engine restart. The implementation session can wire panels, expand-views, messaging, full-render-mode toggles, anything — each as its own node-type file. A Claude Code session running on this renderer can debug a broken panel by editing its file; the engine reloads automatically; the maintainer sees the fix.

**Failure isolation guarantee.** A broken node-type returns a placeholder under the engine's try/except wrapper. One panel breaking does NOT take down the renderer — the broken panel renders as a magenta placeholder while the other two panels and the chat bar keep working. This is the node-modularity-as-UX-guarantee that the maintainer named directly: "one feature not working does not affect the other features not working."

## Procedural tools — the accumulator pattern

Every wish the maintainer makes can fall into "first-time" or "I've-asked-for-this-shape-before." The accumulator pattern: each time a wish-granting session implements something, it ALSO produces a tool that makes the same shape of wish easier next time.

Examples:

- Maintainer says "make a new queue." Implementation session creates a generic `Queue` node-type AND a `make_queue` skill or process-node. Next time the maintainer says "make a queue of X," the skill drives the work; no full implementation session needed.
- Maintainer says "show me my email." Implementation creates an `EmailPanel` node-type AND a `mount_panel` skill that generalizes the "wire a new panel into the layout" work. Next time a new panel is wanted, the skill mounts it.
- Maintainer says "add a button that does Y." Implementation creates the button AND a `add_button` skill.

The tools accumulate. Each is a node — process-node, skill file, or new node-type with a specific role. Over time, the maintainer's voice commands map to procedural tool invocations rather than full implementation rounds. The implementation sessions become rarer, and shorter, as the tool catalog grows.

The interpreter that maps voice to tool invocations is deferred (the maintainer named this explicitly). For now, the tools are invoked via explicit chat commands; the natural-language layer is future work.

## Text compatibility

Every interaction in the renderer has a text equivalent. Click-to-expand is also `expand <item_id>`. Switch sessions is also `switch <session_name>`. Toggle full-render is also `toggle full_render`. Filing a wish is also `wish "<text>"`. The existing `TextRenderer` + `tools/text_test.py` command grammar IS the text-API for the renderer; the implementation session extends it as new actions are added.

This is what lets Claude Code test the renderer's full functionality without the maintainer needing to verify visually. A Claude Code session running headless can: open the renderer, expand a wish, see the description, fire the "grant" action, observe the wish-grant flow, all through text. The maintainer's testing burden is then bounded to: "is the design what I want?" — not "does it work?"

## What the implementation session does first

Sequenced for one session of work:

1. **MCP adapter inside Apeiron** — a `node_types/mcp_call.py` node-type whose emit calls a named MCP tool and returns the result on a channel. The Ideas panel and the corpus-browsing parts of the wishlist panel depend on this.
2. **Three panel node-types** — `TaskPanel`, `IdeaPanel`, `WishPanel`, each reading from its source file and rendering a vertical list of items.
3. **`WorkflowView` composite** — the three-panel layout with the top bar and chat bar.
4. **`expand` action** — click-to-expand for any panel item.
5. **`SessionRoster` + `ChatPanel`** — minimal messaging surface, single-session first.
6. **End-to-end text-compat test** — run the renderer through the text-renderer command grammar; verify every action has a text equivalent and the engine produces the expected post-state.
7. **Wire the file-watcher to refresh on chat-log + task/wishlist file changes.**

Out of scope for the first implementation session (move to subsequent ones):

- Full-render-mode toggle (depends on a working keyboard handler, which depends on the interactive renderer that hasn't been built yet).
- Subagent messaging routes.
- Procedural tool accumulator beyond what the implementation session builds.
- Voice-to-tool interpreter.
- Real-time multi-session updates with conflict resolution.

## Open design choices for the implementation session

- **Panel rendering: text vs. mini-3D.** Each panel is a Computer-node that renders into a screen region. The implementation could use TextRenderer for plain-text rendering of the panel content (fastest path) or a small 2D-raster renderer that draws cards (more visually distinctive). Recommendation: start with text-rendering since the text-compat path is the priority; aesthetic upgrade is a later session.
- **Task file format.** Markdown checklist is the obvious default. An alternative is a JSON-with-metadata format that the renderer parses directly. The choice depends on whether the maintainer edits tasks from outside the renderer (which favors markdown) or only from inside (which permits JSON).
- **Session-log location.** `Alethea-cc/nodes/inbox_msg_*.md` is the existing parallel-development convention; `logs/session_<id>.md` in Apeiron is the renderer-local alternative. The cross-machine question matters: if the maintainer wants to talk to a session running on a remote machine, the renderer needs to access remote logs (HTTP via MCP adapter). Inbox convention generalizes more naturally; recommendation: use it.
- **Wishlist file format.** Markdown with status emoji prefixes per item. Easy to grep, easy for sessions to update.

## What this doesn't try to do yet

- It doesn't try to be the workflow surface for everything (email, calendar, finances). Those are future panels added through the wish-granting pipeline.
- It doesn't try to look pretty. The aesthetic upgrade arc is independent; the workflow is the priority.
- It doesn't try to replace Claude Code's terminal. It composes with it — the terminal is the maintainer's escape hatch when a panel-level action doesn't fit.
- It doesn't try to do federation. Single-user, single-machine, single-Claude-Code-network. Federation comes later per the [extensions doc](dream_features_extensions.md#b3-federated-node-types-as-first-class-import).

## How this composes with the wish-granting workflow

The maintainer is the project manager. The implementation session(s) are the programming team. The wishlist is the backlog. The wish-granting session type formalizes the implementation work: pick a wish, plan with heavy subagent dispatching, build, test, ship. The renderer view's Wishlist panel is the live backlog the maintainer browses to direct attention. As the maintainer says "grant wish N," a wish-granting session spins up and the panel updates in real time as the wish progresses.

See [the wish-granting session type](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/session_types/wish_granting.md) for the full procedure.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — produced once during the renderer-view planning session, frozen at session close.
