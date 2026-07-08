#!/usr/bin/env python3
"""run_all_tests.py — the ONE composable stress gate for the Resonance-Evolution Godot project.

Liam 2026-07-08: an evolving process that "stress tests by explicitly searching for all the things
that could be wrong or broken", with "composable and generalizable tools ... such that future
instances of testing would re-use those tools rather than making new ones." This is that gate. Instead
of running 79 `headless_*_test.gd` files by hand and eyeballing each, run THIS once. It:

  1. HEADLESS SUITES — runs every `headless_*_test.gd` and classifies PASS / FAIL / UNKNOWN by the
     `RESULT: ALL PASS` sentinel + `SCRIPT ERROR` / `Parse Error` scan.
  2. SCENE RENDER — rebuilds the class cache once, then `scene_smoketest.py`-tests every launchable
     scene WARM (its intrinsic render health: grey/blank, blown-out, dead, or built-nothing — the
     cold-cache case FM-01 is now globally solved by launch_scene.py, so warm reveals REAL breakage).
  3. STATIC LINTS — greps the source for the statically-detectable failure modes in FAILURE_MODES.md
     (FM-03 `String()` cast, FM-04 untyped `load().new()`).

Aggregates ONE PASS/FAIL matrix → stdout + `artifacts/stress_report.json` + `artifacts/stress_report.md`.
Exit 0 iff everything green. Extend FAILURE_MODES.md + add a detector here when a new break class appears.

USAGE:
    py -3 godot/tools/run_all_tests.py                         # full sweep
    py -3 godot/tools/run_all_tests.py --no-smoketest          # headless + lints only (fast, no GL)
    py -3 godot/tools/run_all_tests.py --filter visisonor      # only tests/scenes matching a substring
    py -3 godot/tools/run_all_tests.py --scenes res://demo_interactions.tscn   # smoketest a specific set
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

# The matrix prints ✓/✗ marks — on a Windows cp1252 console these raise UnicodeEncodeError mid-report.
# Force UTF-8 so the summary + RESULT line always print regardless of the console code page.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

HERE = Path(__file__).resolve()
PROJECT = HERE.parents[1]                 # <re>/godot
RE_ROOT = PROJECT.parent
CONSOLE = os.environ.get("GODOT_CONSOLE", r"C:/Users/Liam/godot/Godot_v4.6.3-stable_win64_console.exe")
CREATE_NO_WINDOW = 0x08000000

# Launchable PERSISTENT scenes (root [node] references a Script, and the scene STAYS UP so the settle-
# and-capture smoketest can render it). Override with --scenes. Some are 2D/UI — a near-uniform 2D frame
# can trip the flat-frame heuristic; review outliers rather than trusting blindly.
# NOT included: self-terminating batch/proof drivers that call get_tree().quit() in _ready (live_demo.tscn,
# render_view.tscn). They kill the shared SceneTree before the smoketest's settle counter can capture →
# "no verdict produced" (a false FAIL, not breakage). Both exit 0 cleanly and are covered by their own
# headless suites (headless_live_test.gd + headless_view_test.gd). See FAILURE_MODES.md FM-12.
DEFAULT_SCENES = [
    "res://demo_interactions.tscn",
    "res://main.tscn",
    "res://optical_showcase.tscn",
    "res://aperture/aperture_3d.tscn",
    "res://aperture/evolution_3d.tscn",
    "res://aperture/sandbox_home.tscn",
    "res://examples/sandbox_creative.tscn",
    "res://examples/projection_sim_demo.tscn",
    "res://examples/wfc_demo.tscn",
    "res://examples/painterly_scene.tscn",
    "res://examples/lsystem_scene.tscn",
    "res://gallery/gallery.tscn",
    "res://walkabout/walkabout.tscn",
]

# Heavy generative scenes: a synchronous CPU painterly paint (Kuwahara, O(pixels × radius²) in GDScript)
# blocks the main thread long enough to blow the default 90s/90-frame budget. This is NOT a hang (FM-11) —
# the scenes render fine given a shorter settle + a longer timeout. Verified 2026-07-08: both PASS at
# settle 40 / timeout 180 (painterly 43 descendants/260 colours, lsystem 830 descendants/220 colours).
HEAVY_SCENES = {
    "res://examples/painterly_scene.tscn": {"settle": 40, "timeout": 180},
    "res://examples/lsystem_scene.tscn": {"settle": 40, "timeout": 180},
}


def run(cmd, timeout, no_window=True):
    try:
        flags = CREATE_NO_WINDOW if no_window else 0
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout,
                           encoding="utf-8", errors="replace", creationflags=flags)
        return (p.stdout or "") + "\n" + (p.stderr or ""), False
    except subprocess.TimeoutExpired as e:
        out = ((e.stdout or "") if isinstance(e.stdout, str) else "")
        err = ((e.stderr or "") if isinstance(e.stderr, str) else "")
        return out + "\n" + err, True


def classify_headless(log: str, timed_out: bool):
    if timed_out:
        return "FAIL", ["timed out"]
    errs = re.findall(r"(?:SCRIPT ERROR|Parse Error).*", log)
    if errs:
        return "FAIL", [e.strip() for e in errs[:4]]
    # Explicit failure sentinels first (so "0 FAIL" / "FAILURES PRESENT (1)" are read correctly).
    if re.search(r"RESULT:\s*FAILURES PRESENT", log) or re.search(r"RESULT:.*\b([1-9]\d*)\s+FAIL", log):
        fails = re.findall(r"(?:RESULT:.*|^\s*FAIL\b.*)", log, re.MULTILINE)
        return "FAIL", [f.strip() for f in fails[:4]]
    # Pass sentinels: "RESULT: ALL PASS", or an explicit "… 0 FAIL", or "N PASS, 0 FAIL".
    if ("RESULT: ALL PASS" in log
            or re.search(r"RESULT:.*\bPASS\b.*\b0\s+FAIL", log)
            or re.search(r"RESULT:.*\b0\s+FAIL", log)):
        return "PASS", []
    # A lone unqualified "FAIL" line with no RESULT verdict → still a fail signal.
    if re.search(r"^\s*FAIL\b", log, re.MULTILINE) and "RESULT:" not in log:
        return "FAIL", [m.strip() for m in re.findall(r"^\s*FAIL\b.*", log, re.MULTILINE)[:4]]
    return "UNKNOWN", ["no recognized RESULT sentinel"]


def rebuild_cache():
    run([CONSOLE, "--headless", "--path", str(PROJECT), "--editor", "--quit"], 180)


def smoketest_scene(scene: str, timeout: int, settle: int = 90):
    safe = re.sub(r"[^a-z0-9]+", "_", scene.lower().replace("res://", ""))
    out_png = f"res://artifacts/smoke_{safe}.png"
    out_json = f"res://artifacts/smoke_{safe}.json"
    cmd = [sys.executable, str(HERE.parent / "scene_smoketest.py"),
           "--scene", scene, "--out", out_png, "--json", out_json,
           "--settle", str(settle), "--keep-cache", "--timeout", str(timeout)]
    log, timed_out = run(cmd, timeout + 15, no_window=True)
    m = re.search(r"SMOKETEST_RESULT:(\{.*\})", log)
    if m:
        try:
            r = json.loads(m.group(1))
            return ("PASS" if r.get("pass") else "FAIL"), r.get("reasons", []), out_png
        except json.JSONDecodeError:
            pass
    return "FAIL", ["no smoketest verdict"], out_png


def static_lints(filter_sub: str):
    """FM-03 / FM-04 static detectors over the .gd source. Precision-tuned from the 2026-07-08 sweep:
    a blanket `String(` flagged 1310 mostly-legit uses (String(dict.get(...)) is fine). FM-03 now flags
    ONLY the shape that actually crashed (String() coercing a runtime Variant param/input — a non-string
    there throws), and skips test files (tests assert on known-string values)."""
    findings = []
    gd_files = [p for p in PROJECT.rglob("*.gd") if ".godot" not in p.parts]
    # FM-03: String(params.get(...)) / String(inputs.get(...)) — the runtime-Variant coercion that throws.
    string_cast = re.compile(r"(?<![A-Za-z_])String\(\s*(?:params|inputs)\.get\(")
    untyped_new = re.compile(r":=\s*(?:load|preload)\([^)]*\)\.new\(\)")  # FM-04
    for p in gd_files:
        rel = str(p.relative_to(PROJECT)).replace("\\", "/")
        if filter_sub and filter_sub not in rel:
            continue
        if p.name.startswith("headless_") or p.name.endswith("_test.gd") or "tests" in p.parts:
            continue  # test code asserts on known-typed values — not the runtime risk
        try:
            lines = p.read_text(encoding="utf-8", errors="replace").splitlines()
        except OSError:
            continue
        for i, line in enumerate(lines, 1):
            code = line.split("#", 1)[0]  # strip trailing comment (cheap; not string-aware)
            if string_cast.search(code):
                findings.append(("FM-03", f"{rel}:{i}", line.strip()[:100]))
            if untyped_new.search(code):
                findings.append(("FM-04", f"{rel}:{i}", line.strip()[:100]))
    return findings


def main() -> int:
    ap = argparse.ArgumentParser(description="Run the full RE Godot stress battery.")
    ap.add_argument("--no-smoketest", action="store_true", help="skip the GL scene-render pass")
    ap.add_argument("--no-headless", action="store_true", help="skip the headless suites")
    ap.add_argument("--no-lint", action="store_true", help="skip the static lints")
    ap.add_argument("--filter", default="", help="only tests/scenes/files whose path contains this substring")
    ap.add_argument("--scenes", default="", help="comma-separated res:// scenes to smoketest (overrides default)")
    ap.add_argument("--timeout", type=int, default=90, help="per-item timeout seconds")
    args = ap.parse_args()

    t0 = time.time()
    report = {"headless": [], "scenes": [], "lints": [], "summary": {}}

    # Rebuild the class cache ONCE up front. Both the headless suites AND the scene smoketests use
    # `class_name` globals, which resolve at runtime only via the (gitignored) cache — a cold run fails
    # every class_name reference (FM-01/FM-09). A real test run sets the cache up first; the battery does
    # too, so its job (functional coverage) isn't masked by the already-characterized cold-cache case.
    if not (args.no_headless and args.no_smoketest):
        print("[0] rebuilding class cache (so class_name globals resolve)…")
        rebuild_cache()

    # 1. headless suites
    if not args.no_headless:
        tests = sorted(PROJECT.glob("headless_*_test.gd"))
        if args.filter:
            tests = [t for t in tests if args.filter in t.name]
        print(f"[1/3] headless suites: {len(tests)}")
        for t in tests:
            log, to = run([CONSOLE, "--headless", "--path", str(PROJECT), "-s", f"res://{t.name}"],
                          args.timeout)
            status, reasons = classify_headless(log, to)
            report["headless"].append({"test": t.name, "status": status, "reasons": reasons})
            mark = {"PASS": " ✓", "FAIL": " ✗", "UNKNOWN": " ?"}.get(status, "")
            print(f"    {status:7}{mark}  {t.name}" + (f"   {reasons[0]}" if reasons else ""))

    # 2. scene render smoketests (warm)
    if not args.no_smoketest:
        scenes = [s.strip() for s in args.scenes.split(",") if s.strip()] or list(DEFAULT_SCENES)
        if args.filter:
            scenes = [s for s in scenes if args.filter in s]
        print(f"[2/3] scene render smoketests: {len(scenes)} (cache already rebuilt above)")
        for s in scenes:
            over = HEAVY_SCENES.get(s, {})
            status, reasons, png = smoketest_scene(
                s, over.get("timeout", args.timeout), over.get("settle", 90))
            report["scenes"].append({"scene": s, "status": status, "reasons": reasons, "png": png})
            mark = " ✓" if status == "PASS" else " ✗"
            print(f"    {status:7}{mark}  {s}" + (f"   {reasons[0]}" if reasons else ""))

    # 3. static lints
    if not args.no_lint:
        findings = static_lints(args.filter)
        report["lints"] = [{"fm": fm, "at": at, "code": code} for fm, at, code in findings]
        print(f"[3/3] static lints (FAILURE_MODES.md): {len(findings)} finding(s)")
        for fm, at, code in findings[:40]:
            print(f"    {fm}  {at}   {code}")

    # summary
    def count(rows, s): return sum(1 for r in rows if r["status"] == s)
    hp, hf, hu = count(report["headless"], "PASS"), count(report["headless"], "FAIL"), count(report["headless"], "UNKNOWN")
    sp, sf = count(report["scenes"], "PASS"), count(report["scenes"], "FAIL")
    report["summary"] = {
        "headless": {"pass": hp, "fail": hf, "unknown": hu, "total": len(report["headless"])},
        "scenes": {"pass": sp, "fail": sf, "total": len(report["scenes"])},
        "lints": len(report["lints"]),
        "elapsed_s": round(time.time() - t0, 1),
    }
    green = hf == 0 and sf == 0
    print("=" * 72)
    print(f"HEADLESS  {hp} pass / {hf} fail / {hu} unknown / {len(report['headless'])}")
    print(f"SCENES    {sp} pass / {sf} fail / {len(report['scenes'])}")
    print(f"LINTS     {len(report['lints'])} finding(s)")
    print(f"ELAPSED   {report['summary']['elapsed_s']}s")
    print("RESULT:", "ALL GREEN ✓" if green else "BREAKAGE FOUND ✗")
    print("=" * 72)

    art = PROJECT / "artifacts"
    art.mkdir(parents=True, exist_ok=True)
    (art / "stress_report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    _write_md(art / "stress_report.md", report)
    print(f"reports: {art/'stress_report.json'}  +  .md")
    return 0 if green else 1


def _write_md(path: Path, report: dict) -> None:
    s = report["summary"]
    lines = ["# Stress report", "",
             f"- headless: **{s['headless']['pass']}** pass / {s['headless']['fail']} fail / {s['headless']['unknown']} unknown",
             f"- scenes: **{s['scenes']['pass']}** pass / {s['scenes']['fail']} fail",
             f"- lints: {s['lints']} finding(s)", f"- elapsed: {s['elapsed_s']}s", ""]
    for title, key in [("Headless FAIL/UNKNOWN", "headless"), ("Scene render FAIL", "scenes")]:
        bad = [r for r in report[key] if r["status"] != "PASS"]
        if bad:
            lines += [f"## {title}", ""]
            for r in bad:
                name = r.get("test") or r.get("scene")
                lines.append(f"- `{name}` — {r['status']}: {'; '.join(r['reasons'][:3])}")
            lines.append("")
    if report["lints"]:
        lines += ["## Static-lint findings", ""]
        for f in report["lints"][:60]:
            lines.append(f"- {f['fm']} `{f['at']}` — `{f['code']}`")
    path.write_text("\n".join(lines), encoding="utf-8")


if __name__ == "__main__":
    sys.exit(main())
