# Workflow-from-within-Apeiron — feasibility and plan

A plan toward the maintainer's described workflow where the entire daily-work surface runs inside Apeiron, with Claude Code generating new code modules that load in real time without restarting the program. Composes the [Apeiron](https://github.com/liamhodgsonhollingsworth/Apeiron) engine with the [Alethea-cc MCP server](https://github.com/liamhodgsonhollingsworth/Alethea/tree/main/Alethea-cc) already operational on the maintainer's machine.

## The transcript this plan responds to

The 2026-05-11 claude.ai conversation [Building an idea realization machine through nonlinear publishing and integrated AI systems](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/Alethea-cc/nodes/transcript_share_3c9971b5-0e65-4faa-b73c-ab5b8c403491_building_an_idea_realization_machine_thr.md) named the workflow vision in eleven numbered points. Points 2–5 are load-bearing for the present plan:

- Point 2: integrate the maintainer's full workflow (work + life: gmail, drive, calendar, notion) under a single surface where Claude is a parallel agent maintaining persistent memory and testing its own memory access.
- Point 3: not just integration but adaptation — the system finds ways to do things better and finds things to do better.
- Point 4: one hub for finances, diet, exercise, health, reading analysis.
- Point 5: the workflow should both push the maintainer to grow and maintain creative flow without interruption.

The transcript's framing was Claude-as-hub. The present refinement is **Apeiron-as-hub-surface, with the MCP server as the cognitive substrate underneath, and Claude Code as the code-generation channel that extends the system at runtime**. The change is which program the maintainer is inside while working — not Claude Code's terminal, but a 3D dream-mode environment whose rooms ARE the workflow contexts.

## What the current implementation already provides

The components that compose the unified workflow already exist as separate, working subsystems. The plan below is mostly integration — building the bridges between subsystems and the missing piece (a file-watcher) that closes the hot-reload loop.

### From Apeiron

- **Hot-reload entry point.** `engine/core.py::Engine.reload_type(type_name)` re-imports a node-type module by re-importing its file and swapping the registration. Validated in PR #1.
- **Discovery.** `Engine.discover()` walks `node_types/` and `renderers/` once at session start.
- **Chat side-channel.** [ChatInterface](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/node_types/chat_interface.py) owns a screen rectangle and renders a chat log file. Claude Code reads and writes the file externally; the engine visualizes the current contents.
- **Chat command parsing.** [ChatInterpreter](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/node_types/chat_interpreter.py) (dream-features skeleton) classifies chat messages as known/novel/noise. When `claude_connected: true`, novel messages get a `requested: <cmd>` line appended for Claude Code to pick up.
- **Bidirectional text-renderer.** [TextRenderer](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/renderers/text.py) exposes a command grammar (`describe`, `spawn`, `connect`, `move`, `look-at`, `render`, `render-text`) and accepts text commands that mutate the graph.
- **Recursive worlds.** [Computer node-type](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/node_types/computer.py) hosts sub-graphs with their own renderers. Each workflow context (a "room" in the dream-mode topology) can be a Computer with its own internal renderer and content.
- **The dream-mode infrastructure** from the prior session lands all the input + navigation primitives the workflow surface needs.

### From Alethea-cc (the MCP server)

The MCP server has been running on the maintainer's machine since 2026-04-29. Per its [CLAUDE.md](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/Alethea-cc/CLAUDE.md):

- **~35 MCP tools** spanning CRUD on 2330 nodes, four search backends, graph traversal, three Notion databases, process-nodes (recursive executable graphs), and the `reflect()` cognitive primitive (RAG-with-persistence).
- **Universal executor.** `execute(handle)` dispatches by frontmatter `type`: Python, Shell, Macro, ProcessNode. Code, scripts, and processes are all first-class nodes.
- **Self-modification.** `add_tool(name, description, code)` writes a plugin at runtime; `reload_plugins()` re-scans. The MCP server CAN ALREADY add tools to itself at runtime.
- **Three transports.** stdio (Claude Code default), `streamable-http`, `sse`. The maintainer's Claude.ai connector can talk to a remote MCP server over HTTP.
- **Code primitives.** `exec_shell` and `exec_python` are MCP tools; any session can run shell or Python from within the MCP graph.

The maintainer's existing daily workflow already lives partly inside this system: ideas in the corpus, Notion mirrors, search across backends, conversation transcripts importable. What's missing is the SURFACE — the maintainer still works in Claude Code's terminal, not inside a navigable spatial environment.

## The unified vision

The maintainer puts on a VR headset or sits at a desk with Apeiron running in full-screen mode. The dream-mode 3D environment is the workspace. Different ROOMS are different workflow contexts:

- An **Ideas room** where Alethea corpus nodes float as visible 3D objects; semantic-search results cluster spatially; resonance scores affect node visibility.
- A **Mail room** where unread emails appear as cards; conversation threads run as Portal-connected sub-rooms.
- A **Calendar room** with time as a literal axis the viewer walks along.
- A **Journal room** where text composition happens through the chat interface; the journal's history is a navigable timeline (composes with the [time-as-navigable-dimension feature](dream_features_extensions.md#1-time-as-a-navigable-dimension) from the dream-features extensions).
- A **Code room** showing the engine's own node-type files as rendered objects, editable in-place.
- Plus rooms for finances, diet, reading, brainstorming, and any new domain that emerges.

A persistent **ChatInterface panel** is visible from every room — the universal control surface. Typing into it routes through the **ChatInterpreter** which:

1. Recognizes the message as a known command → dispatches via the text-renderer's command grammar OR a registered MCP tool call.
2. Recognizes the message as a workflow request → calls the corresponding MCP tool (search the corpus, read email, schedule an event, log a journal entry).
3. Recognizes the message as novel → routes to Claude Code via the chat-log side channel. Claude Code reads the request, decides whether it can be handled by an existing tool, and if not, generates a new node-type or MCP tool, writes it to the appropriate directory, and the file-watcher picks it up. The next chat message can use the new capability.

## Feasibility of hot-reload without restart

**Direct answer: yes, with one missing piece this session adds.** The architectural primitives are all in place; the only gap is a file-watcher that wires Engine.reload_type() to filesystem changes.

The full mechanism:

1. **Claude Code receives a request** by reading the chat log file. (Existing — ChatInterface + ChatInterpreter.)
2. **Claude Code decides the request needs a new node-type.** It generates the Python file with `manifest()`, `build()`, `emit()` per the node-type protocol described in [architecture.md](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/architecture.md).
3. **Claude Code writes the file** to `node_types/<new_type>.py`. (Just a file write — Claude Code does this directly.)
4. **The file-watcher detects the new file** and calls `engine._load_node_type_file(path, "node_types")`. (NEW — this plan's deliverable.)
5. **The engine registers the new type.** Now available for `spawn()`.
6. **Claude Code sends a `spawn` command** via the chat log → ChatInterpreter dispatches → new node appears in the world.
7. **The viewer interacts with the new node immediately.** No engine restart, no scene reload, nothing.

For UPDATES to existing node-types, the same flow uses `Engine.reload_type(type_name)` instead of `_load_node_type_file`. The watcher detects modifications and dispatches the appropriate call.

**What can break, and the mitigations.** Hot-reload of a node-type whose instances exist in the live graph: the existing NodeInstances retain their state, but next `emit()` uses the new module. Instances created before the reload keep working. State migration across an incompatible-build change is a known concern; the manifest's `version` field is the migration hook (per [engine/node.py](https://github.com/liamhodgsonhollingsworth/Apeiron/blob/main/engine/node.py) `Manifest.version`). The first version of the file-watcher does not run version-migration; it just hot-swaps the module and lets old instances render with the new code. Documented as a v1 limitation.

**What this session ships as the proof.** A `engine/file_watcher.py` module wrapping the [watchdog](https://pypi.org/project/watchdog/) library (already a permissive dependency). A small CLI in `tools/watch.py` that starts the watcher and prints reload events. An end-to-end test that: (a) loads a scene, (b) writes a new node-type file mid-test, (c) verifies the engine sees and uses it without restart.

## Phased plan

**Phase 0 — File-watcher (this session, deliverable).** Closes the hot-reload loop. Single Python file plus tests. After this lands, the architecture's "claude-code-builds-features-and-uses-them-immediately" forecast becomes literally true at runtime.

**Phase 1 — Apeiron-to-MCP-server adapter (next session).** Apeiron needs to call MCP tools from inside node emit() implementations. Two paths:

- *Direct import* — Apeiron imports `tools.alethea_mcp_server` and calls its Python functions directly. Tight coupling but fast. Works because both projects are checked out on the same machine.
- *MCP client over stdio/HTTP* — Apeiron starts a subprocess connection or HTTP call to the MCP server. Service-architecture-clean. Survives the MCP server moving to a different machine eventually.

Recommendation: direct import first (Phase 1a), HTTP client when the MCP server moves to web hosting per [Alethea pending #005](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/pending.md). The adapter is a single `node_types/mcp_call.py` node-type whose `emit()` calls an MCP tool by name and returns the result on a channel.

**Phase 2 — Workflow-specific node-types (incremental).** One node-type per workflow domain:

- `IdeasRoom` — wraps a search query against the Alethea corpus; renders matching nodes as 3D objects whose positions reflect semantic similarity.
- `MailRoom` — reads Gmail via an MCP tool (one that wraps the gmail API); renders threads as Portal-connected sub-rooms.
- `CalendarRoom` — reads Google Calendar; renders events along a time axis.
- `JournalRoom` — renders a chat log file as a timeline; composes with TextRenderer for entry composition.
- `CorpusBrowser` — renders the Alethea node graph as a 3D graph; click to focus, hover to preview.

Each is a single file dropping into `node_types/`. Per-room work is bounded; the unified workflow accumulates as each room lands.

**Phase 3 — End-to-end chat-driven code generation (Phase 0 + 1 dependency).** A demonstration scene where:

1. The viewer is in a room with the ChatInterface visible.
2. The viewer types a request the engine doesn't know how to handle (e.g. "make me a node-type that renders a clock").
3. ChatInterpreter classifies as novel; writes `requested: make me a node-type that renders a clock` to the chat log.
4. Claude Code (running externally on the chat log file) generates `node_types/clock.py` and writes it.
5. File-watcher picks up the new file; engine registers Clock.
6. ChatInterface displays a "clock node-type now available" message in the log.
7. Viewer types `spawn clock`; ChatInterpreter dispatches via the text-renderer; a Clock node appears in the world.

This is the load-bearing demo. If it works end-to-end without engine restart, the workflow vision is mechanically validated.

**Phase 4 — Production integration.** When the MCP server moves to HTTP hosting, the Apeiron-MCP adapter becomes a remote client. Multiple Apeiron viewers (the maintainer's desktop + headset) connect to the same MCP server. The maintainer's workflow follows them across devices.

**Phase 5 — Federation.** Other users' Apeiron instances connect to other users' MCP servers; shared node-types federated per the [federation idea](dream_features_extensions.md#b3-federated-node-types-as-first-class-import). The system the maintainer described in the 2026-05-11 transcript — improving through collective use — reaches its full architectural shape.

## What this session does NOT do

- The MCP adapter is Phase 1; this session doesn't build it.
- Workflow-specific node-types are Phase 2; this session doesn't build any.
- The end-to-end chat-driven code generation demo is Phase 3; the file-watcher this session builds is the precondition, not the demo itself.
- Production hosting is Phase 4–5; depends on Alethea pending #005.

## Open questions the next session should answer

- **Security model for autogenerated code.** Claude Code can drop arbitrary Python into `node_types/`. The engine's try/except isolation prevents crashes, but doesn't prevent malicious imports or file I/O. Acceptable in single-user mode; not acceptable when federation lands. The federation idea names "register a remote URL → mirror its node-types" — a malicious peer's node-type imports become local code. Containerization, sandboxing, or static analysis are the candidate mitigations; no decision yet.
- **State migration on reload of stateful node-types.** v1 ignores; needs design when nodes hold meaningful runtime state.
- **MCP tool call latency inside emit().** emit() runs per-frame in interactive mode. An MCP call that takes 100ms is unusable for per-frame use. The MCP adapter probably needs async or precompute integration; the Apeiron architecture's build/runtime split is the natural home.
- **What "workflow context" means spatially.** Are rooms metaphors (text-renderer's "list nodes" with a wallpaper) or full 3D environments? The dream-features dim-mode infrastructure supports either; the maintainer's preference shapes Phase 2's level of effort.

This page is a [static idea](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/static_ideas.md) — created during the workflow-feasibility session, frozen at session close.
