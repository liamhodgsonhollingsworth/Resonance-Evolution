# Failure-mode registry — the evolving break-class catalog for Godot stress-testing

Liam 2026-07-08: *"start practicing an evolving process where you stress test by explicitly searching
for all the things that could be wrong or broken, creating composable and generalizable tools ... such
that future instances of testing would re-use those tools rather than making new ones."*

This is that catalog. Every time a NEW way-things-break is discovered, add a row here **and** (if it is
statically or at-runtime detectable) a detector to `run_all_tests.py` so the next stress-sweep catches
it automatically. The battery reads this file's IDs; a break class that is only documented (not yet
detectable) is a TODO for the next session to make detectable. **Append-only in spirit** — supersede a
row (mark it) rather than deleting, so the history of what has bitten us stays inheritable.

| ID | Break class | Symptom | Detector (in the battery) | Discovered |
|----|-------------|---------|---------------------------|-----------|
| FM-01 | **Cold class cache** — a scene's scripts `extends`/reference a `class_name`; the gitignored `.godot/global_script_class_cache.cfg` is missing/stale at launch | GREY SCREEN — root script parse-fails, `_ready` never runs, flat grey viewport | `scene_smoketest.py` on a COLD cache (default) → flat-frame + "Could not resolve script" parse errors. FIX: launch via `launch_scene.py` (rebuilds cache first) | 2026-07-08 (visi-sonor demo) |
| FM-02 | **Two competing bright WorldEnvironments** — two envs both add exposure/background | BLOWN-OUT near-white frame, content invisible | `scene_smoketest.py` → `lum_mean > 0.95` | 2026-07-07 (visi-sonor Wave 4) |
| FM-03 | **`String(v)` used as a cast** — `String()` is a constructor that crashes on a non-string arg | runtime crash on the branch that hits it | static lint: `\bString\(` in a `.gd` (flag for review; use `str()`) | 2026-07-07 (prim_response_curve) |
| FM-04 | **Untyped `.new()` / `load().new()` inference** — `var x := load(p).new()` can't infer a type from an untyped Variant | compile error "Cannot infer the type" → scene won't load | static lint: `:=\s*(load\|preload)\([^)]*\)\.new\(\)` | 2026-07-07 (Wave 0 demo) |
| FM-05 | **Bare `class_name` type annotation in a scene-root script** — `var x: PrimFoo` needs the cache even if `.new()` uses a path/preload | same grey-screen shape as FM-01 (cache-dependent) | `scene_smoketest.py` cold cache catches the parse-fail | 2026-07-08 (b40a094 red herring) |
| FM-06 | **Click eaten by a covering node** — a transparent/again node with `mouse_filter != IGNORE` sits over a button | a button "does nothing" — the click lands on the coverer | `agent_harness.gd ui_click` reports which node ACTUALLY received the event | 2026-07-05 (aperture ✕ button) |
| FM-07 | **Unwired seam emits zero** — a live path (e.g. audio analyzer) that nothing feeds returns all-zeros while a synthetic test fixture masks it | "works in tests, dead live" | run the LIVE path (real mp3 / real input), not only the synthetic fixture; assert non-zero | 2026-07-07 (1A analyzer bus gap) |
| FM-08 | **Dummy audio/GL driver in `--headless`** — `--headless` uses stub drivers; `get_image()` is blank, analyzer bands are zero | headless "render/audio ok" that is meaningless | render checks MUST use the console exe WITHOUT `--headless` (real GL); audio-live checks need a real driver | 2026-07-07 |
| FM-09 | **Headless-with-rebuilt-cache masks a cold-launch bug** — a test that rebuilds the cache before running never sees FM-01/FM-05 | ships a grey screen that "passed all tests" | the battery smoketests scenes on a COLD cache; never rebuild-then-headless as the render gate | 2026-07-08 |
| FM-10 | **Flaky test** — a test whose PASS/FAIL varies between identical runs (timing/physics/order dependence) | "passed last time" — intermittent red hiding a real bug behind luck | run a suite ≥2×; a differing verdict = flaky (e.g. `headless_feature_smoke_test` E1 char_move: 20-PASS-0-FAIL one run, 19-PASS-1-FAIL the next) | 2026-07-08 |
| FM-11 | **Scene hangs on load / never self-quits** — a scene whose `_ready` blocks (heavy synchronous gen, an await that never resolves) | a one-click launch that "hangs"; the window never becomes interactive | `scene_smoketest.py` → "launch timed out" / "no verdict" (e.g. painterly_scene, lsystem_scene) | 2026-07-08 |

**FM-03 precision note (2026-07-08):** a blanket `String(` lint flagged 1310 mostly-legit uses. The detector now flags ONLY `String(params.get(…))` / `String(inputs.get(…))` in non-test code — the runtime-Variant coercion that actually throws (codebase convention: `str()`, never `String()`, for a Variant — see prim_feature_pick:67). The remaining hits are a real low-severity cleanup list (convert to `str()`), not false positives.

## How the battery uses this

`run_all_tests.py`:
1. runs every `headless_*_test.gd` (functional/mechanics coverage),
2. `scene_smoketest.py`-tests every scene in the launchable manifest on a COLD cache (FM-01/02/05/09),
3. runs the static lints for FM-03/FM-04 (and any future statically-detectable class),
and aggregates one PASS/FAIL matrix. Re-run it as the single stress gate; extend THIS file + a detector
when a new break class appears.
