# Procedural-tools pattern — the accumulator

The structural mechanism by which the workflow becomes more automatic over time. Every wish-granting session produces, alongside the wished feature, a tool that makes the same shape of future wish easier — a skill, a process-node, a helper node-type, or a verb in the text-renderer's command grammar. The accumulator catalog grows; the work of each successive wish-grant shrinks; in the limit, common requests become procedural invocations rather than full implementation rounds.

This document specifies the pattern: what counts as a tool, how tools accumulate, what makes the accumulator catalog navigable, and how the pattern composes with the engine's everything-is-a-node commitment.

## What counts as a tool

A tool is anything that takes a wish-shape and produces an implementation with less work than the original wish-grant required. Five concrete shapes:

- **Skill.** A markdown file in `skills/` describing a procedure. Read by sessions when the shape matches. Example: `mount_panel` — describes how to wire a new panel into the WorkflowView, with the wired-up files and the binding entries named at the right level.
- **Process-node.** A `ProcessNode`-typed node in the Alethea-cc corpus with a body of `TOOL` / `CALL` / `READ` / `SHELL` / `PYTHON` / `RETURN` step lines. Executable directly via `execute(handle)`. Example: a process-node that adds a new panel to a scene by spawning the panel, adding it to the WorkflowView's connections, and updating the scene JSON.
- **Helper node-type.** A node-type whose role is to make composition easier rather than render content. Example: a `PanelMount` node-type whose state is the panel-spec and whose emit recursively delegates to the spec's named renderer.
- **Verb in the text-renderer's command grammar.** A new command word the TextRenderer's grammar accepts. Example: `expand <id>` becomes a verb after the click-to-expand wish lands; any subsequent panel-expansion need uses the same verb.
- **Engine hook.** A new function name the engine's discover-and-dispatch machinery recognizes (`precompute_hook`, `sim_precompute_hook`, `invert_hook`, `select_children`, `step`, `describe` — and any future ones). Example: if a future wish adds time-driven state, the engine could grow a `time_hook(state, dt) -> state'` that future stateful node-types implement.

Every shape is a node — the everything-is-a-node commitment holds. Skills are markdown nodes; process-nodes are explicitly nodes; helper node-types are nodes by definition; command-grammar verbs are entries in the TextRenderer's state which IS a node; engine hooks are functions registered against modules which ARE nodes. The accumulator catalog is not a parallel system; it's the same node graph extending in different ways.

## How tools accumulate

The accumulator's growth path:

1. Maintainer says "I want X." X is filed as a wish.
2. Wish-granting session implements X. **In the same session,** the implementer asks: what shape was this work? Is there a tool that would have made it shorter? If yes, build the tool.
3. The tool is named, documented, and added to the appropriate catalog (skills catalog, process-node corpus, node-types directory, etc.).
4. The wishlist's Granted section gets an entry for the wish AND a sibling entry for the accumulator-tool.
5. Maintainer says "I want Y" where Y has the same shape as X. The next wish-granting session reads the wishlist, sees the accumulator-tool from X, and applies it. The implementation work is bounded.
6. Across many wishes, the catalog grows. Most common shapes get tools first because they recur most.

**The "is there a tool" test.** Phase 3 of the wish-granting procedure makes this a procedural step, not a postscript. The five tool-shapes above are the test's vocabulary. If the answer is "no useful tool emerges from this wish," the session writes one line explaining why — typically "the wish was too specific to generalize" or "the work was already covered by an existing tool." This forces the question rather than letting silence be the default.

## What makes the catalog navigable

A catalog that grows without organization decays into a junk drawer. The pattern requires three navigation primitives:

- **By shape.** Each tool declares its shape (which of the five above) plus a one-line "matches wish-shape" description. Future wish-granting sessions in Phase 1 grep against shapes to find candidate tools.
- **By wish-lineage.** Each tool links to the wish that produced it. The reverse direction holds: each granted wish in the wishlist names the tool it produced. Tracing forward (wish → tool) and backward (tool → wish) both work.
- **By composability.** Tools that compose together get cross-linked. Example: `mount_panel` composes with `add_button`; both compose with the click-to-expand verb. The catalog surface for skills and process-nodes uses standard meta-layer index conventions; cross-links live as bullet entries in each tool's evolution-notes section.

When the catalog exceeds ~30 entries, a topical reorganization may be warranted. The accumulator's own growth produces wishes about the catalog (a `Tool catalog browser panel` would be a Tier B+ wish itself); the system bootstraps its own organization.

## Examples (instantiated as Tier A wishes are granted)

These are the accumulator-tools expected to land alongside the Tier A wishes. Each is provisional until the wish-granting session actually produces them — the shape is the spec, not the literal name or content.

- **`mount_panel` skill** — produced alongside wish #002 (TaskPanel). Wires a new panel into the WorkflowView's three-panel layout: spawns the panel-node, adds it to the connections map, updates the scene JSON, validates the layout doesn't break. Used directly by wishes #003, #004, and any later panel wish.
- **`DataSourceAdapter` node-type** — produced alongside wish #001 (MCP adapter). Generalizes "this panel reads from an external data source" to a single helper node-type. Subsequent wishes that pull data from anywhere (Gmail, calendar, finance APIs) reuse the adapter rather than writing custom MCP-call wiring per panel.
- **`expand` verb** — produced alongside wish #006 (click-to-expand). Becomes a text-renderer command word. Future expandable items just register against the verb's dispatch table.
- **`Router` node-type** — produced alongside wish #007 (SessionRoster + ChatPanel). Generalizes "where does this message go" to editable routing rules. Future messaging extensions (subagent route, @-tag route, #-tag route) ride this primitive without re-implementing dispatch.

The pattern is recursive: the accumulator-tool catalog is itself a wish-grant outcome, so the catalog's own organization improves as it grows.

## How the pattern composes with hot-reload

The file-watcher landed in [Apeiron PR #14](https://github.com/liamhodgsonhollingsworth/Apeiron/pull/14) makes accumulator-tools land in real time. A wish-granting session drops a new skill file or a new node-type file; the next chat command can invoke it. The maintainer doesn't need to restart anything between "the wish-granting session finished" and "the new tool is available." The accumulator catalog grows continuously rather than session-to-session.

## How the pattern composes with text-compatibility

Every accumulator-tool has a text invocation surface. Skills are invoked by chat command (the maintainer or Claude Code says the skill's trigger phrase). Process-nodes are invoked by `execute(handle)`. Helper node-types are spawned by `spawn` commands. Engine hooks are exercised by the existing precompute/sim_precompute/invert_edit calls. Text-compatibility is therefore not a separate concern — the tools are designed to be text-invoked by construction.

The limit case the maintainer named — "in the limit case, everything will be procedural and the program will be able to move around according to what I want without needing claude code" — is the catalog grown large enough that almost every common request maps to a tool invocation. Claude Code's role narrows from implementer to selector: which existing tool fits this request, and does it need extension. Eventually even the selection becomes procedural (the natural-language interpreter from Tier H), but that's a deferred wish.

## What this pattern does NOT promise

- It does not promise that EVERY wish produces a useful tool. Some wishes are too specific or too one-off.
- It does not promise that tools, once made, are forever correct. Tools can become wrong-shaped as the system grows; the wishlist + wish-granting procedure can produce a wish to revise an old tool.
- It does not promise that the catalog stays small. The catalog grows; navigation becomes the bottleneck before total-tool-count does. Plan for organization wishes alongside feature wishes.
- It does not promise that the catalog substitutes for understanding. Sessions still need to read and reason about the codebase; the catalog accelerates known patterns, not novel architectural work.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — produced once during the parallel wish-granting-expansion session, frozen at session close.
