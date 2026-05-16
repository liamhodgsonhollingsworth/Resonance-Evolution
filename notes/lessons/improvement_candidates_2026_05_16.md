# Improvement candidates — 2026-05-16

End-of-session audit for the Apeiron dream-features skeleton session. Per the restored audit convention (filed as pending #006), divergent freeform across eight audit walks. Findings that landed as edits this turn are noted inline; findings that didn't get codified live here as the queue.

## Walk 1: Session arcs — what worked, what didn't

**Worked:**
- Loading the existing architecture before designing absorbed most features without re-design — the bootstrap session's commitments (topology-over-coordinates, channels-by-name, aggregator-as-node, build/runtime split) covered features 2, 4, 7 fully and absorbed parts of nearly every other one.
- Building skeleton + tests + verification end-to-end. The tesseract bundle render gave a concrete artifact rather than just "the design composes." Visible-artifact verification beats test-passes-alone for architectural confidence.
- Three logical commits made the branch history readable. Each commit is independently coherent.

**Didn't:**
- **Concluded the session at named-task-complete.** I asked the naming question and waited. The remaining context window had substantial room. The maintainer surfaced this as a forgotten convention — codified now as the use-full-context-budget memory entry and the pending #007 convention.
- **Skipped the audit pass.** The convention was archived 2026-05-13 and dropped from session_wrap_up.md on 2026-05-14. Two failures of the same shape: not noticing that named-completion ≠ session-complete. Codified now in memory and pending #006.
- **Conflated verification with stress-testing.** Original todos listed "Stress-test: render new demo bundles + verify visually" as the stress-test step. Rendering verifies; it doesn't try to break. Built the stress-test-design skill in this audit pass to separate the two.
- **Self-audited the design as the designer.** From the bootstrap's "proposer-frame blind spots" warning — single-author stress-tests don't catch what cross-audit catches. The fix would have been to dispatch a subagent for the stress-test; I did it myself. Noted for future sessions but not the highest-leverage fix in this audit.

## Walk 2: Live-trial rules — which solidify, which need watching

**Codify as permanent** (done this turn):
- End-of-session audit mandatory.
- Use-full-context-budget.
- Stress-test-design as a skill.

**Solidify with caveat** (need attention):
- The Intent-fidelity pass added to stress-test-design v2 came from a single application. The skill's own evolution-notes rule says "new passes should land when they prove productive across multiple applications, not after a single use." Self-violation. Resolution: marked as provisional in the skill — pending confirmation on next application. If the next application doesn't surface intent-fidelity-class vulnerabilities, the pass moves to "candidate, awaiting evidence."

**Test in next session, don't codify yet:**
- Whether the "named channels carry everything" meta-generalization from `dream_features_extensions.md` actually holds against new features. Cross-test by asking: does feature N pass through a new channel name + new producer-node + new consumer-node? If yes, the meta-generalization is correct. If a counterexample surfaces, the meta-generalization needs refinement.

## Walk 3: Artifacts — what stays, what gets edited, what's superseded

**Stays as-is:**
- design/dream_features.md, dream_features_extensions.md.
- Engine extensions (engine/input.py, inverse.py, sim_precompute in core, View fields).
- Seven node-types (with V3 + V5 patches applied this turn).
- One renderer (ProjectorN).
- Three scene demos.
- Test suite (now 59 tests).
- Name suggestions, handoff, whats_built.

**Gets edited this turn:**
- stress-test-design skill — Intent-fidelity marked provisional.

**Superseded** (future sessions):
- Generator's inline-rasterization (v1 choice). Triggered when dynamic-spawn-during-precompute gets engine support.
- invert_edit's in-place Seed mutation (stress-test V1). Triggered when undo/redo or per-edit-creates-new-node infrastructure lands.

## Walk 4: Session's own outputs — token discipline

- Communication blocks used minimal numbered lists per the parallel-development memory entry. Compliant.
- The design doc and stress-test doc are necessarily long; they ARE substantive content the maintainer reads as artifacts, not status reports. Acceptable.
- No emojis. Compliant.
- Markdown file-path links followed the system prompt's format. Compliant.

## Walk 5: Closing blocks

- First turn: Question shape with Recommended on first option. Survived the content-test (only the maintainer can decide the name).
- Second turn ("3 defer"): one-line acknowledgment. Compliant.
- This turn: the audit IS the close. The Communication after will be brief.

## Walk 6: System-level meaning

The session changes the project trajectory in three ways:

1. **Apeiron has dream-mode infrastructure** ready for the realtime renderer. The next session picks up the windowing-library decision and wires the loop — every dream-mode feature flows through that decision.
2. **Session-discipline conventions restored** (audit + context-budget). Future sessions across all session types inherit this. The forgetting-loop that lost the audit-pass in the 2026-05-14 compression now has a memory anchor against recurrence.
3. **First adversarial design skill** in the catalog (stress-test-design). All existing skills are constructive (claim, iterate-and-check, recall, pull-and-resync, test-findability). Stress-test-design is the first skill that tries to BREAK an artifact. Skill-catalog has a new shape — more adversarial skills can follow.

## Walk 7: Forward-looking — what next session inherits

**On the queue for the next Apeiron session:**
- Realtime renderer + windowing-library decision.
- Invert_edit append-only fix (stress-test V1).
- Generator-inside-Computer staleness (V4).
- Click-to-edit mechanism (V7).
- The Intent-fidelity provisional pass — pending second-application confirmation.
- The regression check that V15 flagged but didn't run (showcase scene + new node-types co-existence). Done this turn; result is in the audit summary.

**On the queue for the next Alethea/meta-layer session:**
- Pending #006 (session_wrap_up.md audit step) awaiting maintainer review.
- Pending #007 (use-full-context-budget convention) awaiting maintainer review.

## Walk 8: Meta-audit — what this audit missed

**Found:**
- The audit didn't initially check the existing test scenes against the new node-types. V15 in the stress-test flagged the regression surface but I queued it rather than running it. Running it this turn surfaces whether new node-types break old scenes. (Tests are all isolated by engine fixture; no global state leaks. But the showcase scene specifically — `scenes/showcase.json` — should still render with the new types in scope. Added to this turn's commit.)
- The audit didn't initially examine subagent dispatching. I did the stress-test in-line rather than dispatching a subagent for fresh-eyes review. For future sessions: when running the stress-test-design skill on your own design, prefer a subagent dispatch over in-line application because the proposer-frame-blindspot is exactly the blindspot the skill tries to catch.

**Loop-back applied:** added the showcase regression check to this turn's commit set. Added the subagent-dispatch preference as a note in the stress-test-design skill's evolution notes.

**Audit-of-the-audit:** does this audit document miss anything? Two potential blindspots:
1. I didn't audit the **maintainer-facing experience** — was the response shape clean for the maintainer to read, or did I bury value behind too much text? The first-turn Communication was 4 items; the second-turn was 1 line; the third (current) will be ~3 items. Probably OK but I lack outside perspective.
2. I didn't check whether the **stress-test findings would themselves benefit from cross-audit**. The 15 vulnerabilities I listed are my list; a second reader might find different ones, or rank them differently, or reject some as non-issues. Cross-audit by a subagent is the next-session candidate.

## Convention-edit candidates surfaced

- **Audit subagent dispatch when applicable.** When a session runs the stress-test-design skill on its own design, the audit should prefer a subagent for fresh-eyes review unless the design is small enough that proposer-frame-blindness is unlikely to matter. Will land in the skill's evolution notes after the next application confirms the pattern.
- **Verify ≠ stress-test.** The distinction is in the new skill's "When to use" section already. Worth surfacing more loudly in the parallel-development session-type doc on the next iteration.
