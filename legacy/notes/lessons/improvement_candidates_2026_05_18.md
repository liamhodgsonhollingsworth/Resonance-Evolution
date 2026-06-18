# Improvement candidates — 2026-05-18 (wish #006 action primitive)

End-of-session audit for the wish-granting session that granted Apeiron wish #006 (click-to-expand) by shipping the per-item action primitive. Ran in the affectionate-leakey-d4c0b1 Alethea worktree, with code lands in the Apeiron repo on branch `claude/wish-006-action-primitive`. Auto-mode active throughout. Both PRs (Apeiron #21, Alethea #12) merged before this audit.

## Walk 1 — Arcs of this session

The session followed the wish-granting session-type's five-phase shape cleanly.

**Worked:**

- **Parallel subagent dispatch in Phase 2.** Four subagents (enumerate / stress-test / generalize / feasibility) ran concurrently against the same wish + framing. The four reports converged enough to make the integration decision unambiguous (Candidate B with three stress-test mitigations). Wall-clock cost of the parallel dispatch was ~2 minutes; the comparative serial cost would have been substantially higher.
- **Pre-naming two stress-test candidates was a useful concrete target.** Both A (engine-cache view-state) and B (per-item actions + dispatch) got stress-tested rigorously. The comparison surfaced specifics — B's ~1.6x LOC premium pays back within 2-3 future wishes, A's per-action duplication compounds — that the enumeration alone would not have made vivid.
- **Defensive emit + stale-id mitigation.** The score-25 stress-test vulnerability (stale item-ids after source-file edits) was addressed in v1 by a 3-line defensive read in `_read_expanded_item` rather than punting the whole content-hash-ids refactor. Parser-level fix filed as #059.
- **Fresh-subagent verification surfaced two real CLI gaps.** The subagent ran the feature end-to-end via the text-API alone and reported (1) no within-invocation state observation and (2) verbs are only discoverable through error messages. Both filed as #060 and #061. Would not have noticed these alone — bias toward the API I'd just built.
- **CLI precompute bug fixed inline.** The text_test CLI didn't run `engine.precompute()` after `load_scene`, so describe / view / command subcommands all showed empty panels. Surfaced while exercising the new verbs manually; 5-line fix shipped same session.

**Didn't work as well / would do differently:**

- **Could have read load-bearing files before dispatching.** I dispatched the four subagents before reading `list_renderer.py` and `engine/core.py` myself. The subagents read them all and produced overlapping context. Reading first and giving the subagents tighter framing might have produced more pointed reports for the same wall-clock cost.
- **Stale-id is a parser-level invariant, not a #006 issue.** The defensive emit ships in v1 but the root cause is a parser convention. A meta-skill that audits parser invariants before any panel-touching wish-grant would catch this proactively rather than reactively.
- **Wishlist has a duplicate #057.** Two entries share the number (Tier R refactor + periodic-mining-cadence). Pre-existing technical debt from the prior session. Noticed during my wishlist update but not fixed — out of session scope and would have churned the wishlist mid-flow.
- **Initial subagent dispatch prompts were verbose.** Each prompt included full file lists and framing duplicate to what other prompts included. Could have factored a shared-context-block.

## Walk 2 — Live-trial rules

No mid-session maintainer corrections in this auto-mode run. No live trials to solidify or codify.

The convention from the prior session ("audit's required output is an edit to the session-type document") applies. Candidate edits to `session_types/wish_granting.md`:

- The Phase 2 dispatch's "pre-name two candidates" pattern worked well enough that the doc could surface it more strongly. Today it says "with the dispatching session naming the two when dispatching"; making this a procedural step rather than a parenthetical clause would be a small clarity win.
- The Phase 4 fresh-subagent verification produced specific CLI gap reports. The doc could call out that the fresh-subagent's report is a high-quality source of CLI/text-API ergonomic gaps, not just functional verification. Today the doc treats it as a yes/no test.

Both are minor procedural sharpenings. Filed at the bottom of this document; will land as a small wish_granting.md commit alongside this audit.

## Walk 3 — Artifacts produced

**Permanent:**
- `engine/actions.py` — dispatch_action free function + reserved cache key + get_view_state helper.
- `node_types/list_renderer.py` — handle_action hook + defensive emit + expanded render path.
- `node_types/parsers/*.py` — actions field via attach_default_actions helper.
- `tools/text_test.py` — invoke/expand/collapse handlers + CLI precompute fix.
- `renderers/text.py` — command_grammar updated.
- `architecture.md` — actions section added.
- `wishlist.md` — #006 granted + Granted-section entry + #015 note + #059/#060/#061 filed.
- `session_types/handoffs/2026_05_18_wish_006_action_primitive.md` — handoff.
- `tests/test_actions.py` (new, 13 tests) + `tests/test_workflow_view.py` (extended, 8 new tests). 27 new tests total; 111 passing.
- Alethea `skills/add-panel-action.md` + catalog entry + handoff index entry.

**Notes / speculative:**
- The OverlayHost / selection-channel framing from the generalization subagent is recorded in the handoff's "Open architectural questions" section. Not implemented; future wishes may re-surface it.
- This session's primary doc (`notes/wish_granting_006_action_primitive.md`) is kept for traceability. Useful as a worked example of the five-phase flow with a real four-subagent dispatch.

## Walk 4 — Session's own outputs

**Token discipline:**
- Heaviest spend was on subagent dispatch (4 × ~700 word reports + their ~100k internal traces). Worth it — the reports drove the integration decision. Future sessions doing similar work could probably pass smaller context blobs since subagents auto-read.
- The primary doc grew ~5x between Phase 1 (framing) and Phase 2 (integration). Acceptable — it's the session's working artifact. Won't be re-read after this session beyond the handoff entry's link-back.

**Communication discipline:**
- Auto-mode meant most per-turn output was inline action / tool calls rather than dedicated Communication blocks. The discipline.md communication-discipline rules (high-level only, no work-recap, no identifier-shorthand) apply more weakly to auto-mode action streams — but the final close (PR descriptions + handoff + this audit) is the surface where the rules apply fully. The PR descriptions land clean; the handoff stays high-level; this audit is internal so the rules relax for self-documentation.

## Walk 5 — Closing blocks

The session has been running under auto-mode without dedicated per-turn Communication closing blocks. The substantive closes are:

- The PR descriptions (auto-mode-appropriate; the maintainer reviews via merged-PR URLs).
- The handoff document (the canonical session-close surface; passes the discipline content test).
- This audit document (internal to the project's improvement record).
- The final response message at session close (will close with a Read pointing at the merged PRs + handoff).

For the final response, applying discipline.md item 5 (pre-send content test): walk each Communication sentence against the derivable-by-maintainer filter, the anti-pattern scan, and the slot test. Done at compose-time.

## Walk 6 — System-level meaning

The action primitive is the second dispatch path in Apeiron alongside `emit`. It's the first hook that mutates engine state outside the build / precompute / runtime cycle. Why it matters:

- Per-renderer view-state at `engine.cache["__view_state__"]` establishes the reserved-namespace pattern for runtime state distinct from build-time cache. Future runtime state (selection, scroll position, drag state, focus state) follows this pattern.
- The dispatch path composes forward to #041 (input-as-channel) and #042 (mutation-with-inverse) without architectural rework. The wishlist's longer-term architecture lands incrementally rather than as a big bang.
- The accumulator-pair (mount-panel + add-panel-action) is the project's first matched pair of skills covering both axes of panel evolution (data + interaction). The pattern of "every wish-grant produces an accumulator that absorbs adjacent wishes" is now demonstrated twice; the wish-granting workflow has internal momentum.

## Walk 7 — Forward-looking

The next wish-granting session inherits:

- Tier A complete; Tier B partial — #006 granted, #008 file-watcher view-refresh and #007 SessionRoster + ChatPanel still open.
- Three new follow-up wishes (#059 content-hash ids, #060 CLI multi-command mode, #061 list-commands verb) all bounded enough to ship in a short focused session.
- Tier C panels (#016-#022) become single-skill compositions of mount-panel + add-panel-action.
- Pending convention proposals from prior sessions remain queued in Alethea's `pending.md`.
- The selection-channel / OverlayHost framing remains as a future architectural question; not blocking but worth re-visiting when a wish surfaces that the alternative shape would grant more easily.

## Walk 8 — Meta-audit

**What did this audit miss?**

1. **Hot-reload + view-state evolution.** The handoff's "Open architectural questions" flagged this but the audit didn't probe deeply: what happens when a renderer module is hot-reloaded and the new module expects a different view-state vocabulary (renamed keys)? Today the new module reads the old keys with `.get(key, default)` defaults and silently no-ops. A schema-versioning convention for view-state keys is worth designing before more renderers grow handler tables. Filed below as a procedural improvement.

2. **The closing-block-enforcement Stop hook (from the prior session's wrap-up).** The hook was reportedly installed at `.claude/hooks/closing_block_check.py` per the planning-parallel-arc handoff. This session ran under auto-mode without dedicated per-turn closing blocks; whether the hook fired (and what it did) is unverified. Worth checking next session if a closing-block discipline failure surfaces.

3. **Convention drift: per-turn closing blocks under auto-mode.** The discipline page says every turn ends with a closing block. Under auto-mode, the practical pattern is that turns end with the next action (not a structured close), and the "close" happens at session end. This is consistent with auto-mode's "minimize interruptions" rule but tensions with the discipline page's "always present" rule. Worth surfacing to the maintainer for clarification — auto-mode may implicitly waive per-turn closes and the convention should say so explicitly.

4. **Context-budget fill at audit time.** Substantial context remains. The "use full context budget" convention says enumerate additional valuable work before concluding. Strong candidates: #061 (list-commands verb — 10 LOC, addresses a gap surfaced today, demonstrates the workflow can ship tiny CLI extensions inside the same session). Will ship this before close.

## Procedural improvements surfaced (candidate edits)

- `session_types/wish_granting.md` Phase 2: promote "pre-name two candidates for stress-test" from parenthetical to procedural step. Tiny clarity win.
- `session_types/wish_granting.md` Phase 4: name fresh-subagent verification as a primary source of CLI/text-API ergonomic gaps (not just yes/no functional verification).
- New wish: parser-invariant audit meta-skill that runs before any panel-touching wish-grant, surfacing parser convention gaps (id-stability, actions-shape, status-coverage) proactively rather than reactively via stress-test.
- Open architectural design: view-state schema versioning for renderer hot-reload safety. Probably belongs as a wish — bounded enough.

## Auditing the audit

This audit walked all eight passes from the wrap-up convention's audit step. The meta-audit (Walk 8) surfaced four items not surfaced in earlier walks; three are forward-looking (schema versioning, closing-block-under-auto-mode, hot-reload safety) and one is a context-budget-fill action item (#061). Acting on #061 now per the use-full-context-budget convention; the others land in this document as forward-looking notes for the next session to pick up.
