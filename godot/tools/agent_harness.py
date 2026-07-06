#!/usr/bin/env python3
"""Thin python wrapper around the Godot agent harness (tools/agent_harness.gd).

An agent calls THIS, not Godot directly: it launches the headless driver, captures Godot's log,
greps the one machine-readable line the driver prints ("HARNESS_JSON:<json>"), parses it, and
returns / prints the JSON. This is the text-equivalent entry point for driving + VERIFYING the game
with no human and no GUI (Liam 2026-07-05 item 4).

USAGE (from anywhere):
    py -3 godot/tools/agent_harness.py --scene res://aperture/aperture_board_2d.tscn \
        --config '<json>' --cmds '<json>'            # inline JSON command(s)
    py -3 godot/tools/agent_harness.py --scene ... --cmds-file cmds.json
    py -3 godot/tools/agent_harness.py --scene ... --cmd ui_dump
    py -3 godot/tools/agent_harness.py --scene ... --cmd ui_click --arg 'target={"text":"✕"}'

Anything after the recognised flags is forwarded verbatim to the Godot driver, so every driver flag
(--view WxH, --out path, etc.) works here too. Exit code mirrors the harness result (0 = all PASS).

Defaults: GODOT env var, else the known console exe on this host; RE godot project auto-detected
relative to this file. Override with --godot / --project.
"""
import argparse
import json
import os
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve()
DEFAULT_PROJECT = HERE.parents[1]  # <re>/godot
DEFAULT_GODOT = os.environ.get(
    "GODOT",
    r"C:/Users/Liam/godot/Godot_v4.6.3-stable_win64_console.exe",
)
JSON_PREFIX = "HARNESS_JSON:"


def main() -> int:
    ap = argparse.ArgumentParser(description="Drive + verify the Godot game headlessly.")
    ap.add_argument("--godot", default=DEFAULT_GODOT, help="path to the Godot console exe")
    ap.add_argument("--project", default=str(DEFAULT_PROJECT), help="the godot/ project dir")
    ap.add_argument("--scene", default="", help="res:// scene to drive")
    ap.add_argument("--config", default="", help="inline JSON config (board substrate paths, etc.)")
    ap.add_argument("--cmds", default="", help="inline JSON: one command object or an array of them")
    ap.add_argument("--cmds-file", default="", help="a file holding the JSON command(s)")
    ap.add_argument("--cmd", default="", help="a single verb (with --arg k=v pairs)")
    ap.add_argument("--arg", action="append", default=[], help="k=v for a single --cmd (repeatable)")
    ap.add_argument("--view", default="", help="WxH host size for a Control scene (default 1600x1000)")
    ap.add_argument("--out", default="", help="screenshot output path")
    ap.add_argument("--raw", action="store_true", help="print Godot's full log too (debugging)")
    args = ap.parse_args()

    cmd = [args.godot, "--headless", "--path", args.project, "-s", "res://tools/agent_harness.gd", "--"]
    if args.scene:
        cmd += ["--scene", args.scene]
    if args.config:
        cmd += ["--config", args.config]
    if args.cmds:
        cmd += ["--cmds", args.cmds]
    if args.cmds_file:
        cmd += ["--cmds-file", args.cmds_file]
    if args.cmd:
        cmd += ["--cmd", args.cmd]
        for a in args.arg:
            cmd += ["--arg", a]
    if args.view:
        cmd += ["--view", args.view]
    if args.out:
        cmd += ["--out", args.out]

    proc = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8", errors="replace")
    log = (proc.stdout or "") + "\n" + (proc.stderr or "")
    if args.raw:
        sys.stderr.write(log)

    payload = None
    for line in log.splitlines():
        line = line.strip()
        if line.startswith(JSON_PREFIX):
            try:
                payload = json.loads(line[len(JSON_PREFIX):])
            except json.JSONDecodeError:
                pass  # keep the last parseable one

    if payload is None:
        print(json.dumps({"ok": False, "error": "no HARNESS_JSON line in Godot output",
                          "godot_exit": proc.returncode, "log_tail": log.splitlines()[-15:]}, indent=2))
        return 2

    print(json.dumps(payload, indent=2, ensure_ascii=False))
    return 0 if payload.get("ok", False) else 1


if __name__ == "__main__":
    raise SystemExit(main())
