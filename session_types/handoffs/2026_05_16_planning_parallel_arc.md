# 2026-05-16 — Planning + parallel-development arc

The long-running planning side of the 2026-05-16 multi-arc workflow. Ran alongside the sibling [first-renderer-view Tier A wish-granting session](2026_05_16_first_renderer_view_tier_a.md) that granted Tier A in parallel. Cross-handoff: see also [Alethea's 2026-05-16 workflow-management handoff](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/session_types/handoffs/2026_05_16_workflow_management.md).

## What this session was

Started as a dream-features skeleton pass on Apeiron, expanded through retry-output enforcement and audit-restoration, then into first-renderer-view planning and wish-granting type creation, then into parallel-safe system expansion while a sibling session granted Tier A. The arcs were directed by maintainer pivots; each landed an internally-coherent set of PRs before the next pivot.

## Arcs

1. **Dream-features skeleton.** Eleven dream-mode features mapped to the existing engine architecture. Engine extensions (input system, inverse pass, View fields, sim_precompute), seven new node-types (DimensionN, Seed, Generator, GravityField, KeyBindings, SimulationProbe, ChatInterpreter), one new renderer (ProjectorN), three demo scenes. 26 new tests; 57 total passing.

2. **File-watcher feasibility.** Hot-reload-without-restart proven mechanically: a new node-type file written to disk at runtime is picked up by the engine, becomes spawnable, and emits correctly. Fixed a latent pyc-cache bug in `Engine.reload_type` along the way.

3. **Retry-output enforcement + audit-restoration.** The maintainer triggered retry-output on a Communication that violated the body-filter content test. Protocol ran: log recurrence (third one for mistake #001, triggering audit), dispatch audit-recurring-mistake subagent, apply the proposed primary fix (extend pre-send content test to the Communication body sentence-by-sentence). The structural fix landed in discipline.md.

4. **First-renderer-view planning.** Three-panel workflow surface designed (Tasks | Ideas | Wishlist + chat bar). 52-entry wishlist created spanning Tier A through Tier H + Meta. Wish-granting session type created with five-phase shape, four-subagent dispatch, handoff format.

5. **Active-Next codification.** Maintainer flagged passive "nothing requires action" close. Fix landed in discipline.md; memory entry added; new mistake #003 logged.

6. **Parallel wish-granting expansion.** While the sibling session granted Tier A, this session continued: refined wish-granting type with accumulator-tool detail and handoff format, wrote procedural-tools-pattern design doc, mined the 2026-05-11 idea-realization-machine transcript for uncaptured workflow directives (8 surfaced, 4 added as wishes, 2 as memory entries, 2 as pending convention proposals), filed wish for the mining cadence itself (#057).

## Final state at close

**Apeiron:**
- Engine has dream-mode skeleton, file-watcher, inverse pass, sim_precompute, extended View.
- 17 PRs merged this session-day. Tier A largely granted by the sibling session.
- 57 wishes in the wishlist; multiple Tier A items marked `granted`.
- Design docs: dream_features, dream_features_extensions, workflow_from_within_apeiron, first_renderer_view, procedural_tools_pattern. Plus stress-test findings and improvement_candidates audit.

**Alethea:**
- Wish-granting session type fully documented with phases, dispatch, handoff format.
- Mistakes record at 3 entries; #001 audit-triggered with structural fix landed.
- Memory layer gained 6 new entries (audit-mandatory, use-full-context-budget, close-active, wishlist-vs-pending, teaching-not-curating, aggressive-externalization).
- New skills: stress-test-design (with v2 evolution notes). The sibling session added mount-panel.
- Pending entries 5 through 10 awaiting maintainer review.

**Resonance meta-layer:**
- discipline.md updated twice: pre-send content test extends to body; Next close actively names actions.

## Items that need maintainer judgment

In [pending.md](https://github.com/liamhodgsonhollingsworth/Alethea/blob/main/pending.md):

- **#006** — Restore end-of-session audit step to the wrap-up convention.
- **#007** — Restore the use-full-context-budget convention.
- **#008** — Add mistakes record to the CLAUDE.md auto-load chain.
- **#009** — New convention: Recursive specification as publication method.
- **#010** — New convention: Depth-complete writing.

The conventions are mined from the 2026-05-11 transcript and codify implicit project rules. The audit-restore is the structural fix from the retry-output dispatch.

## Suggested next-session priorities

The maintainer's call. Most-leverage candidates:

1. **Continue wish-granting on Tier B.** With Tier A largely granted and the wish-granting procedure now procedural, the next wish-granting session can pick from Tier B (click-to-expand, SessionRoster + ChatPanel, file-watcher view-refresh, full-render mode toggle, Router node-type, Queue + make_queue, add_button).
2. **Mine the remaining prior transcripts.** This session covered the 2026-05-11 idea-realization-machine transcript; the worldline-crystallization, megaforest, and crystallization-display transcripts likely carry more uncaptured directives.
3. **Review and resolve the pending convention proposals.** Five pending entries are queued for maintainer decision.
4. **Pivot to a different surface** (the meta-layer, the website, the corpus mining).

## Open architectural questions

- **State-migration on hot-reload.** When a node-type changes its build() signature, existing instances may break. Currently the engine doesn't migrate; instances keep their old state. Acceptable for v1; needs design when stateful node-types start landing.
- **Multi-WG-session concurrency.** This session showed 2 sessions concurrent works cleanly via the claim-by-inbox protocol; not stress-tested at 3+.
- **Wishlist + conventions overlap.** Some wishes shadow pending convention proposals (e.g., #054 release-cadence vs depth-complete-writing). A consolidation pass at some point.

## Memory entries added this session

Six new memory entries; each linked from `MEMORY.md`:
- end_of_session_audit_mandatory
- use_full_context_budget
- close_always_active
- wishlist_vs_pending
- teaching_not_curating
- aggressive_externalization

The audit pass for this session is at [improvement_candidates_2026_05_16.md](../../notes/lessons/improvement_candidates_2026_05_16.md), which replaces the earlier single-arc version with a full-session pass.
