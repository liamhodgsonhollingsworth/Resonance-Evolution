#!/usr/bin/env python3
"""Composable render-smoketest for ANY Godot scene — "does it actually render on a real launch?".

The reusable companion to `tools/scene_smoketest.gd`. An agent calls THIS, not Godot directly. It:
  1. (optionally, default ON) CLEARS the gitignored class cache so the launch is COLD — faithful to a
     fresh checkout / double-click, the exact state that surfaced the visi-sonor grey screen (#049).
  2. Launches the scene under a REAL GL context (the *console* exe, no --headless — so we get both a
     real render AND readable stdout) driving `res://tools/scene_smoketest.gd`, which instances the
     REAL .tscn, uses its OWN camera, settles, captures a frame, and writes a JSON verdict.
  3. Reads the JSON verdict FILE (primary) + scans the log for parse-error patterns (SCRIPT ERROR /
     Parse Error / Could not find type / Cannot infer) that a grey screen emits, and MERGES both into
     one PASS/FAIL. Exit 0 = PASS, 1 = FAIL.

Why this exists (Liam 2026-07-08): future render-verification REUSES this instead of writing another
bespoke capture harness. The last one used its own camera + preload + a warm cache and shipped a grey
screen. This one is faithful by construction.

USAGE:
    py -3 godot/tools/scene_smoketest.py --scene res://demo_interactions.tscn
    py -3 godot/tools/scene_smoketest.py --scene res://X.tscn --keep-cache --settle 120 --json out.json
"""
import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path

# The verdict lines print ✓/✗/· — on a Windows cp1252 console these raise UnicodeEncodeError and
# SUPPRESS the machine-readable SMOKETEST_RESULT line, so the caller reads "no verdict". Force UTF-8.
try:
    sys.stdout.reconfigure(encoding="utf-8", errors="replace")
    sys.stderr.reconfigure(encoding="utf-8", errors="replace")
except (AttributeError, ValueError):
    pass

HERE = Path(__file__).resolve()
DEFAULT_PROJECT = HERE.parents[1]  # <re>/godot
# Console exe: real GL render (no --headless) AND writes stdout/stderr (unlike the GUI-subsystem exe).
DEFAULT_GODOT = os.environ.get(
    "GODOT_CONSOLE",
    r"C:/Users/Liam/godot/Godot_v4.6.3-stable_win64_console.exe",
)
PARSE_ERROR_PATTERNS = [
    r"SCRIPT ERROR",
    r"Parse Error",
    r"Could not find type",
    r"Cannot infer the type",
    r"Identifier .* not declared",
    r"Compile Error",
]


def main() -> int:
    ap = argparse.ArgumentParser(description="Render-smoketest a Godot scene on a cold cache.")
    ap.add_argument("--scene", required=True, help="res:// scene to render-test")
    ap.add_argument("--godot", default=DEFAULT_GODOT, help="path to the Godot CONSOLE exe (real GL + stdout)")
    ap.add_argument("--project", default=str(DEFAULT_PROJECT), help="the godot/ project dir")
    ap.add_argument("--out", default="res://artifacts/smoketest.png", help="frame PNG output (res://)")
    ap.add_argument("--json", dest="json_out", default="res://artifacts/smoketest.json", help="verdict JSON (res://)")
    ap.add_argument("--settle", type=int, default=90, help="frames to wait before capture")
    ap.add_argument("--drive-method", default="", help="optional no-arg method to pump each frame")
    ap.add_argument("--keep-cache", action="store_true", help="do NOT clear the class cache (test a warm launch)")
    ap.add_argument("--timeout", type=int, default=90, help="seconds before killing the launch")
    ap.add_argument("--raw", action="store_true", help="also print the full Godot log")
    args = ap.parse_args()

    project = Path(args.project)
    cache = project / ".godot" / "global_script_class_cache.cfg"
    cache_note = "kept"
    if not args.keep_cache and cache.exists():
        try:
            cache.unlink()
            cache_note = "cleared (cold launch)"
        except OSError as e:
            cache_note = f"could not clear: {e}"

    def res_to_fs(res_path: str) -> Path:
        return project / res_path.replace("res://", "", 1)

    json_fs = res_to_fs(args.json_out)
    # stale-verdict guard: remove any prior verdict so we never read a previous run's result.
    if json_fs.exists():
        try:
            json_fs.unlink()
        except OSError:
            pass

    cmd = [
        args.godot, "--path", str(project),
        "-s", "res://tools/scene_smoketest.gd", "--",
        "--scene", args.scene, "--out", args.out, "--json", args.json_out,
        "--settle", str(args.settle),
    ]
    if args.drive_method:
        cmd += ["--drive-method", args.drive_method]

    log = ""
    timed_out = False
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=args.timeout,
                              encoding="utf-8", errors="replace")
        log = (proc.stdout or "") + "\n" + (proc.stderr or "")
    except subprocess.TimeoutExpired as e:
        timed_out = True
        log = ((e.stdout or "") if isinstance(e.stdout, str) else "") + \
              ((e.stderr or "") if isinstance(e.stderr, str) else "")

    if args.raw:
        print(log)

    # parse-error scan (independent of the frame — this is what a grey screen emits to the log)
    parse_hits = []
    for pat in PARSE_ERROR_PATTERNS:
        for m in re.finditer(pat + r".*", log):
            line = m.group(0).strip()
            if line and line not in parse_hits:
                parse_hits.append(line)
    parse_hits = parse_hits[:12]

    # read the verdict FILE (primary), fall back to the SMOKETEST_JSON: stdout line
    verdict = None
    if json_fs.exists():
        try:
            verdict = json.loads(json_fs.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            verdict = None
    if verdict is None:
        m = re.search(r"SMOKETEST_JSON:(\{.*\})", log)
        if m:
            try:
                verdict = json.loads(m.group(1))
            except json.JSONDecodeError:
                verdict = None

    reasons = list(verdict["reasons"]) if verdict and verdict.get("reasons") else []
    if verdict is None:
        reasons.append("no verdict produced (Godot crashed, timed out, or never reached capture)")
    if timed_out:
        reasons.append(f"launch timed out after {args.timeout}s (scene never self-quit)")
    if parse_hits:
        reasons.append(f"{len(parse_hits)} parse-error line(s) in log (grey-screen signal)")

    passed = (verdict is not None) and bool(verdict.get("pass")) and not parse_hits and not timed_out

    result = {
        "scene": args.scene,
        "pass": passed,
        "reasons": reasons,
        "cache": cache_note,
        "parse_errors": parse_hits,
        "verdict": verdict,
    }
    print("=" * 72)
    print(f"SCENE SMOKETEST  {args.scene}")
    print(f"  cache:   {cache_note}")
    if verdict:
        print(f"  struct:  {verdict.get('structural')}")
        print(f"  pixels:  {verdict.get('pixels')}")
        print(f"  frame:   {verdict.get('frame_png')}")
    if parse_hits:
        print("  parse errors:")
        for h in parse_hits[:6]:
            print(f"    - {h}")
    print("-" * 72)
    print(("RESULT: PASS ✓" if passed else "RESULT: FAIL ✗"))
    for r in reasons:
        print(f"    · {r}")
    print("=" * 72)
    # also emit a single machine-readable line
    print("SMOKETEST_RESULT:" + json.dumps(result))
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
