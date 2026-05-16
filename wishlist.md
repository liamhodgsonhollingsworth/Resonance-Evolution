# Wishlist

Features the maintainer wants developed, ordered by rough development sequence. Maintained by sessions; the maintainer adds wishes by saying "I want X" or naming features they'd like; sessions file them here. A wish-granting session picks one (or a coherent cluster) from the pending pool, plans deeply with subagent dispatching, builds, ships, and updates the entry's status. The maintainer browses this list as a backlog rather than maintaining it.

Status values:
- `pending` — not yet started
- `planning` — a wish-granting session is in the planning phase
- `granting` — implementation is in flight
- `granted` — implementation landed; the wish-granting session's PR merged
- `superseded` — replaced by a different wish that absorbs this one

The wish-granting session may also produce a result BETTER than the wish — more generalizable, more adaptable. When that happens, the original wish is marked `granted` and a note points at the better implementation.

The append-only meta-convention applies: nothing is deleted, only re-classified.

## Tier A — Foundation for first renderer view

The implementation session for the first renderer view focuses here. Most of these are bounded enough to land together.

- **#001** [pending] — **MCP adapter inside Apeiron.** A node-type whose emit calls a named Alethea-cc MCP tool and returns the result on a channel. Precondition for any panel that reads live data from the corpus.
- **#002** [pending] — **TaskPanel.** Reads tasks.md, renders a vertical list of TaskItem nodes inside its Computer-node region.
- **#003** [pending] — **IdeaPanel.** Reads Alethea's ideas_queue.md (via MCP adapter), renders a list of IdeaItem nodes.
- **#004** [pending] — **WishPanel.** Reads wishlist.md (this file), renders a list of WishItem nodes with status indicators.
- **#005** [pending] — **WorkflowView composite.** The three-panel layout root scene composing TaskPanel, IdeaPanel, WishPanel side-by-side with a top bar and a chat bar.
- **#006** [pending] — **Click-to-expand for panel items.** Generic expand action that takes any panel item and shows its full content plus connections in a sub-renderer overlay. Escape collapses back.
- **#007** [pending] — **SessionRoster + ChatPanel.** Bottom-edge messaging surface: roster of active Claude Code sessions, plus an active-session chat panel showing recent messages and an input field.
- **#008** [pending] — **File-watcher integration for view-refresh.** Wire the existing file-watcher to invalidate precompute caches and re-emit panels when their source files change.
- **#009** [pending] — **Text-compatibility verification suite.** Every panel action (expand, select, scroll, send-message) has a text-equivalent command in the TextRenderer grammar; the suite tests each one.

## Tier B — First-renderer-view enrichments

Next-priority wishes that build on Tier A.

- **#010** [pending] — **Full-render mode toggle.** Press Escape from the three-panel layout to switch to the dream-mode 3D scene; Escape again to switch back. Depends on a working keyboard binding loop.
- **#011** [pending] — **Subagent messaging route.** When a subagent posts to its parent session's log file, the SessionRoster shows the subagent as a sub-entry under its parent.
- **#012** [pending] — **Router node-type.** Sits between chat input and session log files. State holds routing rules (focus-default, @-tags, #-tags). Generalizes the "where does this message go" decision into editable data.
- **#013** [pending] — **Generic Queue node-type + make_queue skill.** When the maintainer says "make a new queue of X," the skill drives the work — no full implementation session needed.
- **#014** [pending] — **mount_panel skill.** Generalizes the work of wiring a new panel into the WorkflowView. Any new panel type becomes a one-skill-invocation away.
- **#015** [pending] — **add_button skill.** Generalizes adding an action button to any panel item.
- **#053** [pending] — **Visual depth indicators for nonlinear reading.** Surfaced from the 2026-05-11 idea-realization-machine transcript: nonlinear documents need explicit visual markers showing how deep a dropdown / branch goes, plus a "shallow read" surface mode. Panel items that expand into longer content show their depth so the reader knows when they're going deeper. Generalizes to: every expandable item carries a depth-hint.
- **#054** [pending] — **Release-cadence system.** Surfaced from the 2026-05-11 transcript: real-time publication with staged visibility control (draft → internal → public). Each artifact has a visibility state; transitions are observable. The system itself iterates on the staging rules through use rather than fixing them in advance.

## Tier C — Workflow integrations (one panel per domain)

Each is a single new panel node-type plus an MCP tool (or direct file read) for its data source.

- **#016** [pending] — **Email panel.** Read recent unread emails; thread-view via expand action.
- **#017** [pending] — **Calendar panel.** Today + upcoming events; calendar-room sub-renderer for spatial browsing.
- **#018** [pending] — **Journal panel.** Composition surface for journal entries; renders the journal log as a timeline.
- **#019** [pending] — **Corpus-browser panel.** Semantic-search interface over the Alethea node graph; results render as expandable items.
- **#020** [pending] — **Finance panel.** Read budget / transactions / balances from connected accounts.
- **#021** [pending] — **Diet / exercise / health panel.** Daily tracking surface with trend visualization.
- **#022** [pending] — **Reading-list panel.** Pending reads, in-progress reads, completed reads with notes.
- **#055** [pending] — **Voice input for workflow control.** Surfaced from the 2026-05-11 transcript's "everything integrated" vision. Voice channel alongside text for chat input. Composes with the input-as-channel generalization (#041) — voice writes to the same input channel that mouse, keyboard, scroll write to. Realtime transcription via a wrapped service (e.g. Whisper) feeding the chat input. Out-of-band: voice commands route through ChatInterpreter the same way typed commands do.
- **#056** [pending] — **Write-for-all-readers-and-let-them-propagate.** Surfaced from the 2026-05-11 transcript: optimize the publication output for every reader type, then let each segment propagate the ideas to their natural networks rather than the maintainer manually distributing. Renderer-side implication: every artifact has multiple reading depths (one-line, one-page, full doc), each complete at its level. Each depth has its own share link.

## Tier D — Dream-mode core features

The features the prior dream-features-skeleton session set up but didn't fully implement.

- **#023** [pending] — **Realtime renderer + windowing library.** Wraps a windowing library (moderngl-window or pygame); pumps InputEvents through the active KeyBindings; closes the input → view-mutation → render loop. The precondition for all interactive dream-mode features.
- **#024** [pending] — **Minecraft-like control bindings active.** Bindings.default()'s WASD + mouse-look + scroll-zoom + space-jump + double-tap-gravity-toggle wired into the realtime renderer.
- **#025** [pending] — **Full-screen interactive mode.** The renderer takes over the screen; toggleable via Escape with the WorkflowView.
- **#026** [pending] — **Procedural seed-zoom visual.** Sphere from outside, world from inside; compose existing Sphere + Computer + Portal + Seed.
- **#027** [pending] — **Full N-D shape catalog beyond hypercube.** Simplex and cross-polytope already shipped as DimensionN shapes; extend to hyper-sphere, cross-tetra, and shape:"custom" with caller-provided vertices.
- **#028** [pending] — **Generator subtypes with rich invert hooks.** TerrainGenerator, PlantGenerator, AgentGenerator — each with gradient-based or learned inversion. Demonstrates the architecture's "different generators have different inversion algorithms" promise.
- **#029** [pending] — **Trajectory renderer.** Consumes SimulationProbe's simulation channel and overlays predicted paths.
- **#030** [pending] — **World-sphere composite.** Single composite node-type packaging Sphere + Computer + Portal + Seed into the dream-mode zoom-into-a-world primitive.

## Tier E — Far-out features (from extensions doc)

These were named in [dream_features_extensions.md](design/dream_features_extensions.md) as features that compose cleanly with the existing architecture.

- **#031** [pending] — **Time-as-navigable-dimension + timeline scrubber.** View.time exists; TimeRewinder node-type reads git history or local seed-version log and exposes scrub controls.
- **#032** [pending] — **Sound channels + SpeakerRenderer.** Audio channel name; spatial audio via Portal transform.
- **#033** [pending] — **Co-presence — multiple viewers in one engine.** Each viewer is a renderer-node; avatar-nodes render other viewers' positions.
- **#034** [pending] — **Persistent dreams — engine state across sessions.** cache_persist_hook companion to precompute_hook.
- **#035** [pending] — **ForceField generalization.** GravityField becomes ForceField with a `kind` field; magnetism, currents, attractors.
- **#036** [pending] — **Constraints as nodes.** ConstraintNode observes targets and enforces relationships.
- **#037** [pending] — **DreamTransition between scenes.** Cross-fade rendering plus topology over a duration.
- **#038** [pending] — **Gaze-driven adaptation.** Renderer reports gaze attention; nodes feed back on what the viewer looks at.
- **#039** [pending] — **Resonance-driven node ordering.** Visit-count-affects-detail; aggregator threshold becomes a function of engagement.
- **#040** [pending] — **SceneEmbed — dreams about dreams.** A node-type whose content connection points to another scene file.

## Tier F — Architectural generalizations

Promotions of primitives that absorb the original eleven dream-mode features plus broader future ones.

- **#041** [pending] — **Input-as-channel.** Generalize InputEvent to a channel. Mouse, keyboard, scroll, voice, BCI all write to the same channel; Bindings becomes a node-type that transforms input channels into mutation channels.
- **#042** [pending] — **Mutation-with-inverse as first-class.** MutationLog (append-only); every mutation carries an inverter ID; undo/redo are log-replay primitives.
- **#043** [pending] — **Federated node-types.** Peers' git repos become importable node-type sources; the engine's discovery walks `peers/*/node_types/` plus the local `node_types/`.

## Tier G — Team workflow + collaboration

Wishes for when the workflow extends beyond the maintainer.

- **#044** [pending] — **Email integration for human collaboration.** When a session needs human input that another team-member should provide, route through email; reply parses back into a chat-log message.
- **#045** [pending] — **Multi-Claude-Code-session orchestration.** A node-type that manages spawning and routing across multiple concurrent CC sessions; the SessionRoster surfaces them.
- **#046** [pending] — **Team management view.** The maintainer's project-manager surface: all sessions, all subagents, all in-flight wishes, all PRs in one panel.
- **#047** [pending] — **Github management integration.** PR statuses, review state, branch divergence visible in the workflow view; click to open PR; merge action available.

## Tier H — Natural language layer

The interpreter layer the maintainer named as "deferred for later."

- **#048** [pending] — **Chat-driven world building with novelty fallthrough.** Already started via ChatInterpreter; needs the parse pipeline of layer-nodes to grow.
- **#049** [pending] — **Evolving interpreter graph.** Parse layers as connected node-types; chaining via connections IS the grammar.
- **#050** [pending] — **Voice-to-tool interpreter.** Natural-language input maps to procedural-tool invocations; the procedural tool catalog from Tier B becomes the action vocabulary.

## Meta — the wishlist itself

- **#051** [pending] — **Procedural tool recorder.** Each time a wish is granted, the wish-granting session ALSO produces a tool that makes the same shape of wish easier next time. The accumulator is structural; the catalog grows.
- **#052** [pending] — **Wish-grants-better-than-wished.** Wish-granting sessions explicitly try to produce something better than the wished-for feature — more adaptable, more generalizable. The session compares its output against the wish and notes what improvements landed.
- **#057** [pending] — **Periodic transcript-mining cadence.** A session or scheduled task that walks the imported claude.ai transcripts plus recent Claude Code session handoffs, looking for workflow directives that haven't been captured in the current wishlist / memory / conventions. Surfaces uncaptured items as candidate wishes. Today this only happens when a session remembers to run it on-demand; making it periodic catches directives sooner. Could compose with the scheduled-tasks MCP tool already available in the harness, or live as a session type whose only role is mining + filing.

## Granted

(None yet.)

## Superseded

(None yet.)

## How to add to this list

The maintainer adds wishes by saying what they want during any session. The receiving session files the wish here as a new pending entry at the next available number, in the appropriate tier (best-guess; tiers can be re-shuffled).

Wish-granting sessions update entries' status as they progress. When an implementation lands, the entry moves to `granted` and a link to the merged PR is appended.

This page is an [evolving index](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/evolving_indexes.md).
