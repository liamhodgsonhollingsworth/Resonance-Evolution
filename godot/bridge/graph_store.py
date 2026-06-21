#!/usr/bin/env python3
"""graph_store — the shared, conflict-safe STORE seam over live/arrangement.json.

The connection contract (godot/CONNECTION-CONTRACT.md) as IMPORTABLE code: one place that owns
reading, hashing, and CONFLICT-SAFELY writing the canonical arrangement. Every transport — the
stdio MCP (graph_mcp.py), the 2D-canvas bridge (canvas_bridge.py), the future remote/Cowork
connector — imports this so they validate + write identically and never clobber each other. The
alternative (each transport doing its own _load/_save) is exactly the cross-process clobber bug
this seam exists to remove: an in-process lock protects one server's threads, not two servers
editing the same file.

Stdlib only (mirrors scene_bridge.py); imports the convo_protocol parity port for the pure
validate/apply logic. No engine, network, or Anthropic-key dependency.
"""
from __future__ import annotations

import hashlib
import json
import os
import time

import convo_protocol as cp

FORMAT = "resonance.arrangement/v1"


def arr_path(live_dir: str) -> str:
    return os.path.join(live_dir, "arrangement.json")


def empty() -> dict:
    return {"format": FORMAT, "nodes": [], "wires": []}


def load(live_dir: str) -> dict:
    """Read the live arrangement, or an empty one if absent/corrupt (never raises)."""
    p = arr_path(live_dir)
    if not os.path.exists(p):
        return empty()
    try:
        with open(p, "r", encoding="utf-8") as f:
            data = json.load(f)
        return data if isinstance(data, dict) else empty()
    except (json.JSONDecodeError, OSError):
        return empty()


def atomic_write(path: str, data: bytes) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    os.replace(tmp, path)


def save(live_dir: str, arr: dict) -> dict:
    """Atomic write of the arrangement, stamping a MONOTONIC `rev` (+ `updated_at` ms) — the single
    write chokepoint, so every writer that goes through the seam advances one shared version counter.
    rev = max(current on-disk rev, the arr's rev) + 1, so it never goes backwards even across
    concurrent writers. Returns the stamped arrangement (a copy; the caller's dict is untouched), so
    callers can read the new rev without re-reading the file."""
    prev_rev = int(load(live_dir).get("rev", 0) or 0)
    stamped = dict(arr)
    stamped["rev"] = max(prev_rev, int(arr.get("rev", 0) or 0)) + 1
    stamped["updated_at"] = int(time.time() * 1000)
    atomic_write(arr_path(live_dir), json.dumps(stamped, indent="\t").encode("utf-8"))
    return stamped


def live_hash(live_dir: str) -> str:
    """Content hash of the live file's raw bytes — the change signal the engine's LiveHost watches
    and the conflict-safe base every proposal records."""
    p = arr_path(live_dir)
    if not os.path.exists(p):
        return ""
    with open(p, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest()


def commit_actions(live_dir: str, actions: list) -> dict:
    """THE conflict-safe append-only write — the single correct way for any writer to land
    agent/Claude contributions. Reloads the CURRENT live arrangement (so a concurrent edit by
    another system is never clobbered), structurally validates the actions against it, applies them
    (append-only), soundness-checks the result, then atomic-writes. Returns
    {"ok": True, "result", "counts"} or {"ok": False, "error", "errors"|"sound"} — and on failure
    writes NOTHING."""
    current = load(live_dir)
    v = cp.validate_actions(current, actions)
    if v["errors"]:
        return {"ok": False, "error": "actions do not apply to the current graph", "errors": v["errors"]}
    result = cp.apply(current, v["actions"])
    sound = cp.validate_arrangement(result)
    if not sound["ok"]:
        return {"ok": False, "error": "result is not sound", "sound": sound}
    result = save(live_dir, result)  # stamps + returns the new rev/updated_at
    return {"ok": True, "result": result, "rev": result.get("rev"),
            "counts": {"nodes": len(result.get("nodes", [])), "wires": len(result.get("wires", []))}}
