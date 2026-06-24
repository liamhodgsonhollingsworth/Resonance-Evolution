"""convo_protocol — the graph<->text protocol, Python port.

Parity with godot/runtime/convo_protocol.gd: pure DATA in -> DATA / text out, no engine
dependency. The arrangement JSON ({format, nodes, wires, current_node?}) is the canonical
shared format; this module and the GDScript ConvoProtocol read the SAME data, so the engine
and every Claude-facing transport (MCP stdio/remote, copy-paste bridge, web UI) agree. Keep
the two in sync — godot/headless_convo_test.gd <-> godot/bridge/test_graph_logic.py check both.

A conversation edge is a wire A.reply -> B.parent. A node with several incoming parent wires
is a MERGE. Context = the de-duplicated union of selected nodes' ancestors (+ the nodes
themselves), ordered by created_at then id (ericmjl Canvas Chat's getAncestors/resolveContext).
"""
from __future__ import annotations

import copy
import hashlib
import json
from typing import Any

PARENT_PORT = "parent"
REPLY_PORT = "reply"
ACTIONS_TAG = "resonance-actions"
ALLOWED_OPS = ("add_node", "wire", "set_active_tip")


# --- FORWARD: graph -> context -------------------------------------------------------------

def parents_of(arr: dict, node_id: str) -> list[str]:
    """Direct parents of a node: the `from` of every wire (to==id, in==parent)."""
    return [str(w.get("from")) for w in arr.get("wires", [])
            if str(w.get("to")) == node_id and str(w.get("in")) == PARENT_PORT]


def ancestors(arr: dict, node_id: str) -> list[str]:
    """All ancestors of node_id (excluding it). DFS over parent wires, visited-set + cycle-safe."""
    seen: set[str] = set()
    stack: list[str] = list(parents_of(arr, node_id))
    result: list[str] = []
    while stack:
        p = stack.pop()
        if p in seen:
            continue
        seen.add(p)
        result.append(p)
        for gp in parents_of(arr, p):
            if gp not in seen:
                stack.append(gp)
    return result


def _index(arr: dict) -> dict[str, dict]:
    return {str(n.get("id")): n for n in arr.get("nodes", [])}


def _order_key(node: dict):
    ca = node.get("params", {}).get("created_at", 0)
    # Numbers (not bools) sort as numbers and before any string key; ties break by id. This is
    # a total order (the GDScript pairwise compare agrees for same-typed created_at, which is
    # the contract: keep created_at a consistent type within a conversation).
    if isinstance(ca, (int, float)) and not isinstance(ca, bool):
        return (0, float(ca), str(node.get("id")))
    return (1, str(ca), str(node.get("id")))


def context_nodes(arr: dict, selected: list[str]) -> list[dict]:
    """Context node SPECS for the selected ids: union of ancestors + the ids, deduped, ordered."""
    want: set[str] = set()
    for nid in selected:
        want.add(str(nid))
        want.update(ancestors(arr, str(nid)))
    by_id = _index(arr)
    picked = [by_id[nid] for nid in want if nid in by_id]
    picked.sort(key=_order_key)
    return picked


def to_messages(arr: dict, selected: list[str]) -> list[dict]:
    """Alternating-ish role/content array (linear projection). The API transport enforces
    first-is-user / role alternation and folds `system` into the system param."""
    return [{"role": str(n.get("params", {}).get("role", "user")),
             "content": str(n.get("params", {}).get("content", ""))}
            for n in context_nodes(arr, selected)]


def _esc(s: str) -> str:
    return (s.replace("&", "&amp;").replace("<", "&lt;")
             .replace(">", "&gt;").replace('"', "&quot;"))


def to_xml(arr: dict, selected: list[str], question: str = "") -> str:
    """Structure mode: an <idea_graph> block (context-at-top), optional question after."""
    ctx = context_nodes(arr, selected)
    ctx_ids = {str(n.get("id")) for n in ctx}
    lines = ["<idea_graph>"]
    for n in ctx:
        nid = str(n.get("id"))
        p = n.get("params", {})
        role = str(p.get("role", "user"))
        ps = [x for x in parents_of(arr, nid) if x in ctx_ids]
        pattr = f' parents="{",".join(ps)}"' if ps else ""
        lines.append(f'  <node id="{_esc(nid)}" role="{_esc(role)}"{pattr}>')
        lines.append(f'    <content>{_esc(str(p.get("content", "")))}</content>')
        lines.append("  </node>")
    lines.append("</idea_graph>")
    if question:
        lines += ["", question]
    return "\n".join(lines)


def to_prompt(arr: dict, selected: list[str], question: str = "") -> str:
    """The copy-paste bridge: text a user pastes into claude.ai — structure + question + the
    instruction telling Claude how to propose graph edits back (parsed by interpret_reply)."""
    instr = (
        f"\n\nIf you want to add to this idea graph, end your reply with a fenced "
        f"```{ACTIONS_TAG} block containing a JSON array of actions. "
        f'Allowed ops: add_node {{kind:"Message", params:{{role, content, author, created_at}}, '
        f'parent:"<node id>"}}; wire {{from, out:"reply", to, in:"parent"}}; set_active_tip {{node}}. '
        f"Reference existing nodes by their id; do not invent ids for existing nodes."
    )
    return to_xml(arr, selected, question) + instr


# --- BACKWARD: reply text -> graph actions -------------------------------------------------

def _extract_fenced(text: str, tag: str) -> str:
    fence = "```" + tag
    start = text.find(fence)
    if start == -1:
        return ""
    nl = text.find("\n", start + len(fence))
    if nl == -1:
        return ""
    end = text.find("```", nl + 1)
    if end == -1:
        return ""
    return text[nl + 1:end].strip()


def interpret_reply(text: str) -> dict:
    """Extract candidate actions from the resonance-actions JSON block in a reply: parse + the
    op-allowlist shape check. Returns {"actions": [...op-valid...], "errors": [...]}. NOTHING is
    applied — these are PROPOSALS, and the STRUCTURAL gate (validate_actions, against the live
    arrangement) is re-applied at propose AND commit, so every entry path validates identically."""
    block = _extract_fenced(text, ACTIONS_TAG)
    if not block:
        return {"actions": [], "errors": [f"no ```{ACTIONS_TAG} block found"]}
    try:
        parsed = json.loads(block)
    except json.JSONDecodeError as e:
        return {"actions": [], "errors": [f"{ACTIONS_TAG} block is not valid JSON: {e}"]}
    if not isinstance(parsed, list):
        return {"actions": [], "errors": [f"{ACTIONS_TAG} block is not a JSON array"]}
    actions, errors = [], []
    for a in parsed:
        if not isinstance(a, dict):
            errors.append(f"action is not an object: {a!r}")
            continue
        op = str(a.get("op", ""))
        if op not in ALLOWED_OPS:
            errors.append(f"unknown op '{op}' (allowed: {', '.join(ALLOWED_OPS)})")
            continue
        actions.append(a)
    return {"actions": actions, "errors": errors}


def _has_cycle(arr: dict) -> bool:
    """True if the parent graph (wires with in==parent) contains a cycle. A conversation/idea graph
    is a DAG — a cycle is corruption (and would make ancestor walks ill-defined). Iterative DFS with
    a three-colour marking (0 unvisited, 1 on-stack, 2 done) so deep graphs never overflow."""
    adj: dict[str, list[str]] = {}
    for w in arr.get("wires", []):
        if str(w.get("in")) == PARENT_PORT:
            adj.setdefault(str(w.get("from")), []).append(str(w.get("to")))
    color: dict[str, int] = {}
    for start in list(adj.keys()):
        if color.get(start, 0) != 0:
            continue
        stack = [(start, 0)]
        color[start] = 1
        while stack:
            u, i = stack[-1]
            nbrs = adj.get(u, [])
            if i < len(nbrs):
                stack[-1] = (u, i + 1)
                v = nbrs[i]
                cv = color.get(v, 0)
                if cv == 1:
                    return True
                if cv == 0:
                    color[v] = 1
                    stack.append((v, 0))
            else:
                color[u] = 2
                stack.pop()
    return False


def validate_actions(arr: dict, actions: list) -> dict:
    """The STRUCTURAL validation gate — the single definition every transport (MCP propose AND
    commit, the canvas, the remote) funnels mutations through. Simulates the batch against `arr`,
    tracking a running id-set (existing node ids + ids added earlier in the SAME batch), so it
    catches edits that would corrupt the shared graph BEFORE they are staged or applied.

    Rejects (with a clear message), per action:
      add_node       — empty `kind`; `params` not an object; a Message with no `role`; a `parent`
                       that is not a known id. (Unknown KINDS are allowed: the protocol is
                       engine-neutral + forward-compatible; new TYPES register in GraphRuntime.)
      wire           — missing `from`/`to`; self-wire (from == to); an endpoint that is not known.
      set_active_tip — missing `node`; a `node` that is not known.

    Returns {"actions": [...passing...], "errors": [...]}. A failed action does NOT enter the
    known-id set, so later actions that depend on it are flagged too (propose/commit reject on any
    error — partial application is never allowed)."""
    known = {str(n.get("id")) for n in arr.get("nodes", [])}
    out, errors = [], []
    for a in actions:
        if not isinstance(a, dict):
            errors.append(f"action is not an object: {a!r}")
            continue
        op = str(a.get("op", ""))
        if op not in ALLOWED_OPS:
            errors.append(f"unknown op '{op}' (allowed: {', '.join(ALLOWED_OPS)})")
            continue
        if op == "add_node":
            kind = str(a.get("kind", "Message"))
            if kind == "":
                errors.append("add_node: empty kind")
                continue
            params = a.get("params", {})
            if not isinstance(params, dict):
                errors.append("add_node: params must be an object")
                continue
            if kind == "Message" and str(params.get("role", "")) == "":
                errors.append("add_node: a Message needs a non-empty role")
                continue
            parent = a.get("parent")
            if parent is not None and str(parent) != "" and str(parent) not in known:
                errors.append(f"add_node: parent '{parent}' not found")
                continue
            known.add(str(a.get("id", _gen_id(a))))
            out.append(a)
        elif op == "wire":
            f, t = str(a.get("from", "")), str(a.get("to", ""))
            if f == "" or t == "":
                errors.append("wire: from and to are required")
                continue
            if f == t:
                errors.append(f"wire: self-wire not allowed ('{f}')")
                continue
            if f not in known:
                errors.append(f"wire: from '{f}' not found")
                continue
            if t not in known:
                errors.append(f"wire: to '{t}' not found")
                continue
            out.append(a)
        elif op == "set_active_tip":
            n = str(a.get("node", ""))
            if n == "":
                errors.append("set_active_tip: node is required")
                continue
            if n not in known:
                errors.append(f"set_active_tip: node '{n}' not found")
                continue
            out.append(a)
    # Whole-batch invariant: the parent graph must stay acyclic. (Skip if the batch is already
    # rejected — errors non-empty means nothing applies anyway.)
    if out and not errors and _has_cycle(apply(arr, out)):
        errors.append("batch would create a cycle in the parent graph")
    return {"actions": out, "errors": errors}


def validate_arrangement(arr: dict) -> dict:
    """SOUNDNESS check on a whole arrangement — the shared definition the engine, the MCP server,
    the canvas, and the remote all use (graph_mcp.graph_validate delegates here). Every wire
    endpoint must exist; current_node (if set) must exist. Returns
    {"ok", "counts": {nodes, wires}, "dangling_wires": [...], "active_tip_exists": bool}."""
    ids = {str(n.get("id")) for n in arr.get("nodes", [])}
    dangling = [w for w in arr.get("wires", [])
                if str(w.get("from")) not in ids or str(w.get("to")) not in ids]
    tip = arr.get("current_node")
    tip_ok = tip is None or str(tip) in ids
    acyclic = not _has_cycle(arr)
    return {"ok": not dangling and tip_ok and acyclic,
            "counts": {"nodes": len(arr.get("nodes", [])), "wires": len(arr.get("wires", []))},
            "dangling_wires": dangling, "active_tip_exists": tip_ok, "acyclic": acyclic}


def _unique_id(arr: dict, base: str) -> str:
    existing = {str(n.get("id")) for n in arr.get("nodes", [])}
    if base and base not in existing:
        return base
    stem = base or "msg"
    i = 1
    while f"{stem}_{i}" in existing:
        i += 1
    return f"{stem}_{i}"


def _gen_id(a: dict) -> str:
    p = a.get("params", {})
    seed = f'{p.get("role", "msg")}:{p.get("content", "")}'
    return "msg_" + hashlib.sha256(seed.encode("utf-8")).hexdigest()[:8]


def apply(arr: dict, actions: list) -> dict:
    """Apply validated actions -> a NEW arrangement (append-only; input untouched)."""
    out = copy.deepcopy(arr)
    out.setdefault("nodes", [])
    out.setdefault("wires", [])
    for a in actions:
        op = str(a.get("op", ""))
        if op == "add_node":
            nid = _unique_id(out, str(a.get("id", _gen_id(a))))
            out["nodes"].append({"id": nid, "type": str(a.get("kind", "Message")),
                                 "params": a.get("params", {})})
            parent = a.get("parent")
            if parent:
                out["wires"].append({"from": str(parent), "out": REPLY_PORT,
                                     "to": nid, "in": PARENT_PORT})
        elif op == "wire":
            out["wires"].append({"from": str(a.get("from")), "out": str(a.get("out", REPLY_PORT)),
                                 "to": str(a.get("to")), "in": str(a.get("in", PARENT_PORT))})
        elif op == "set_active_tip":
            out["current_node"] = str(a.get("node"))
    return out
