# Apeiron node-substrate bootstrap — session handoff (rev 2)

This document supersedes any earlier handoff. Read it fully before any code. Do not summarize it back unless asked.

## Section 0 — Orientation, before any code

You are picking up a system mid-design. The architecture is partially specified across multiple repos; the prose conventions are further along than the code. Your first job is consolidation, not invention.

1. Read, in order: this document fully; the Apeiron repo's `architecture.md` and `whats_built.md`; the meta-layer repo's `README.md`, `CLAUDE.md`, `conventions/discipline.md`, `conventions/evolving_documents.md`, `conventions/idea_evaluation.md`, `meta_conventions/append_only.md`; the meta-layer's `ideas/apeiron.md`, `ideas/everything_is_a_node.md`, `ideas/halo_sage_mycelia.md`, `ideas/self_designing_system.md`; the Alethea repo's `whats_built.md` and the current MCP server entry point.

2. Produce a node titled "what I understand this system to be." Summarize the architectural commitments already present in the repos and the gaps between current state and the spec below. This is the alignment artifact. The maintainer reviews it. Do not proceed past this point without confirmation.

3. Produce a `tool-consideration node` listing every tool you have available — Anthropic-provided, MCP-server-exposed, filesystem, Claude Code slash commands, web search, image search, document creation, every connector accessible via `tool_search`. Keep listing until you cannot list any new ones. For each, a one-line note on whether it is relevant to this work. Reinventing capabilities that already exist is the most common silent failure in sessions on this project; this node is the primary defense against it. Update this node whenever you discover a tool you missed.

4. Produce a `prior-work node` with two sections. Internal: search the meta-layer corpus, the Alethea corpus, past session archives, by node ID and by schema, for work related to what you are about to do. External: web search for existing implementations of the patterns this system uses. Named entry points so you do not have to start cold: Unison (content-addressed code), IPFS and multihash (content-addressed storage with hash-function evolution), Smalltalk metaclass hierarchy (self-referential type systems), Erlang/OTP (actor isolation, hot code loading, supervision trees), Pure Data, Max/MSP, Houdini (node-graph programming in production), Nix and NixOS (content-addressed system state), Cap'n Proto and the object-capability literature (capability-based security with delegation), the MCP specification at modelcontextprotocol.io, CRDT literature (monotonic distributed state), Racket's `#lang` mechanism (multi-language composition over a shared meta-protocol). Cite at least one in any design node you produce afterward.

5. Retrieve, before starting any non-trivial task, the tool-consideration nodes and prior-work nodes produced by previous sessions on related work. Even naive keyword search across the corpus is acceptable for the bootstrap. You are required to either use the tools suggested by those nodes or write a justification node explaining why not. "Ignored available tools without justification" is a surfaceable event, not a silent loss.

6. Read this section again before proceeding to Section I.

## Section I — The meta-discipline that shapes every move

This section is normative. Every numbered item is a rule you operate under. Violations are recorded as nodes naming the violation, not hidden.

7. Everything is already a node. The infrastructure does not *make* artifacts into nodes; it treats them as the nodes they already are. A markdown file is already a node: content, identity via content hash, provenance via git, connections via links. A code file, a PDF, an image, a conversation transcript, a calendar entry — same. The system's work is providing wrappers (themselves nodes) that expose each artifact's node-properties uniformly to the rest of the system. For artifact types with no existing wrapper, write an *interpreter node* describing how to read that artifact-type as a node; future sessions inherit the interpreter as soon as it is published. Adding new file-type support is "add a node," not "modify the system."

8. Fixed-point self-reference, not external authority. There is no specification outside the node graph governing it. The bootstrap contract is itself a node and is a working instance of what it specifies. Some node, evaluated by the protocol, returns itself. That closes the regress. The protocol does not appeal to anything external.

9. Identity is content-addressed and unforgeable; names are local and mutable. Every node has an ID derived from a multihash of its normalized content (start with sha256: prefix, leave room for blake3 and successors). Aliases live in a separate naming layer and are mutable. Sessions never have to deal with hashes directly — the `find` primitive resolves any of {ID, alias, content fragment, schema match, connection pattern} to the full node record.

10. Monotonic accumulation, append-only, supersession-as-the-only-change-mechanism. A published node is reachable forever by its hash. Editing means publishing a new version under a new hash with an explicit supersedes link. Rollback is itself an append. Nothing is ever truly deleted. This is the prose-side discipline applied to code.

11. Load-bearing minimization. Whenever a piece of work seems necessary for many other pieces, decompose. The architectural goal is that no single node is load-bearing — the load is distributed across the graph. When you are forced to redo previous work, that signals what was redone was load-bearing in a way the system does not want; record a "what was load-bearing here" analysis as a node alongside the redo.

12. Redoing is a learning moment, distinct from failing fast. Cheap experiments — try, see if it works, supersede — are normal and recorded as ordinary supersession. Forced redoing — earlier work was wrong in a way that propagated — is recorded as a node *and* triggers a load-bearing analysis. Conflating the two loses information. From this point in the project forward, no work should ever be redone unless treated as a learning moment.

13. The unifying coding principle. If you can imagine a situation where another program would need to write an isomorphism of this behavior using different methods, write it in a more general way and abstract the specific behavior into specific nodes. Apply recursively. Generalization is the default; specialization is justified explicitly.

14. Subagents are the primary coding agents. Higher-level sessions focus on composite behavior between nodes — wiring, coordination, the nodes that determine how other nodes compose — not on writing specific implementation nodes. Implementation work delegates downward; architectural and compositional work stays at the higher level. The higher you sit in the session hierarchy, the more your output is wiring rather than building blocks.

15. Disagreement protocol. When the spec conflicts with itself, with existing repo material, or with implementation reality, write a disagreement node naming the conflict and ask the maintainer. Pause the thread until resolved. Do not proceed by silent interpretation. The maintainer's resolution is itself a node and supersedes the conflict. Disagreements already covered by the spec do not require escalation.

16. Stopping conditions. Every session has explicit or implicit stopping conditions. If none is given, ask before starting. Common conditions: acceptance test passes; checkpoint reveals monotonicity violation that cannot be quickly fixed; fixed time budget elapsed; session notices it has lost the thread.

17. Every tool call is a polling opportunity for the inbox. Wrap your tool-call layer so that on every call, if there is a pending message in the session inbox, it is injected alongside the result. This is the out-of-band signaling mechanism that makes live coordination work without true streaming.

18. Live editability. Automation is node-composition; an automated workflow is a node graph that can be paused, modified, and resumed by editing the wiring. No compile step, no opaque blobs, no closed-source executables in the substrate. Automation that loses live-editability is rejected.

## Section II — The bootstrap, in build order

Items 19 through 24 are built before the chess test in Section III. Build them in order. Building chess before these four exist degrades every-output-is-a-node into "I wrote some markdown" within an hour.

19. The fixed-point node. First implementation task. A node whose contract is itself: when evaluated by the protocol, it returns itself; when introspected, it produces the schema all nodes including itself obey. Multihash-prefixed ID. Diagnostic: applying the node to itself returns the node. If this round-trips, the bootstrap is real.

20. The toolbox-as-node and the primitives over toolboxes. A toolbox is a node listing tool-node hashes a session has access to. Primitives include: adding a tool to a toolbox, removing one, querying what's in it, granting a subset to a subagent, merging toolboxes, publishing a toolbox at session-end so the next session can retrieve it. Sessions start by retrieving the maintainer-provided starting toolbox; tools authored mid-session land in the session's toolbox automatically; the published toolbox is reviewed alongside the rest of the work. This makes "tools accumulate across sessions" structural rather than aspirational.

21. The minimal evolving primitive set. The complete set of meta-actions every other node decomposes into. There is no fixed cardinality. The initial set, for you to validate and extend: `publish` (commit a node), `find` (retrieve by ID, alias, content, schema, or connection), `compose` (wire nodes into a new node), `execute` (run a node with typed input), `describe` (return schema and provenance), `supersede` (publish a new version with explicit lineage), plus the toolbox primitives from item 20, plus whatever else you find you need. Each primitive is itself a node obeying the fixed-point contract. The criterion for what counts as a primitive over time, applied as a soft rule now and automated later: a tool is a primitive if it has been used in every (or almost every) session since its creation. Tools that fail this criterion get reframed as compositions of more fundamental tools. The primitive set sorts itself out through use, not through up-front design.

22. The MCP server is itself node-composed. The server's tool registry is a node. Tool implementations are nodes. The server is a thin interpreter over the registry. Changing the tool list updates the registry node. The server watches the registry node and reloads affected tools live. This is hot-code-loading applied to MCP and is what makes the rest of the everything-evolves property work for sessions consuming the server.

23. Wrap-existing-artifacts-as-nodes pipeline. Per item 7, artifacts are already nodes; the pipeline exposes them as such. The first wrapper handles markdown files in a designated directory: hashed on save, schema inferred from frontmatter, provenance recorded from git. The second wrapper handles Python source files. Add interpreter-nodes for other artifact types as they come up; do not pre-build interpreters for types no session needs yet.

24. Wrap one existing Alethea tool. `alethea:read` is the recommended candidate: simplest, most-used. The wrapped tool is itself a node with hash, schema, and provenance. This proves the wrapping pattern works and establishes the template for the continuous tool-wrapping discipline in Section IV.

25. The first benchmark: the auto-supersession-following tool. Build a tool that, given a node and a child node it points to, produces a new node identical to the original but with the connection updated to point to a successor of the child (auto-following supersedes chains). Optionally recursive across all descendants. This is the canonical "make a tool instead of redoing manual work" task. The benchmark is whether the session makes this tool, iterates on it, *publishes it to the toolbox*, and remembers to use it rather than defaulting to manual rewiring later. Forgetting it exists is the failure mode this benchmark detects.

## Section III — The acceptance test and iterative generalization

This section is what proves the bootstrap holds. It runs as a sequence of escalating tests; passing each stage gates the next.

26. Initial chess test. Build a chess implementation with three piece types (king, rook, pawn), a 4×4 board, and the composition structure: piece-node → shape, piece-node → moves; moves composed from possible-moves, which composes board-traversal, which composes board-geometry; rules-node connecting back to pieces. Everything as nodes. Hot-swap the rook for a queen by publishing a new piece-node, without losing the rest of the system. A fresh session, given only the board state node by hash, must extend the system with a new piece.

27. First generalization test, hidden from implementers. After the chess test passes, the maintainer (or an isolated LLM call) generates five entirely new piece types with novel movement rules and interactions. These are handed to the system as new nodes. The system must compose them with the existing board and rules. *The subagents that built the chess implementation must not be told this is the evaluation criterion in advance.* This is the held-out test that measures actual generalization rather than test-passing.

28. Iterative generalization. After the first generalization test, the session works on accommodating the AI-generated pieces. If any existing nodes had to be rewritten (rather than only new nodes added), record those as load-bearing analyses per item 11. Then a *second* generalization test: a random AI-generated change to the game itself — different board shape, different turn structure, different win condition, whatever the random generator produces. The system must accommodate the change. If existing nodes were rewritten, record and proceed. Repeat until a generalization test passes with *zero rewrites, only additions*. That is the operational definition of the system having reached its monotonic-accumulation property for this domain.

29. Each iteration of item 28 is itself a node. The full sequence — initial chess, first test, accommodation work, second test, accommodation work, and so on until convergence — is a chain of nodes telling the story of how the architecture stabilized.

## Section IV — Continuous practices

30. Subagents are fully capable actors, not stateless reducers. Subagents have access to the same memory tools, file operations, and MCP servers the main session has. Pass node hashes, not embedded content; the subagent looks up what it needs. This preserves context budget across nesting depth and is what the toolbox primitives in item 20 enable.

31. Subagents are used for all testing. Testing is a separate workstream parallel to implementation. Subagent-driven testing improves over time as the testing patterns themselves become reusable nodes.

32. Toolbox capabilities with provenance. A subagent receives a toolbox node listing tool hashes it has been granted. The subagent can create new tools, returning them as new nodes the parent can review. Provenance is recorded for every tool: creator, grantor, users. No restrictions on creation; complete audit trail on lineage. Creation is free; fabrication is impossible because lineage is verifiable.

33. Required vs. situational tool use. Required (unprompted, whenever applicable): subagent spawning, file persistence, MCP communication, content-addressed storage operations, search across past sessions, toolbox operations. Situational (used when the work calls for them): web search, image search, document creation. You are not graded on tool-use breadth.

34. Research before implementation, symmetric. Before any non-trivial work, search internally (past sessions, corpus, node IDs by schema) and externally (web search, named existing implementations). Both go in the prior-work node. "I looked and there is nothing" is an acceptable entry; not searching is not. Internal search includes retrieving prior tool-consideration and prior-work nodes per item 5.

35. Tool-consideration discipline, automated as it stabilizes. Before any non-trivial work, update or produce a tool-consideration node listing every available tool and whether it applies. As patterns emerge across sessions, the matching logic gets smarter — semantic search across past tool-consideration nodes, learned patterns over which tools fit which work-types. The bootstrap version is naive retrieval plus required acknowledgment; the eventual version is automated suggestion. Sessions producing useful tool-consideration nodes should also produce *self-suggestion nodes* — explicit notes-to-future-sessions about what they wish they had known at the start, which the suggestion logic can surface to those future sessions.

36. Tool-list pruning is continuous. The current Alethea tool list is accumulated bloat. As primitives stabilize per item 21, existing tools are reframed as process-nodes built from primitives. The goal is a small primitive set and a large composable library, not a large primitive set.

37. Generalization-first writing. When implementing, write the general form by default and specialize only with explicit reason. If a function takes a board, a piece, and a move, but the underlying logic does not depend on it being chess, the function takes a graph, a node, and an operation, and chess is a specialization composed on top. Apply recursively.

38. Hierarchy of work. Per item 14, subagents do implementation and the parent session does composition. The parent session's outputs are predominantly wiring-nodes: nodes that compose other nodes into larger structures, nodes that determine how groups of nodes interact, nodes that govern other nodes' behavior. Implementation-shaped output from a high-level session is a signal that work has not been delegated correctly.

## Section V — Safeguards and checkpoints

39. Checkpoint cadence. Every hour or every 20 nodes (whichever comes first), the session writes a checkpoint node: what was published since the last checkpoint, what was superseded, whether monotonicity was preserved, what is queued, what tools were used, what was considered and rejected, the current state of the toolbox. The checkpoint is itself a node.

40. Fresh-session test cadence. Once per session day (or every 50 nodes), spawn a fresh Claude Code session with no context, give it only the bootstrap node hash and a starting toolbox, and ask it to retrieve and extend an arbitrary published node. Result becomes a node. This is how the success metric is actually measured.

41. Bootstrap-phase redo budget. The first 20 published nodes are explicitly allowed to be redone as the protocol stabilizes; redos in this phase are noted as nodes but not treated as failures. After node 20, redos become rare and require an explicit reason-node and a load-bearing analysis per item 11.

42. Disagreement nodes are first-class. Any conflict between spec, repo, and implementation surfaces as a disagreement node and pauses the affected thread until the maintainer resolves.

43. The success metric, singular. The number of nodes a fresh session can pick up by hash and successfully extend, plus the result of the iterative generalization sequence in item 28 — specifically, whether the sequence converges to a state where new domain changes require only new nodes, not rewrites. Everything else is vanity.

## Section VI — After the bootstrap holds

44. Continuous tool-wrapping. Convert remaining existing tools to node form, one at a time, in priority order of which the maintainer uses most. This is not a sprint; it is the rest-of-life workstream.

45. Interpreter nodes for new artifact types. As new artifact types come up (PDFs, calendar entries, browser tabs, code in unfamiliar languages), write an interpreter node per item 7. Each new interpreter expands the system's reach without modifying the substrate.

46. Protocol iteration. The protocol is a node and can be superseded. New protocol versions are new nodes with translator-nodes connecting them to old ones. Old nodes continue working under the old protocol. Migration is voluntary, gradual, and recorded. Bootstrap-version changes (the multihash format, the primitive set itself) are once-in-a-generation civilizational events with explicit translation across versions.

47. Protocol-evolution queue. Maintain a node listing things that came up during work that the current protocol could not express cleanly. The maintainer reviews periodically. New translators get added; new protocol versions get drafted when warranted.

48. Live communication via inbox-polling-on-tool-call (item 17) extends naturally to coordinator-and-worker patterns. Build coordination patterns as nodes that compose the inbox mechanism with the existing subagent spawning.

## Section VII — The long arc

49. The Apeiron substrate is one possible Aperture (one instantiation) of the HALO/SAGE/Mycelia architecture. The bootstrap above is sized for one machine and one maintainer; the architecture is sized for distributed self-improving systems across many machines and many participants. The Merkle-synchronization pattern in the protocol (content-addressed IDs, hash-based deduplication, transmission-of-diff-only) is what lets it scale across machines without coordination. Building the local version honestly is what produces the property at distributed scale; cutting corners now removes options later.

50. The asymmetry between code and prose is the historical accident this work corrects. Prose accumulates with citation and supersession; code mutates and rewrites. The discipline you operate under is the prose discipline applied to executable substrate. If the discipline holds, code becomes citable, traceable, supersedable, accumulating. The substrate change is the bet.

51. The session producing the next handoff document is operating under the same discipline as the session receiving it. This document was produced by push-concede-refine, by fixed-point recognition, by disagreement-as-node, by content-addressing of decisions. The session reading this should look for the same moves in itself. Sessions becoming instances of what they describe is one of the project's recurring structural features; this document is one of them.

End of handoff. Begin at Section 0.
