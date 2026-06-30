class_name ApertureGraph
extends RefCounted
## Pure-DATA adapter: normalize an incoming Aperture artifact ({nodes, edges})
## into the engine's canonical internal arrangement shape, with NO Godot scene/UI type on
## the data path (engine-agnostic — a future three.js delegate reuses this verbatim).
##
## The Aperture's system-neutral artifact is a node-graph. Two shapes are accepted, and both
## normalize to the SAME canonical form:
##   1. RE-native arrangement: {nodes:[{id,type,params}], wires:[{from,out,to,in}]}
##   2. generic graph:         {nodes:[{id, type?/label?, ...}], edges:[{from,to}|{source,target}]}
##
## Field-name tolerance (so the as-yet-unfinalized big_projects_graph.json renders with at most a
## tiny field-map tweak — nothing is hardcoded to one schema):
##   - edge LIST key:  "edges" OR "wires"            (configurable: field_map.edges_keys)
##   - edge ENDPOINTS: from/to, source/target        (configurable: field_map.from_keys / to_keys)
##   - edge PORTS:     out/in (optional)             (configurable: field_map.out_keys / in_keys)
##   - node ID:        id, name, key                 (configurable: field_map.id_keys)
##   - node TYPE:      type, kind                    (configurable: field_map.type_keys)
##   - node LABEL:     label, title, name            (configurable: field_map.label_keys)
##   - node POS:       pos, position [x,y]           (configurable: field_map.pos_keys)
##
## CANONICAL OUT: { "format": "resonance.arrangement/v1", "name": ...,
##   "nodes": [ { "id", "type", "label", "pos":[x,y], "params" } ],
##   "wires": [ { "from", "out", "to", "in" } ] }
## Every node is given a generic single in/out port ("in"/"out") unless the edge names ports
## explicitly, so a read-only board can always draw the edges regardless of node type.

const FORMAT := "resonance.arrangement/v1"
const GENERIC_OUT := "out"
const GENERIC_IN := "in"

## The default, tolerant field map. Pass a partial override to normalize() to retarget a new
## schema (e.g. big_projects_graph.json) without code changes.
static func default_field_map() -> Dictionary:
	return {
		"edges_keys": ["edges", "wires"],
		"from_keys": ["from", "source", "src"],
		"to_keys": ["to", "target", "dst"],
		"out_keys": ["out", "from_port", "sourcePort"],
		"in_keys": ["in", "to_port", "targetPort"],
		"id_keys": ["id", "name", "key"],
		"type_keys": ["type", "kind"],
		"label_keys": ["label", "title", "name"],
		"pos_keys": ["pos", "position"],
	}

## Normalize an arbitrary {nodes, edges|wires} graph into the canonical internal arrangement.
## `field_overrides` is merged over default_field_map() (per-key replace), so a caller adapts a
## new schema by overriding only the keys that differ. Degrades gracefully: a missing/empty/
## malformed graph yields an empty-but-valid arrangement (no crash).
static func normalize(graph, field_overrides: Dictionary = {}) -> Dictionary:
	var fm := default_field_map()
	for k in field_overrides:
		fm[k] = field_overrides[k]

	var out := { "format": FORMAT, "name": "", "nodes": [], "wires": [] }
	if typeof(graph) != TYPE_DICTIONARY:
		return out
	out["name"] = String((graph as Dictionary).get("name", ""))

	var raw_nodes = (graph as Dictionary).get("nodes", [])
	if typeof(raw_nodes) != TYPE_ARRAY:
		raw_nodes = []

	# --- nodes ---
	var seen_ids := {}
	var auto := 0
	for rn in raw_nodes:
		if typeof(rn) != TYPE_DICTIONARY:
			continue
		var n: Dictionary = rn
		var id := _first_str(n, fm["id_keys"], "")
		if id == "":
			id = "n%d" % auto
		auto += 1
		if seen_ids.has(id):
			continue  # first id wins; ignore duplicate-id rows (append-only, no overwrite)
		seen_ids[id] = true
		var ntype := _first_str(n, fm["type_keys"], "node")
		var label := _first_str(n, fm["label_keys"], "")
		if label == "":
			label = id
		out["nodes"].append({
			"id": id,
			"type": ntype,
			"label": label,
			"pos": _read_pos(n, fm["pos_keys"]),
			"params": n.get("params", {}) if typeof(n.get("params")) == TYPE_DICTIONARY else {},
		})

	# --- edges (accept either edge-list key) ---
	var raw_edges = null
	for ek in fm["edges_keys"]:
		var v = (graph as Dictionary).get(ek)
		if typeof(v) == TYPE_ARRAY:
			raw_edges = v
			break
	if raw_edges == null:
		raw_edges = []

	for re in raw_edges:
		if typeof(re) != TYPE_DICTIONARY:
			continue
		var e: Dictionary = re
		var f := _first_str(e, fm["from_keys"], "")
		var t := _first_str(e, fm["to_keys"], "")
		if f == "" or t == "":
			continue  # skip malformed edge endpoints
		if not seen_ids.has(f) or not seen_ids.has(t):
			continue  # drop edges that reference unknown nodes (don't fabricate nodes)
		out["wires"].append({
			"from": f,
			"out": _first_str(e, fm["out_keys"], GENERIC_OUT),
			"to": t,
			"in": _first_str(e, fm["in_keys"], GENERIC_IN),
		})
	return out

## The set of ports a normalized node needs so its edges can attach — the UNION of the generic
## in/out ports and any explicit port names the wires reference. Pure data; the board reads this
## to lay out slots without knowing any primitive type. Returns { "inputs":[name...], "outputs":[name...] }.
static func ports_for_node(node_id: String, arr: Dictionary) -> Dictionary:
	var ins := { GENERIC_IN: true }
	var outs := { GENERIC_OUT: true }
	for w in arr.get("wires", []):
		if String(w.get("to")) == node_id:
			ins[String(w.get("in", GENERIC_IN))] = true
		if String(w.get("from")) == node_id:
			outs[String(w.get("out", GENERIC_OUT))] = true
	return { "inputs": ins.keys(), "outputs": outs.keys() }

# --- internals -------------------------------------------------------------

static func _first_str(d: Dictionary, keys: Array, fallback: String) -> String:
	for k in keys:
		if d.has(k) and d[k] != null:
			var s := String(d[k])
			if s != "":
				return s
	return fallback

static func _read_pos(d: Dictionary, keys: Array) -> Array:
	for k in keys:
		var p = d.get(k)
		if p is Array and (p as Array).size() >= 2:
			return [float(p[0]), float(p[1])]
		if p is Dictionary and (p as Dictionary).has("x") and (p as Dictionary).has("y"):
			return [float((p as Dictionary)["x"]), float((p as Dictionary)["y"])]
	return [0.0, 0.0]
