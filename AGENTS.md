# AGENTS.md — Apeiron

This file is the vendor-neutral agent-discoverable entry point for the Apeiron project. Any AI agent (Claude, GPT, open-source models, future agents) reads this file at the start of any session in this repo to orient itself in the project's conventions, capabilities, and current state.

This is the cross-vendor mirror of the Claude-Code-specific `CLAUDE.md` instruction file. The deep auto-load chain lives in `CLAUDE.md`; this file is the universal-agent entry point.

## What Apeiron is

Apeiron is a node-graph engine for building, rendering, and inhabiting worlds. Every world-object, every renderer, every aggregation rule, every text-interaction surface is a node. The graph is the medium; renderers are nodes that turn the graph into output (visual, textual, or compositional); aggregation nodes turn fine-scale structure into coarse-scale emergent behavior.

Apeiron:

- Stores node-type implementations as one file per type under `node_types/`
- Stores renderer implementations as one file per type under `renderers/`
- Stores scene data as JSON under `scenes/`
- Produces image bundles (`color.png`, `depth.png`, optional `normal.png`, optional `ids.png`, `manifest.json`) that feed the downstream painterly module engine
- Exposes a text-renderer surface so LLM agents can interact with worlds as fully as a human could
- Composes with sibling projects in the network (Alethea, Resonance Website, Resonance Hub, the meta-layer at Resonance/)

Working name **Apeiron** is a placeholder — better-name suggestions go in `name_suggestions.md`.

## Network map (sibling projects this agent may need to touch)

| Project | Local path | GitHub remote | Role |
|---------|-----------|---------------|------|
| **Apeiron** (this repo) | `C:/Users/Liam/Desktop/Apeiron/` | github.com/liamhodgsonhollingsworth/Apeiron | Node-graph engine; multi-renderer substrate |
| **Alethea** | `C:/Users/Liam/Desktop/Alethea/` | github.com/liamhodgsonhollingsworth/Alethea | Portfolio root; session-types + skills + corpus |
| **Resonance Wavefront (meta-layer)** | `C:/Users/Liam/Desktop/Resonance/` | github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront | Conventions + ideas graph |
| **Resonance Website** | `C:/Users/Liam/Desktop/Resonance-Website/` | github.com/liamhodgsonhollingsworth/Resonance-Website | Immersive science-fiction website |
| **Resonance Hub** | `C:/Users/Liam/Desktop/Resonance-Hub/` | github.com/liamhodgsonhollingsworth/Resonance-Hub | Open-edit collaborator entry point |
| **conversation-bridge** | — | github.com/liamhodgsonhollingsworth/conversation-bridge | Chrome extension + FastAPI for cross-surface comms |

## Where to find what

| Looking for... | Read... |
|----------------|---------|
| Current state of every node-type, renderer, engine module | `whats_built.md` |
| Load-bearing design commitments | `architecture.md` |
| Chronological index of prior sessions | `session_types/handoff.md` |
| Items deferred for future sessions or maintainer | `pending.md` |
| Feature requests + name-suggestion queue | `wishlist.md` + `name_suggestions.md` |
| Node-type implementations | `node_types/<type>.py` |
| Renderer implementations | `renderers/<renderer>.py` |
| Scene data graphs | `scenes/<scene>.json` |
| Engine core | `engine/` |
| Bundle output examples | `output/` |
| Operational discipline (response shape, communication conventions) | `https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/discipline.md` |

## What conventions every agent inherits

- **Append-only invariant + per-edit-creates-new-node extension**: this repository is write-only. A new version of a node-type is a new file alongside the old, not a destructive overwrite. The engine's manifest-versioning machinery resolves which version is active per scene. Old versions stay reachable; reverting is automatic for any scene referencing an older version.
- **Modules-as-nodes**: every node-type is one file under `node_types/`. Engine discovery walks the directory at startup. A broken node-type only breaks itself; the rest of the engine keeps running per the try/except isolation in the engine core.
- **Channels-by-name wires**: renderers and node-types communicate via named channels (`color`, `depth`, `normal`, `ids`, `text`, custom). New channels can be added without breaking existing consumers; consumers read what they know about and ignore the rest.
- **Manifest contract**: every bundle output carries `manifest.json` enumerating channels + camera + scene metadata. The painterly module engine downstream relies on this contract.
- **Per-session branches + per-session attribution**: each session works on `claude/<topic>-<slug>` or `feature/<topic>` and sets `git user.name`/`user.email` locally before its first commit per the meta-layer's [session_naming](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/session_naming.md).
- **Node-grain claims**: concurrent sessions claim node-types or renderer-modules before substantive work via Alethea's `claim-node-scope` skill; the cross-repo inbox lives at `Alethea-cc/nodes/inbox_msg_*.md`.
- **CODEOWNERS gating**: Atlas-linked paths (README Atlas links, `architecture.md`) are maintainer-edited only; non-Atlas paths are editable by any session.
- **GitHub operations are session-handled**: agents do their own `gh` operations (PR creation, merge, branch delete). Maintainer takes zero github actions.

## Bundle contract with the painterly module engine

Apeiron's software-raster renderer outputs a bundle directory matching the painterly module engine's input contract:

- `color.png` — RGB or RGBA raster
- `depth.png` — single-channel depth, normalized
- `normal.png` — optional, three-channel normal in tangent space
- `ids.png` — optional, single-channel segmentation IDs
- `manifest.json` — channel index plus camera and scene metadata

Additional channels can be added by name without breaking consumers.

## Text-renderer surface

The `TextRenderer` node-type is the first-class bidirectional LLM-facing surface. It walks its wrapped sub-graph and produces structured text output (view state, scene topology, observations, command grammar) via the `text` channel. The CLI at `python -m tools.text_test` provides `describe_scene`, `describe_view`, `summarize_bundle`, `dispatch_command`, `assert_visible` — the LLM-facing verification surface. Once visuals are confirmed, new features can be built and verified through these tools alone.

The `ChatInterface` node-type owns a screen rectangle in the outer world and renders the contents of a chat log file. The side channel to the LLM is the file itself, so the system contains the authoring tool as a node inside the system being authored.

## How to contribute as an agent

1. **Read `README.md`** for the framing + Atlas
2. **Read `architecture.md`** for the load-bearing design commitments
3. **Read `whats_built.md`** for the current implementation surface
4. **Read the latest entry in `session_types/handoff.md`** for prior-session context
5. **Set git user.name/email locally** per the session-naming convention
6. **Claim your node-grain scope** if working on a node-type or renderer
7. **Author your work** as new files (or new versions of existing files) under `node_types/`, `renderers/`, `scenes/`, etc.
8. **Commit + push + merge** via `gh` (sessions are full github actors)
9. **Close with the discipline-compliant response shape** (see the meta-layer's discipline conventions URL above)

## When you can't tell whether to act or ask

- **Reversible + derivable from existing conventions/architecture/whats_built**: act
- **Irreversible OR multi-option judgment call**: file in `pending.md`
- **Maintainer-edited path (Atlas, architecture.md)**: open PR rather than direct edit; tag for review

## License

[O'Saasy License](LICENSE) — MIT with an anti-competing-SaaS clause. Self-host, modify, fork, redistribute remain free.

## Open questions agents may need to surface

- The painterly module engine downstream of Apeiron's bundles is documented in the meta-layer (`ideas/painterly_module_engine.md`) but not yet implemented; the bundle contract is forward-defined to its input requirements
- The Resonance Hub repo is listed in the projects atlas but does not exist on disk as of 2026-05-28; treat as aspirational until created
- The OpenGL + browser renderers are scoped in `whats_built.md` but not yet implemented

This file is an evolving idea; agents that find gaps should propose extensions via PRs.
