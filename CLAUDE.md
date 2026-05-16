# Apeiron — orientation for Claude Code sessions

You are in the Apeiron project repository, part of the [Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront) network. Apeiron is a node-graph engine for building, rendering, and inhabiting worlds — every world-object, every renderer, every aggregation rule, every text-interaction surface is a node. Produces bundles for the painterly module engine downstream and exposes a text-renderer so Claude Code can use the world fully.

Read this file as the entry point. The README has the full framing.

## Auto-load at session start

At session start, after reading this CLAUDE.md, also read:

1. `README.md` — this project's framing and Atlas.
2. `architecture.md` — the load-bearing design commitments. Read this before touching engine or node-type code.
3. `whats_built.md` — current state of what is and is not implemented.
4. The meta-layer's atlas at `https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/README.md` — the network's index of indexes.
5. The meta-layer's operational discipline at `https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/discipline.md` — network-wide rules for response shape, communication, closing-block format, archive process, github URL links, and auto-push.

(Additional orientation pages are added as the project develops.)

## Append-only invariant

This repository is write-only. Beyond the standard append-only rule, Apeiron carries the per-edit-creates-new-node extension where it applies to node-type and renderer definitions: a new version of a node-type is a new file alongside the old, not a destructive overwrite. The engine's manifest-versioning machinery resolves which version is active per scene. Old versions stay reachable, and reverting is automatic for any scene referencing an older version.

## Identifying yourself

Set git user.name and user.email locally in this repo:

    git config user.name "your-session-name"
    git config user.email "your-session-name@resonance.local"

The session-naming convention is documented in [the meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/session_naming.md).

## Edit permissions

The README's Atlas links and `architecture.md` are maintainer-edited only. Non-Atlas pages — node-type implementations, renderer implementations, scene data, engine internals, tooling — are editable directly by subagents and independent sessions, per the standard branch-protection setup. See [the meta-layer's edit-permissions convention](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/edit_permissions.md) for the full rule.

## Parallel-implementation pattern

Many sessions and subagents may work on Apeiron concurrently. The pattern:

- **Per-session branches** — each session works on a feature branch named `claude/<topic>-<slug>`; merges to main on session close or claim release.
- **Per-session attribution** — each session sets `git user.name`/`user.email` locally in this repo before its first commit.
- **Auto-push** — sessions commit and push without waiting for explicit instruction, per the meta-layer's [auto-push convention](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/discipline.md#pushing-to-github-happens-automatically).
- **Node-grain claims** — concurrent sessions claim node-types or renderer-modules before substantive work via the [claim-node-scope skill](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/skills/claim-node-scope.md); inbox messages live at `Alethea-cc/nodes/inbox_msg_*.md` in the Alethea project (cross-repo inbox).
- **Worktrees for same-machine concurrency** — sessions on one machine use `git worktree add` so they don't step on each other's branch state.
- **CODEOWNERS gating** — Atlas-linked paths require maintainer review; non-Atlas paths can be merged by any session.

The modules-as-nodes commitment makes this work: different sessions edit different files, so git's three-way merge only fires on cross-touching indexes. A broken node-type only breaks itself; the rest of the engine keeps running per the try/except isolation in the engine core.

## Bundle contract with the painterly module engine

Apeiron's software-raster renderer outputs a bundle directory matching the painterly module engine's input contract:

- `color.png` — RGB or RGBA raster
- `depth.png` — single-channel depth, normalized
- `normal.png` — optional, three-channel normal in tangent space
- `ids.png` — optional, single-channel segmentation IDs
- `manifest.json` — channel index plus camera and scene metadata

Additional channels can be added by name without breaking consumers; the painterly engine reads the channels it knows about and ignores the rest.

## Master documents

Every session and every subagent operating here owns at least one primary document tracking its work. The convention is at [the meta-layer's primary-documents page](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront/blob/main/conventions/primary_documents.md).
