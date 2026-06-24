"""chip_ops — engine-neutral fold/unfold of an arrangement, Python port.

Parity with godot/editor/chip_ops.gd. Pure DATA in -> DATA out, append-only (returns a NEW
arrangement, never mutates the input). group() wraps a selection of nodes into ONE Chip,
synthesizing one boundary port per cut edge; ungroup() is the EXACT inverse. This is the
"fractal primitive" capability surfaced to Claude as graph_abstract / graph_decompose.
"""
from __future__ import annotations

import copy
import hashlib

FORMAT = "resonance.arrangement/v1"


def _unique_id(arr: dict, base: str) -> str:
    existing = {str(n.get("id")) for n in arr.get("nodes", [])}
    if base not in existing:
        return base
    i = 2
    while f"{base}_{i}" in existing:
        i += 1
    return f"{base}_{i}"


def _chip_id(arr: dict, ids: list[str]) -> str:
    joined = "".join(sorted(str(i) for i in ids))
    return _unique_id(arr, "chip_" + hashlib.sha256(joined.encode("utf-8")).hexdigest()[:8])


def _type_of(nodes: list[dict], node_id: str) -> str:
    for n in nodes:
        if str(n.get("id")) == node_id:
            return str(n.get("type"))
    return ""


def _ptype(resolve_type, inner_nodes, node_id, port, is_input) -> str:
    if resolve_type is None:
        return "any"
    tn = _type_of(inner_nodes, node_id)
    if not tn:
        return "any"
    r = resolve_type(tn, port, is_input)
    return str(r) if r is not None else "any"


def group(arr: dict, ids: list[str], resolve_type=None) -> dict:
    """Wrap the selected node ids into one Chip; rewire crossing wires to the chip's ports."""
    sel = {str(i) for i in ids}
    inner_nodes, outer_nodes = [], []
    sx = sy = 0.0
    npos = 0
    for n in arr.get("nodes", []):
        if str(n.get("id")) in sel:
            inner_nodes.append(copy.deepcopy(n))
            p = n.get("pos")
            if isinstance(p, list) and len(p) >= 2:
                sx += float(p[0])
                sy += float(p[1])
                npos += 1
        else:
            outer_nodes.append(copy.deepcopy(n))

    chip_id = _chip_id(arr, ids)
    inner_wires, kept_wires, inputs, outputs = [], [], [], []
    in_key, out_key = {}, {}

    for w in arr.get("wires", []):
        f, fo, t, ti = str(w.get("from")), str(w.get("out")), str(w.get("to")), str(w.get("in"))
        f_in, t_in = f in sel, t in sel
        if f_in and t_in:
            inner_wires.append(copy.deepcopy(w))
        elif not f_in and not t_in:
            kept_wires.append(copy.deepcopy(w))
        elif t_in:  # outside -> inside : a chip INPUT (one port per distinct inner sink port)
            key = (t, ti)
            pname = in_key.get(key)
            if pname is None:
                pname = f"in_{len(inputs)}"
                in_key[key] = pname
                inputs.append({"name": pname, "type": _ptype(resolve_type, inner_nodes, t, ti, True),
                               "node": t, "port": ti})
            kept_wires.append({"from": f, "out": fo, "to": chip_id, "in": pname})
        else:  # inside -> outside : a chip OUTPUT (one port per distinct inner source port)
            key = (f, fo)
            pname = out_key.get(key)
            if pname is None:
                pname = f"out_{len(outputs)}"
                out_key[key] = pname
                outputs.append({"name": pname, "type": _ptype(resolve_type, inner_nodes, f, fo, False),
                                "node": f, "port": fo})
            kept_wires.append({"from": chip_id, "out": pname, "to": t, "in": ti})

    pos = [sx / npos, sy / npos] if npos > 0 else [0.0, 0.0]
    chip_node = {
        "id": chip_id, "type": "Chip",
        "params": {
            "arrangement": {"format": FORMAT, "nodes": inner_nodes, "wires": inner_wires},
            "ports": {"inputs": inputs, "outputs": outputs},
        },
        "pos": pos,
    }
    out = copy.deepcopy(arr)
    outer_nodes.append(chip_node)
    out["nodes"] = outer_nodes
    out["wires"] = kept_wires
    out.setdefault("format", FORMAT)
    return out


def ungroup(arr: dict, chip_id: str) -> dict:
    """Inverse of group(): splice a Chip's inner nodes/wires back, rewire its ports to inner sites."""
    chip = None
    other = []
    for n in arr.get("nodes", []):
        if str(n.get("id")) == chip_id and str(n.get("type")) == "Chip":
            chip = n
        else:
            other.append(copy.deepcopy(n))
    if chip is None:
        return copy.deepcopy(arr)

    p_params = chip.get("params", {})
    inner = p_params.get("arrangement", {})
    ports = p_params.get("ports", {})
    in_map = {str(p.get("name")): p for p in ports.get("inputs", [])}
    out_map = {str(p.get("name")): p for p in ports.get("outputs", [])}

    for n in inner.get("nodes", []):
        other.append(copy.deepcopy(n))

    new_wires = [copy.deepcopy(w) for w in inner.get("wires", [])]
    for w in arr.get("wires", []):
        f, t = str(w.get("from")), str(w.get("to"))
        if t == chip_id:
            p = in_map.get(str(w.get("in")))
            if p:
                new_wires.append({"from": f, "out": str(w.get("out")),
                                  "to": str(p.get("node")), "in": str(p.get("port"))})
        elif f == chip_id:
            p = out_map.get(str(w.get("out")))
            if p:
                new_wires.append({"from": str(p.get("node")), "out": str(p.get("port")),
                                  "to": t, "in": str(w.get("in"))})
        else:
            new_wires.append(copy.deepcopy(w))

    out = copy.deepcopy(arr)
    out["nodes"] = other
    out["wires"] = new_wires
    return out
