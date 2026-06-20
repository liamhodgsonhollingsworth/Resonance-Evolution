#!/usr/bin/env python3
"""Parity tests for the Python protocol port (convo_protocol.py + chip_ops.py).

Mirrors godot/headless_convo_test.gd and headless_chip_test.gd so the engine (GDScript) and the
Claude-facing transports (Python: MCP server, copy-paste bridge, future web/connector) agree
over the SAME canonical arrangement data. Pure stdlib — no mcp dependency.

Run:  python godot/bridge/test_graph_logic.py
"""
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import convo_protocol as cp  # noqa: E402
import chip_ops  # noqa: E402

ok = True


def check(label: str, cond: bool) -> None:
    global ok
    print(("PASS " if cond else "FAIL ") + label)
    ok = ok and bool(cond)


def msg(i, role, content, ca):
    return {"id": i, "type": "Message",
            "params": {"role": role, "content": content, "author": "", "created_at": ca}}


def wire(a, b):
    return {"from": a, "out": "reply", "to": b, "in": "parent"}


# --- ConvoProtocol parity (mirrors headless_convo_test.gd) ---------------------------------
convo = {
    "format": "resonance.arrangement/v1", "current_node": "n3",
    "nodes": [msg("n1", "system", "You are helpful", 1), msg("n2", "user", "Hello", 2),
              msg("n3", "assistant", "Hi!", 3), msg("n4", "user", "Actually, reframe", 4),
              msg("n5", "user", "combine", 5)],
    "wires": [wire("n1", "n2"), wire("n2", "n3"), wire("n2", "n4"),
              wire("n3", "n5"), wire("n4", "n5")],
}

check("merge n5 has 2 parents", len(cp.parents_of(convo, "n5")) == 2)
c3 = cp.to_messages(convo, ["n3"])
check("path to n3 => [system,user,assistant]", [m["role"] for m in c3] == ["system", "user", "assistant"])
c5 = cp.to_messages(convo, ["n5"])
check("merge n5 dedups to 5 in order",
      len(c5) == 5 and c5[0]["content"] == "You are helpful" and c5[4]["content"] == "combine")
c4 = cp.to_messages(convo, ["n4"])
check("branch n4 distinct thread", len(c4) == 3 and c4[2]["content"] == "Actually, reframe")
xml = cp.to_xml(convo, ["n5"], "Summarize.")
check("xml has graph + roles + question",
      "<idea_graph>" in xml and "Summarize." in xml and 'role="assistant"' in xml)
interp = cp.interpret_reply(
    'x\n```resonance-actions\n[{"op":"add_node","kind":"Message",'
    '"params":{"role":"assistant","content":"f","created_at":6},"parent":"n5"},{"op":"bogus"}]\n```\n')
check("interpret: 1 valid + 1 error", len(interp["actions"]) == 1 and len(interp["errors"]) == 1)
applied = cp.apply(convo, interp["actions"])
check("apply append-only + new node + wire",
      len(convo["nodes"]) == 5 and len(applied["nodes"]) == 6 and len(applied["wires"]) == 6)
applied2 = cp.apply(convo, [{"op": "set_active_tip", "node": "n4"}])
check("set_active_tip", applied2.get("current_node") == "n4")

# --- Hardened validation: the structural gate (mirrors headless_convo_test.gd) -------------
# validate_actions simulates the batch against the arrangement; known ids = {n1..n5}.
val_ok = cp.validate_actions(convo, [
    {"op": "add_node", "kind": "Message", "params": {"role": "user", "content": "hi"}, "parent": "n5"},
    {"op": "wire", "from": "n3", "to": "n4"},
    {"op": "set_active_tip", "node": "n4"},
])
check("validate_actions accepts a sound batch", len(val_ok["actions"]) == 3 and not val_ok["errors"])

bad = cp.validate_actions(convo, [
    {"op": "add_node", "kind": "Message", "params": {"role": "user", "content": "x"}, "parent": "ghost"},
    {"op": "wire", "from": "n1", "to": "nope"},
    {"op": "wire", "from": "n2", "to": "n2"},
    {"op": "set_active_tip", "node": "missing"},
    {"op": "add_node", "kind": "Message", "params": {"content": "no role"}},
    {"op": "bogus"},
])
check("validate_actions rejects parent/endpoint/self/tip/role/op (6 errors, 0 valid)",
      len(bad["actions"]) == 0 and len(bad["errors"]) == 6)

batch = cp.validate_actions(convo, [
    {"op": "add_node", "id": "fresh", "kind": "Message", "params": {"role": "user", "content": "a"}, "parent": "n5"},
    {"op": "wire", "from": "fresh", "to": "n5"},
])
check("validate_actions resolves batch-local ids (added node referenceable later)",
      len(batch["actions"]) == 2 and not batch["errors"])

# validate_arrangement soundness.
check("validate_arrangement: clean convo is ok", cp.validate_arrangement(convo)["ok"])
broken = {"format": "resonance.arrangement/v1", "current_node": "ghost",
          "nodes": [msg("a", "user", "x", 1)],
          "wires": [{"from": "a", "out": "reply", "to": "missing", "in": "parent"}]}
bsound = cp.validate_arrangement(broken)
check("validate_arrangement flags dangling wire + missing tip",
      not bsound["ok"] and len(bsound["dangling_wires"]) == 1 and not bsound["active_tip_exists"])

# --- ChipOps parity (mirrors headless_chip_test.gd) ---------------------------------------
base = {
    "format": "resonance.arrangement/v1",
    "nodes": [{"id": "a", "type": "Const", "params": {"value": 3}},
              {"id": "b", "type": "Const", "params": {"value": 4}},
              {"id": "m", "type": "Math", "params": {"op": "add"}},
              {"id": "out", "type": "Log", "params": {}}],
    "wires": [{"from": "a", "out": "value", "to": "m", "in": "a"},
              {"from": "b", "out": "value", "to": "m", "in": "b"},
              {"from": "m", "out": "result", "to": "out", "in": "in"}],
}
g = chip_ops.group(base, ["a", "b", "m"])
check("group => 1 Chip + Log (2 nodes)",
      len(g["nodes"]) == 2 and sum(1 for n in g["nodes"] if n["type"] == "Chip") == 1)
chip = next(n for n in g["nodes"] if n["type"] == "Chip")
check("chip [a,b,m] has 0 inputs, 1 output",
      len(chip["params"]["ports"]["inputs"]) == 0 and len(chip["params"]["ports"]["outputs"]) == 1)
g2 = chip_ops.group(base, ["m"])
chip2 = next(n for n in g2["nodes"] if n["type"] == "Chip")
check("group [m] chip has 2 inputs, 1 output",
      len(chip2["params"]["ports"]["inputs"]) == 2 and len(chip2["params"]["ports"]["outputs"]) == 1)
u = chip_ops.ungroup(g, chip["id"])
check("ungroup restores 4 nodes, 0 chips",
      len(u["nodes"]) == 4 and sum(1 for n in u["nodes"] if n["type"] == "Chip") == 0)


def sig(arr):
    nids = sorted(str(n["id"]) for n in arr["nodes"])
    ws = sorted((w["from"], w["out"], w["to"], w["in"]) for w in arr["wires"])
    return (nids, ws)


check("group->ungroup restores structure (lossless round-trip)", sig(u) == sig(base))
check("group is append-only (base unchanged)", len(base["nodes"]) == 4)

print("RESULT:", "ALL PASS" if ok else "FAILURES PRESENT")
sys.exit(0 if ok else 1)
