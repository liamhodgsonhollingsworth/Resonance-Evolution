class_name ChipOps
extends RefCounted
## Engine-neutral arrangement transforms: wrap a selection of nodes into a single Chip, and
## expand a Chip back. Pure DATA in -> DATA out (Dictionaries); imports NO Godot UI / render
## type, so a future three.js (or any) delegate reuses this logic verbatim. Append-only:
## both return a NEW arrangement and never mutate the input.
##
## resolve_type (optional): Callable(node_type: String, port_name: String, is_input: bool)
## -> String, used to type the chip's boundary ports. Pass Callable(graph_runtime,
## "port_type"); when absent, boundary ports default to "any".

const FORMAT := "resonance.arrangement/v1"
const SEP := ""  # field separator unlikely to appear in node ids/port names

## Wrap the selected node ids into one Chip node; rewire crossing wires to the chip's ports.
static func group(arr: Dictionary, ids: Array, resolve_type := Callable()) -> Dictionary:
	var sel := {}
	for id in ids:
		sel[String(id)] = true

	var inner_nodes := []
	var outer_nodes := []
	var sum_x := 0.0
	var sum_y := 0.0
	var n_pos := 0
	for n in arr.get("nodes", []):
		if sel.has(String(n.get("id"))):
			inner_nodes.append((n as Dictionary).duplicate(true))
			var p = n.get("pos")
			if p is Array and (p as Array).size() >= 2:
				sum_x += float(p[0])
				sum_y += float(p[1])
				n_pos += 1
		else:
			outer_nodes.append((n as Dictionary).duplicate(true))

	var chip_id := _unique_id(arr, _chip_id(ids))

	var inner_wires := []
	var kept_wires := []
	var inputs := []
	var outputs := []
	var in_key := {}   # "innerNode SEP innerPort" -> chip input port name
	var out_key := {}  # "innerNode SEP innerPort" -> chip output port name

	for w in arr.get("wires", []):
		var f := String(w.get("from"))
		var fo := String(w.get("out"))
		var t := String(w.get("to"))
		var ti := String(w.get("in"))
		var f_in := sel.has(f)
		var t_in := sel.has(t)
		if f_in and t_in:
			inner_wires.append((w as Dictionary).duplicate(true))
		elif not f_in and not t_in:
			kept_wires.append((w as Dictionary).duplicate(true))
		elif t_in:
			# outside -> inside : a chip INPUT (one port per distinct inner sink port).
			var key := t + SEP + ti
			var pname := String(in_key.get(key, ""))
			if pname == "":
				pname = "in_%d" % inputs.size()
				in_key[key] = pname
				inputs.append({ "name": pname, "type": _ptype(resolve_type, inner_nodes, t, ti, true), "node": t, "port": ti })
			kept_wires.append({ "from": f, "out": fo, "to": chip_id, "in": pname })
		else:
			# inside -> outside : a chip OUTPUT (one port per distinct inner source port).
			var key := f + SEP + fo
			var pname := String(out_key.get(key, ""))
			if pname == "":
				pname = "out_%d" % outputs.size()
				out_key[key] = pname
				outputs.append({ "name": pname, "type": _ptype(resolve_type, inner_nodes, f, fo, false), "node": f, "port": fo })
			kept_wires.append({ "from": chip_id, "out": pname, "to": t, "in": ti })

	var pos := [0.0, 0.0]
	if n_pos > 0:
		pos = [sum_x / n_pos, sum_y / n_pos]

	var chip_node := {
		"id": chip_id,
		"type": "Chip",
		"params": {
			"arrangement": { "format": FORMAT, "nodes": inner_nodes, "wires": inner_wires },
			"ports": { "inputs": inputs, "outputs": outputs },
		},
		"pos": pos,
	}

	var out := arr.duplicate(true)
	outer_nodes.append(chip_node)
	out["nodes"] = outer_nodes
	out["wires"] = kept_wires
	if not out.has("format"):
		out["format"] = FORMAT
	return out

## Inverse of group(): splice a Chip's inner nodes/wires back, rewire its ports to inner sites.
static func ungroup(arr: Dictionary, chip_id: String) -> Dictionary:
	var chip = null
	var other_nodes := []
	for n in arr.get("nodes", []):
		if String(n.get("id")) == chip_id and String(n.get("type")) == "Chip":
			chip = n
		else:
			other_nodes.append((n as Dictionary).duplicate(true))
	if chip == null:
		return arr.duplicate(true)

	var p_params: Dictionary = chip.get("params", {})
	var inner: Dictionary = p_params.get("arrangement", {})
	var ports: Dictionary = p_params.get("ports", {})

	var in_map := {}
	for p in ports.get("inputs", []):
		in_map[String(p.get("name"))] = p
	var out_map := {}
	for p in ports.get("outputs", []):
		out_map[String(p.get("name"))] = p

	for n in inner.get("nodes", []):
		other_nodes.append((n as Dictionary).duplicate(true))

	var new_wires := []
	for w in inner.get("wires", []):
		new_wires.append((w as Dictionary).duplicate(true))
	for w in arr.get("wires", []):
		var f := String(w.get("from"))
		var t := String(w.get("to"))
		if t == chip_id:
			var p = in_map.get(String(w.get("in")))
			if p != null:
				new_wires.append({ "from": f, "out": String(w.get("out")), "to": String(p.get("node")), "in": String(p.get("port")) })
		elif f == chip_id:
			var p = out_map.get(String(w.get("out")))
			if p != null:
				new_wires.append({ "from": String(p.get("node")), "out": String(p.get("port")), "to": t, "in": String(w.get("in")) })
		else:
			new_wires.append((w as Dictionary).duplicate(true))

	var out := arr.duplicate(true)
	out["nodes"] = other_nodes
	out["wires"] = new_wires
	return out

static func _ptype(resolve_type: Callable, inner_nodes: Array, node_id: String, port: String, is_input: bool) -> String:
	if not resolve_type.is_valid():
		return "any"
	var tn := _type_of(inner_nodes, node_id)
	if tn == "":
		return "any"
	var r = resolve_type.call(tn, port, is_input)
	return String(r) if r != null else "any"

static func _type_of(nodes: Array, node_id: String) -> String:
	for n in nodes:
		if String(n.get("id")) == node_id:
			return String(n.get("type"))
	return ""

static func _chip_id(ids: Array) -> String:
	var s := []
	for id in ids:
		s.append(String(id))
	s.sort()
	var joined := SEP.join(PackedStringArray(s))
	return "chip_" + joined.sha256_text().substr(0, 8)

static func _unique_id(arr: Dictionary, base: String) -> String:
	var existing := {}
	for n in arr.get("nodes", []):
		existing[String(n.get("id"))] = true
	if not existing.has(base):
		return base
	var i := 2
	while existing.has("%s_%d" % [base, i]):
		i += 1
	return "%s_%d" % [base, i]
