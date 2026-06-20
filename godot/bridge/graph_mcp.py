#!/usr/bin/env python3
"""graph_mcp — the local stdio MCP server that lets Claude (Claude Code now; the SAME core
runs over Streamable HTTP for the web/Cowork connector later) cowork inside the conversation/
idea graph. NO Anthropic API key: an MCP server is authorized by the client's existing Claude
session/subscription, never a key.

Successor to scene_bridge.py (same tiny, stdlib-plus-mcp, atomic-write, live/-dir shape). It
operates ENTIRELY on the canonical arrangement.json — the same file the running Godot game
hotloads — so edits appear live and every renderer stays a dumb delegate. ALL mutations are
APPROVAL-GATED via propose-then-commit: write tools never touch arrangement.json; they stage a
proposal (with a preview) that a separate graph_commit applies. Read tools are side-effect free.

Run (stdio, for Claude Code):
    python godot/bridge/graph_mcp.py [--live-dir <path>]
Register in Claude Code (no key):
    claude mcp add --transport stdio resonance-graph -- python <abs path to this file>
Later, the same server over the network for web/Cowork (Phase F):
    python godot/bridge/graph_mcp.py --transport streamable-http   (behind OAuth + HTTPS)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import time

from mcp.server.fastmcp import FastMCP

import convo_protocol as cp
import chip_ops
import graph_store as gs

LIVE_DIR = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "live"))

mcp = FastMCP("resonance-graph")


# --- arrangement + proposal storage --------------------------------------------------------
# The canonical store ops — read, hash, and the CONFLICT-SAFE write — live in graph_store, the
# importable CONNECTION-CONTRACT seam every transport shares (the engine canvas + remote import
# the SAME module so no two writers clobber). These thin wrappers just bind this server's LIVE_DIR.

def _arr_path() -> str:
    return gs.arr_path(LIVE_DIR)


def _props_dir() -> str:
    return os.path.join(LIVE_DIR, "proposals")


def _load() -> dict:
    return gs.load(LIVE_DIR)


def _save(arr: dict) -> None:
    gs.save(LIVE_DIR, arr)


def _live_hash() -> str:
    return gs.live_hash(LIVE_DIR)


def _counts(arr: dict) -> dict:
    return {"nodes": len(arr.get("nodes", [])), "wires": len(arr.get("wires", [])),
            "chips": sum(1 for n in arr.get("nodes", []) if str(n.get("type")) == "Chip")}


def _snippet(n: dict, length: int = 60) -> str:
    p = n.get("params", {})
    t = " ".join(str(p.get("title") or p.get("content", "")).split())
    return t[:length] + ("…" if len(t) > length else "")


def _stage(kind: str, payload: dict, summary: str) -> dict:
    """Persist a proposal record. `payload` carries the conflict-safe fields — `base_hash` plus the
    DELTA to re-apply (`actions` for an action batch, `args` for a structural op) — and a `result`
    PREVIEW. Commit re-derives from the CURRENT live arrangement; the stored result is for display
    only (graph_list_proposals)."""
    pid = "prop_" + hashlib.sha256(
        (kind + json.dumps(payload, sort_keys=True, default=str)).encode("utf-8")).hexdigest()[:8]
    rec = {"id": pid, "kind": kind, "summary": summary, **payload}
    gs.atomic_write(os.path.join(_props_dir(), pid + ".json"),
                    json.dumps(rec, indent="\t").encode("utf-8"))
    return {"proposal_id": pid, "kind": kind, "summary": summary}


# --- READ tools (side-effect free) ---------------------------------------------------------

@mcp.tool()
def graph_read() -> dict:
    """Overview of the current conversation/idea graph: counts, the active tip (current_node),
    and a compact node list (id, role, snippet). Start here, then graph_get_subgraph or
    graph_assemble_context for detail. Read-only."""
    arr = _load()
    nodes = [{"id": str(n.get("id")), "type": str(n.get("type")),
              "role": str(n.get("params", {}).get("role", "")), "snippet": _snippet(n)}
             for n in arr.get("nodes", [])]
    return {"counts": _counts(arr), "current_node": arr.get("current_node"), "nodes": nodes}


@mcp.tool()
def graph_get_subgraph(node_id: str, depth: int = 6) -> dict:
    """The ancestor subgraph of node_id up to `depth` levels (the thread leading to it), as
    {nodes, wires}. Depth-limited to stay within context budgets. Read-only."""
    arr = _load()
    keep = {node_id}
    frontier = [node_id]
    for _ in range(max(depth, 0)):
        nxt = []
        for nid in frontier:
            for p in cp.parents_of(arr, nid):
                if p not in keep:
                    keep.add(p)
                    nxt.append(p)
        frontier = nxt
        if not frontier:
            break
    nodes = [n for n in arr.get("nodes", []) if str(n.get("id")) in keep]
    wires = [w for w in arr.get("wires", [])
             if str(w.get("from")) in keep and str(w.get("to")) in keep]
    return {"format": arr.get("format", "resonance.arrangement/v1"), "nodes": nodes, "wires": wires}


@mcp.tool()
def graph_assemble_context(node_ids: list[str], fmt: str = "messages") -> dict:
    """Assemble LLM context from selected node id(s): the de-duplicated, created_at-ordered
    union of their ancestors + themselves. fmt='messages' -> role/content array (a linear
    thread / merge); fmt='xml' -> an <idea_graph> structure block. This is the 'send a whole
    structure to Claude' operation. Read-only."""
    arr = _load()
    if fmt == "xml":
        return {"format": "xml", "context": cp.to_xml(arr, node_ids)}
    return {"format": "messages", "context": cp.to_messages(arr, node_ids)}


@mcp.tool()
def graph_find(query: str) -> list[dict]:
    """Find nodes whose role/title/content contains `query` (case-insensitive). Read-only."""
    arr = _load()
    q = query.lower()
    hits = []
    for n in arr.get("nodes", []):
        p = n.get("params", {})
        hay = " ".join([str(p.get("role", "")), str(p.get("title", "")), str(p.get("content", ""))]).lower()
        if q in hay:
            hits.append({"id": str(n.get("id")), "role": str(p.get("role", "")), "snippet": _snippet(n)})
    return hits


@mcp.tool()
def graph_validate() -> dict:
    """Structural soundness of the live graph — delegates to the shared
    convo_protocol.validate_arrangement (the ONE definition the engine + every transport use):
    every wire endpoint exists; the active tip exists. Reports dangling wires + counts. Read-only."""
    return cp.validate_arrangement(_load())


# --- PROPOSE tools (stage only; never write arrangement.json) -------------------------------

@mcp.tool()
def graph_propose(actions: list) -> dict:
    """Stage typed graph actions as an APPROVAL-GATED proposal (does NOT apply). This ONE DSL
    is how Claude builds anything in the graph — messages, ideas, diagrams, images, structure —
    so there is no sprawl of bespoke add_* tools.

    actions: a JSON array of {op,...}:
      - add_node {kind:'Message', params:{role, content, author?, created_at?}, parent?}
        Roles include: 'user'/'assistant'/'system' (chat), 'idea'/'note' (your own structure),
        'diagram' (params also: diagram_kind 'svg'|'mermaid'|'dot'|'plantuml'|'d2'|'excalidraw'|
        'tldraw'; content = the diagram SOURCE you author as text — no image API/key needed, a
        renderer rasterizes it later), 'image' (params also: image_kind 'svg'|'url'|'ref';
        content = the SVG/url/ref). created_at is stamped for you if omitted.
      - wire {from, out:'reply', to, in:'parent'}
      - set_active_tip {node}
    Returns proposal_id + summary; call graph_commit to apply or graph_discard to drop."""
    arr = _load()
    v = cp.validate_actions(arr, actions)
    if v["errors"]:
        return {"ok": False, "errors": v["errors"]}
    # Server convenience: stamp a monotonic created_at on add_node actions that omit one, so
    # the linear projection stays ordered without burdening the model (keeps the pure protocol
    # time-free). A per-batch offset disambiguates several adds in one proposal.
    now = int(time.time() * 1000)
    offset = 0
    for a in v["actions"]:
        if str(a.get("op")) == "add_node":
            params = a.setdefault("params", {})
            if "created_at" not in params:
                params["created_at"] = now + offset
                offset += 1
    result = cp.apply(arr, v["actions"])
    before, after = _counts(arr), _counts(result)
    summary = f"+{after['nodes'] - before['nodes']} nodes, +{after['wires'] - before['wires']} wires"
    return {"ok": True, **_stage(
        "actions", {"base_hash": _live_hash(), "actions": v["actions"], "result": result}, summary)}


@mcp.tool()
def graph_propose_abstract(node_ids: list[str]) -> dict:
    """Stage a proposal to ABSTRACT (fold) the selected nodes into one Chip — a reusable
    sub-graph you can later open. Approval-gated; does NOT apply. Returns proposal_id."""
    arr = _load()
    result = chip_ops.group(arr, node_ids)
    return {"ok": True, **_stage(
        "abstract", {"base_hash": _live_hash(), "args": {"node_ids": node_ids}, "result": result},
        f"abstract {len(node_ids)} nodes into 1 Chip")}


@mcp.tool()
def graph_propose_decompose(chip_id: str) -> dict:
    """Stage a proposal to DECOMPOSE (open) a Chip back into its inner nodes/wires.
    Approval-gated; does NOT apply. Returns proposal_id."""
    arr = _load()
    result = chip_ops.ungroup(arr, chip_id)
    return {"ok": True, **_stage(
        "decompose", {"base_hash": _live_hash(), "args": {"chip_id": chip_id}, "result": result},
        f"decompose Chip {chip_id}")}


# --- COMMIT / manage proposals (the gate's second half) ------------------------------------

@mcp.tool()
def graph_list_proposals() -> list[dict]:
    """List staged (uncommitted) proposals. Read-only."""
    d = _props_dir()
    out = []
    if os.path.isdir(d):
        for fn in sorted(os.listdir(d)):
            if not fn.endswith(".json"):
                continue
            try:
                with open(os.path.join(d, fn), "r", encoding="utf-8") as f:
                    p = json.load(f)
                out.append({"proposal_id": p.get("id"), "kind": p.get("kind"), "summary": p.get("summary")})
            except (json.JSONDecodeError, OSError):
                pass
    return out


@mcp.tool()
def graph_commit(proposal_id: str) -> dict:
    """Apply a staged proposal to the live arrangement — the CONFLICT-SAFE commit half of the gate
    (atomic write; the running game hotloads it). Instead of blindly writing a result computed at
    propose time, it RE-DERIVES against the CURRENT live arrangement so a concurrent edit by another
    system is never clobbered:
      • action batches      — re-validate + re-apply (append-only) onto the current graph, then
        soundness-check. Concurrent adds rebase cleanly; if a referenced node was concurrently
        removed the commit is REJECTED rather than corrupting the graph. The only true conflict
        (set_active_tip vs set_active_tip) is last-writer-wins.
      • abstract/decompose  — structural, so they require an unchanged base: if the graph moved since
        the proposal, the commit is REJECTED with a re-propose hint.
    Returns {ok, committed, counts, rebased} or {ok:False, error[, errors]}."""
    fp = os.path.join(_props_dir(), proposal_id + ".json")
    if not os.path.exists(fp):
        return {"ok": False, "error": f"no such proposal '{proposal_id}'"}
    with open(fp, "r", encoding="utf-8") as f:
        prop = json.load(f)
    kind = str(prop.get("kind"))
    rebased = prop.get("base_hash") != _live_hash()

    if kind == "actions":
        # The conflict-safe append-only write lives in the shared seam (graph_store): reload the
        # CURRENT graph, re-validate, re-apply, soundness-check, atomic-write — the SAME path every
        # transport uses, so concurrent edits rebase rather than clobber.
        res = gs.commit_actions(LIVE_DIR, prop.get("actions", []))
        if not res["ok"]:
            out = {"ok": False, "error": res.get("error", "could not commit to the current graph")}
            if "errors" in res:
                out["errors"] = res["errors"]
            if "sound" in res:
                out["sound"] = res["sound"]
            return out
        os.remove(fp)
        return {"ok": True, "committed": proposal_id, "counts": _counts(res["result"]), "rebased": rebased}

    if kind in ("abstract", "decompose"):
        if rebased:
            return {"ok": False, "error": "graph changed since this structural proposal — re-propose"}
        current = _load()
        args = prop.get("args", {})
        result = (chip_ops.group(current, args.get("node_ids", []))
                  if kind == "abstract" else chip_ops.ungroup(current, args.get("chip_id", "")))
        sound = cp.validate_arrangement(result)
        if not sound["ok"]:
            return {"ok": False, "error": "refusing to commit: result is not sound", **sound}
        _save(result)
        os.remove(fp)
        return {"ok": True, "committed": proposal_id, "counts": _counts(result), "rebased": rebased}

    return {"ok": False, "error": f"unknown proposal kind '{kind}'"}


@mcp.tool()
def graph_discard(proposal_id: str) -> dict:
    """Discard a staged proposal without applying it."""
    fp = os.path.join(_props_dir(), proposal_id + ".json")
    if os.path.exists(fp):
        os.remove(fp)
        return {"ok": True, "discarded": proposal_id}
    return {"ok": False, "error": f"no such proposal '{proposal_id}'"}


def main() -> None:
    global LIVE_DIR
    ap = argparse.ArgumentParser()
    ap.add_argument("--live-dir", default=LIVE_DIR)
    ap.add_argument("--transport", default="stdio", choices=["stdio", "sse", "streamable-http"])
    args = ap.parse_args()
    LIVE_DIR = os.path.abspath(args.live_dir)
    os.makedirs(LIVE_DIR, exist_ok=True)
    mcp.run(transport=args.transport)


if __name__ == "__main__":
    main()
