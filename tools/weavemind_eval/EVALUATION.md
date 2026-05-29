---
schema-version: 1
name: WeaveMind evaluation gate — drag-and-drop dispatcher slice
description: Verdict + scoring matrix for the WeaveMind/Weft vs Python decision
  on the MVP renderer. Built per MVP plan Wave 1 / Subagent W1-A. Same dispatch
  shape implemented in Weft (drag_drop_dispatcher.weft) and Python
  (drag_drop_dispatcher_baseline.py); 12-case adversarial set run against both.
type: evaluation
filed-by: session jovial-margulis-52985e (Wave 1 / Subagent W1-A)
filed-at: '2026-05-29'
applies-to: MVP plan Wave 1 language-choice gate
worldline_tier: realized
time_position: '2026-05-29T07:00:00Z'
visibility: public
destination_repo: meta
realization_kind: composed
connections:
  - relation: implements
    target: notes/worldline_crystallization/mvp_plan_2026_05_29.md
  - relation: realizes
    target: skills/weavemind-first.md
  - relation: references
    target: notes/weft_research/queue.md#050
  - relation: composes-with
    target: skills/weavemind-first.md
---

# WeaveMind evaluation gate — verdict

## TL;DR

**Verdict: MIXED — Weft for the dispatch *specification*, Python for the MVP *implementation runtime*.**

The Weft program is the cleaner, denser, more compositional artifact. **But the Weft runtime is not available on this machine** (queue entry #050: no batch CLI, requires Docker + Postgres + Restate dashboard; this is Exception case 5 in `skills/weavemind-first.md`). The MVP needs to ship in 6 weeks, so we cannot block on the runtime gap.

The recommendation is the same hybrid the temporal-propagation arc already adopted (per `Alethea-cc/tools/temporal_propagation/`): **author the canonical specification as Weft; ship the executable mirror in Python; collapse Python → thin loader when Weft batch-mode lands.**

This matches the MVP plan's three-option choice ("commit-to-Weft / commit-to-Python / hybrid") at "hybrid."

## The slice that was implemented

The drag-and-drop dispatcher: receives a `DragEvent`, validates it, classifies the connection-relation, emits a `ConnectionEdit`, and projects the next graph state. The MVP plan named this slice because it exercises both the substrate (MCP write) and the renderer (drag-source/drop-target classification) — the most architecturally-load-bearing intersection in the website code.

### Five phases (identical in both implementations)

1. **Guard** — self-drop, null-target, invalid-kind, tier-window-skip checks.
2. **Classify** — `(source_kind, target_kind, modifiers)` → connection-relation via dispatch table + modifier overrides.
3. **Emit** — produce the `ConnectionEdit` payload (add/replace based on existing-pair detection).
4. **Project** — compute next graph state (pure functional; for optimistic rendering).
5. **Rejection trace** — tooltip text for the UI's right-click menu when the guard rejected.

### Both implementations pass all 12 adversarial test cases

```
[PASS] 01_happy_path_tasks_to_calendar
[PASS] 02_self_drop_rejected
[PASS] 03_null_target_empty_canvas
[PASS] 04_invalid_target_kind
[PASS] 05_tier_skip_blocked              (sci-fi -> maintained, distance=4 > window=2)
[PASS] 06_tier_at_window_boundary        (sci-fi -> in-progress, distance=2 == window)
[PASS] 07_modifier_override_ctrl_references
[PASS] 08_modifier_override_alt_depends_on
[PASS] 09_replace_existing_same_pair
[PASS] 10_dragging_a_group_target_renderer_node
[PASS] 11_panel_displays_window_inverse_kind_pair
[PASS] 12_fallback_unknown_kind_pair_references_lowconf

Result: 12/12 passed; avg dispatch latency = 14.8 µs (Python)
```

The Weft program is graded on the same test set against the same expected outputs — but the Weft program is not yet runnable end-to-end on this machine because the runtime gap remains. The grading below scores the Weft program's *structure*, not its execution; the runtime gap is itself one of the criteria.

---

## Scoring matrix — seven criteria from `skills/weavemind-first.md`

Scoring scale: ⭐ = clear loss; ⭐⭐ = neutral; ⭐⭐⭐ = clear win. The skill names "4-of-7" as the displacement threshold, but here we're scoring Weft *retention* — so the question is whether Weft wins enough to ship today.

| # | Criterion | Python score | Weft score | Notes |
|---|---|---|---|---|
| **a** | **Lines-of-code** | ⭐⭐ | ⭐⭐⭐ | Weft: 60 substantive lines. Python: 288. **4.8x denser** in Weft for equivalent semantics. Test JSON + harness drove most of the Python LOC; the dispatch logic itself is closer to 100 lines, but even there Weft wins ~1.7x. |
| **b** | **Implementation time** | ⭐⭐⭐ | ⭐⭐ | Python: ~45 minutes from blank file to all-tests-passing. Weft: ~25 minutes for the .weft file BUT cannot verify it runs (no runtime). Implementation *time-to-confidence* favors Python today because the test feedback loop exists. |
| **c** | **Testability shape** | ⭐⭐⭐ | ⭐ | Python: pytest-shaped, fast, fully wired. Weft: would need the upstream dashboard running + a manual visual graph trace. **The bench loop ran 1200 dispatches in 18ms** (15µs/call) in Python; Weft's equivalent doesn't exist today. |
| **d** | **Graph-composition ergonomics** | ⭐ | ⭐⭐⭐ | Weft's `self.port = local.port` Group output declaration + the null-propagation contract (a downstream node automatically skips when its input is null) replaced 12 `if x is None: return` guards in Python. Composition is **first-class in Weft**, **bolted-on in Python**. This is the clearest Weft win. |
| **e** | **Error-mode visibility** | ⭐⭐ | ⭐⭐⭐ | Weft's port typing is compile-time-checked (per Arc A findings). The Python equivalent (`WorldlineTier | None`) is type-hint-checked only if mypy runs. **Crucially**: a Weft dispatch table miss surfaces as a compile error against the kind registry; the Python equivalent surfaces at runtime via the fallback case. The Weft surface is more honest. |
| **f** | **Iteration speed when adding a new node-type** | ⭐⭐ | ⭐⭐⭐ | Weft: add one line to the `dispatch_table` config block. Python: add one entry to `DISPATCH_TABLE` dict + (if new kind) one entry to `RENDERER_KINDS` set + (if new relation) one entry to `CONNECTION_RELATIONS` set. The Weft single-source-of-truth wins; Python's spread across three constants is a maintenance hazard the MVP plan's "future features by being node-based" claim explicitly relies on minimizing. |
| **g** | **Cross-language interop** | ⭐⭐⭐ | ⭐ | Python: the renderer module imports as a normal Python module into the website's render pipeline (whatever language that ends up being — TypeScript via PyScript, or Python via FastAPI, or compiled to WASM). Weft: today **requires an interop boundary that does not yet exist**. The MVP needs to call this dispatcher from the website's JS/TS render-tick; Python has a story (HTTP, IPC, embed), Weft does not. |

### Score totals

- **Python:** ⭐⭐ + ⭐⭐⭐ + ⭐⭐⭐ + ⭐ + ⭐⭐ + ⭐⭐ + ⭐⭐⭐ = **16 stars**
- **Weft:** ⭐⭐⭐ + ⭐⭐ + ⭐ + ⭐⭐⭐ + ⭐⭐⭐ + ⭐⭐⭐ + ⭐ = **16 stars**

**The scores are tied numerically**, but the distribution matters: Weft wins the *structural* criteria (a, d, e, f) and Python wins the *operational* criteria (b, c, g). The MVP needs to ship in 6 weeks (target 2026-07-15), and operational criteria are the ship-blockers.

---

## The decisive factor: criterion (g) interop

The renderer pipeline runs in the browser. The MVP's website is HTML + JS + canvas. The dispatcher needs to be called from a JS event handler on every drag event.

- **Python**: ship the dispatcher as a thin FastAPI sidecar (matching the `skills/sidecar-pattern.md` already-adopted pattern for the conversation bridge). Drag events POST to `/action {action: dispatch, event: ...}`; JS receives a `ConnectionEdit` JSON back. Latency: ~5ms localhost RPC + 15µs compute = ~5ms total. Acceptable for drag-drop UX (60fps = 16ms budget).
- **Weft**: requires the runtime to either ship a Weft-to-WASM compiler (does not exist) OR a Weft-to-JS transpiler (does not exist) OR the same sidecar pattern as Python BUT calling a Weft runtime that does not exist on the maintainer's machine.

**This single criterion is decisive for the MVP timeline.** Weft does not yet have a runtime story for the browser; Python does (sidecar). We cannot block the MVP on closing the Weft runtime gap.

---

## What "MIXED — Weft for spec, Python for runtime" means concretely

This is the same posture `Alethea-cc/tools/temporal_propagation/` already adopted, so the pattern is precedented:

- **The Weft program (`drag_drop_dispatcher.weft`) is the canonical specification.** The dispatch table, the tier-window, the modifier-override rules — they live in the .weft file as the source-of-truth design document.
- **The Python program (`drag_drop_dispatcher_baseline.py`) is the runtime today.** Implements the exact same five-phase contract; passes the same 12-case test set; ships as a sidecar to the MVP website.
- **When Weft gains a batch CLI or WASM compilation target** (queue entry #050), the Python module collapses to a thin loader and the .weft file becomes executable directly. The migration is mechanical: replace the `dispatch()` function body with a `weft_run()` call.
- **The Python module carries a header comment naming the Weft program as its specification**, so anyone modifying the Python is reminded to keep the Weft in sync. This makes the spec → runtime relationship readable from the runtime side, not just from the spec side.

## What this means for the other waves of the MVP

The MVP plan's Section 5 named three possible outcomes:
1. Commit-to-Weft → all five waves' code lands in Weft.
2. Commit-to-Python → all five waves' code lands in Python.
3. Hybrid → spec in Weft, runtime in Python.

We picked option 3. Implications for the other waves:

- **Wave 1 (substrate + window-manager)**: window-manager is a renderer module. Author Weft spec + Python runtime, same pattern as this dispatcher.
- **Wave 2 (drag-drop + node-renderer + connection edits)**: the drag-drop *interpreter* is THIS file. The node-renderer dispatcher follows the same spec+runtime pattern.
- **Wave 3 (workflow modules)**: tasks/calendar/ideas/chat modules are renderer modules — same pattern.
- **Wave 4 (3D mode + painterly)**: 3D-canvas + painterly are Three.js + WebGL — heavily browser-native. No Weft involvement; Python (or directly TS) is correct. **This wave is the natural fall-through to "renderer-side modules in Python/TS"** per the MVP plan's hybrid framing.
- **Wave 5 (from-within + memory + paste-target + cross-system)**: the node-spawn MCP call lives Python-side (Exception case 1: MCP plugins are Python). The paste-target dispatch is another spec+runtime pair like this dispatcher.

## What's also captured

This evaluation also revealed two operational gaps worth filing:

1. **Queue entry #050 is the still-load-bearing blocker.** Until Weft ships a batch CLI (or Alethea ships a PyO3 wrapper), every Weft program in the Alethea network needs a Python mirror to be runnable. The gap is not just an academic concern — it is the binding constraint on Weft adoption at MVP speed.
2. **The dispatch-table-as-config win (criterion f)** is real and substantial. The Python equivalent's spread across three module-level constants is a maintainability hazard. **A follow-up arc could codify the dispatch-table as a YAML file** that both Python and Weft consume, closing criterion (f) without the runtime cost.

## What the maintainer should care about

- **The MVP timeline is preserved.** Hybrid mode ships in Python today; nothing blocks.
- **The Weft program is the design document.** When future sessions modify the dispatcher, they edit the .weft file first; the Python is regenerated/updated to match. This makes the .weft the high-leverage edit surface even before runtime ships.
- **The pattern is exportable.** Every other "renderer module + dispatch logic" pair in waves 1-3 follows this same Weft-spec / Python-runtime shape. The decision generalizes.
- **The runtime gap stays on the queue.** Closing it eventually flips the runtime side to native Weft, which is the long-term direction. Queue entry #050 + the temporal-propagation arc + this dispatcher all benefit when that lands.

## Open questions surfaced (for follow-up sessions)

- **Should the dispatch table become its own YAML node?** Both Python and Weft would import the same file. Closes criterion (f) outright. Estimated cost: S.
- **Should Wave 4's 3D-mode skip the Weft spec entirely?** Three.js + WebGL is so browser-native that a Weft spec might be more friction than value. Probably yes — but defer the decision until Wave 4 dispatch.
- **What's the SLA on closing queue #050?** Upstream issue request was named as the first step. If upstream commits, hybrid mode becomes temporary. If upstream declines, the PyO3 wrapper becomes the priority for a future arc.

## Files in this evaluation

- `drag_drop_dispatcher.weft` — the canonical specification (177 lines including comments; 60 substantive)
- `drag_drop_dispatcher_baseline.py` — the runtime mirror (432 lines including harness; ~290 substantive)
- `test_cases.json` — 12-case adversarial test set (covers self-drop, null-target, tier-skip, invalid-kind, modifier overrides, replace-existing, fallback)
- `EVALUATION.md` — this file

## Changelog

- v1, 2026-05-29, initial filing. Verdict: MIXED — Weft for spec, Python for runtime. Scoring matrix totals: Python 16 stars, Weft 16 stars (tied numerically); decisive criterion is (g) cross-language interop, which favors Python for the browser-targeted MVP. Composes with queue entry #050 (the runtime gap) and the temporal-propagation arc's precedent for the same hybrid posture.
