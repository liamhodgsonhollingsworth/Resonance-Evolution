#!/usr/bin/env python3
"""Sync / conflict-safety tests for the connection fabric (Track 1).

Drives the REAL graph_mcp tools (graph_propose / graph_commit / graph_validate / ...) against a
throwaway live dir, simulating TWO systems editing the same arrangement.json concurrently. Proves
the conflict-safe (rebasing) commit: a proposal computed against one state still applies cleanly
after another writer has changed the file, and neither writer's edit is lost. This is the
data-layer proof of the handoff's "two systems edit the same arrangement, robustly".

Run:  python godot/bridge/test_sync_logic.py     (needs the `mcp` package, same as the server)
"""
import os
import shutil
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import graph_mcp as g  # noqa: E402

ok = True


def check(label: str, cond: bool) -> None:
    global ok
    print(("PASS " if cond else "FAIL ") + label)
    ok = ok and bool(cond)


def reset(arr: dict) -> None:
    """Clear staged proposals and seed the live arrangement (a fresh shared graph)."""
    pd = g._props_dir()
    if os.path.isdir(pd):
        shutil.rmtree(pd)
    g._save(arr)


def ids() -> set:
    return {str(n.get("id")) for n in g._load().get("nodes", [])}


def msg(i, role="user", content="", ca=1):
    return {"id": i, "type": "Message", "params": {"role": role, "content": content, "created_at": ca}}


tmp = tempfile.mkdtemp(prefix="resonance_sync_")
g.LIVE_DIR = tmp  # redirect every file op in graph_mcp to the throwaway dir

try:
    base = {"format": "resonance.arrangement/v1", "nodes": [msg("root", "user", "root")], "wires": []}

    # 1) CONFLICT-SAFE REBASE: propose against {root}; a second system commits child_b in between;
    #    committing the proposal must NOT clobber child_b — both children + root survive.
    reset(base)
    p = g.graph_propose([{"op": "add_node", "id": "child_a", "kind": "Message",
                          "params": {"role": "assistant", "content": "A"}, "parent": "root"}])
    check("propose A staged", bool(p.get("ok")) and "proposal_id" in p)
    ext = g._load()  # the "other system" appends child_b directly to the live file
    ext["nodes"].append(msg("child_b", "assistant", "B", 2))
    ext["wires"].append({"from": "root", "out": "reply", "to": "child_b", "in": "parent"})
    g._save(ext)
    c = g.graph_commit(p["proposal_id"])
    check("commit A succeeds and reports rebased", bool(c.get("ok")) and c.get("rebased") is True)
    check("no clobber: root + child_a + child_b all present", {"root", "child_a", "child_b"} <= ids())
    check("graph still sound after rebase", g.graph_validate()["ok"])

    # 2) REJECT-ON-CORRUPTION: if the referenced parent was concurrently removed, commit must fail
    #    (not corrupt the graph) and leave the proposal staged for re-proposal.
    reset(base)
    p2 = g.graph_propose([{"op": "add_node", "id": "c", "kind": "Message",
                           "params": {"role": "user", "content": "x"}, "parent": "root"}])
    g._save({"format": "resonance.arrangement/v1", "nodes": [], "wires": []})  # other system deletes root
    c2 = g.graph_commit(p2["proposal_id"])
    check("commit rejected when parent concurrently removed", not c2.get("ok") and "errors" in c2)
    staged = [pp["proposal_id"] for pp in g.graph_list_proposals()]
    check("rejected proposal stays staged (not consumed)", p2["proposal_id"] in staged)

    # 3) PROPOSE-TIME VALIDATION: a structurally invalid edit never even stages.
    reset(base)
    p3 = g.graph_propose([{"op": "wire", "from": "root", "to": "ghost"}])
    check("propose rejects a dangling wire up front", not p3.get("ok") and bool(p3.get("errors")))
    check("nothing staged from a rejected propose", not g.graph_list_proposals())

    # 4) CLEAN COMMIT: no concurrent change -> applies, rebased == False.
    reset(base)
    p4 = g.graph_propose([{"op": "add_node", "id": "d", "kind": "Message",
                           "params": {"role": "user", "content": "d"}, "parent": "root"}])
    c4 = g.graph_commit(p4["proposal_id"])
    check("clean commit succeeds, not rebased", bool(c4.get("ok")) and c4.get("rebased") is False)
    check("clean commit applied the node", "d" in ids())

    # 5) STRUCTURAL OP BASE-CHECK: an abstract proposal requires an unchanged base.
    base2 = {"format": "resonance.arrangement/v1",
             "nodes": [{"id": "a", "type": "Const", "params": {"value": 3}},
                       {"id": "b", "type": "Const", "params": {"value": 4}}],
             "wires": []}
    reset(base2)
    pa = g.graph_propose_abstract(["a", "b"])
    check("propose_abstract staged", bool(pa.get("ok")))
    ext2 = g._load()  # other system changes the file after the structural proposal
    ext2["nodes"].append({"id": "z", "type": "Const", "params": {"value": 9}})
    g._save(ext2)
    ca = g.graph_commit(pa["proposal_id"])
    check("abstract commit rejected after concurrent change", not ca.get("ok") and "re-propose" in str(ca.get("error", "")))

    # 6) STRUCTURAL OP, UNCHANGED BASE: abstract commits and yields a Chip.
    reset(base2)
    pa2 = g.graph_propose_abstract(["a", "b"])
    ca2 = g.graph_commit(pa2["proposal_id"])
    check("abstract commit ok with unchanged base", bool(ca2.get("ok")))
    check("abstract produced a Chip", any(n.get("type") == "Chip" for n in g._load().get("nodes", [])))
finally:
    shutil.rmtree(tmp, ignore_errors=True)

print("RESULT:", "ALL PASS" if ok else "FAILURES PRESENT")
sys.exit(0 if ok else 1)
