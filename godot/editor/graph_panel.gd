class_name GraphPanel
extends GraphEdit
## The in-game node-editor surface (Godot DELEGATE — throwaway per engine). It renders an
## arrangement as GraphNodes with typed slots, lets you rewire by dragging connections, and
## group a selection into a Chip; every edit re-serialises and writes the SAME arrangement
## file the runtime watches, so editing the graph IS editing the data IS a live re-evaluate.
## The portable grouping/serialisation logic lives in ChipOps + the arrangement schema; this
## file only marshals between the GraphEdit widget and that data.

const FORMAT := "resonance.arrangement/v1"

## Where _commit() writes. Defaults to the file LiveHost watches; override for tests.
var commit_path: String = "res://live/arrangement.json"

var _rt := GraphRuntime.new()
var _arr: Dictionary = {}
var _node_ports: Dictionary = {}  # node_id -> { "inputs": [{name,type}], "outputs": [{name,type}] }

func _ready() -> void:
	# Mirror the PortTypes widening rules into GraphEdit so it permits exactly the
	# connections the runtime accepts (and no others). Single source of truth.
	for from_name in PortTypes.TYPE_IDS:
		for to_name in PortTypes.TYPE_IDS:
			if PortTypes.compatible(from_name, to_name):
				add_valid_connection_type(PortTypes.TYPE_IDS[from_name], PortTypes.TYPE_IDS[to_name])
	connection_request.connect(_on_connection_request)
	disconnection_request.connect(_on_disconnection_request)

func _exit_tree() -> void:
	# _rt is a bare helper Node (never parented), so free it with the panel.
	if is_instance_valid(_rt):
		_rt.free()
		_rt = null

## Render an arrangement. Rebuilds nodes + connections from the data.
func load_arrangement(arr: Dictionary) -> void:
	_arr = arr.duplicate(true)
	clear_connections()
	for c in get_children():
		if c is GraphNode:
			remove_child(c)
			c.free()
	_node_ports.clear()

	for n in _arr.get("nodes", []):
		_add_graph_node(n)
	for w in _arr.get("wires", []):
		var fi := _out_index(String(w.get("from")), String(w.get("out")))
		var ti := _in_index(String(w.get("to")), String(w.get("in")))
		if fi >= 0 and ti >= 0:
			connect_node(String(w.get("from")), fi, String(w.get("to")), ti)

## Recompute _arr["wires"] (+ node positions) from the current graph, and return a copy.
func serialize() -> Dictionary:
	_sync_from_graph()
	return _arr.duplicate(true)

## Group the currently-selected GraphNodes into one Chip (engine-neutral via ChipOps).
func group_selected() -> void:
	var ids := []
	for c in get_children():
		if c is GraphNode and c.selected:
			ids.append(String(c.name))
	if ids.is_empty():
		return
	_sync_from_graph()
	_arr = ChipOps.group(_arr, ids, Callable(_rt, "port_type"))
	load_arrangement(_arr)
	_commit()

# --- internals -------------------------------------------------------------

func _add_graph_node(n: Dictionary) -> void:
	var id := String(n.get("id"))
	var ports: Dictionary = _rt.ports_of(n)
	_node_ports[id] = ports
	var ins: Array = ports["inputs"]
	var outs: Array = ports["outputs"]

	var gn := GraphNode.new()
	gn.name = id
	gn.title = "%s  [%s]" % [id, String(n.get("type"))]
	var pos = n.get("pos", [0, 0])
	if pos is Array and (pos as Array).size() >= 2:
		gn.position_offset = Vector2(float(pos[0]), float(pos[1]))

	var rows: int = maxi(maxi(ins.size(), outs.size()), 1)
	for i in rows:
		var lbl := Label.new()
		var li := String(ins[i]["name"]) if i < ins.size() else ""
		var lo := String(outs[i]["name"]) if i < outs.size() else ""
		lbl.text = ("%-8s" % li) + lo
		gn.add_child(lbl)
	add_child(gn)

	for i in rows:
		var has_in := i < ins.size()
		var has_out := i < outs.size()
		var in_t := PortTypes.type_id(String(ins[i]["type"])) if has_in else 0
		var out_t := PortTypes.type_id(String(outs[i]["type"])) if has_out else 0
		gn.set_slot(i, has_in, in_t, _slot_color(in_t), has_out, out_t, _slot_color(out_t))

func _on_connection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	# One source per input port: drop any existing wire into the target port first.
	for c in get_connection_list():
		if _cl_to(c) == String(to_node) and int(c["to_port"]) == to_port:
			disconnect_node(StringName(_cl_from(c)), int(c["from_port"]), to_node, to_port)
	connect_node(from_node, from_port, to_node, to_port)
	_sync_from_graph()
	_commit()

func _on_disconnection_request(from_node: StringName, from_port: int, to_node: StringName, to_port: int) -> void:
	disconnect_node(from_node, from_port, to_node, to_port)
	_sync_from_graph()
	_commit()

func _sync_from_graph() -> void:
	var wires := []
	for c in get_connection_list():
		var fp: Dictionary = _node_ports.get(_cl_from(c), {})
		var tp: Dictionary = _node_ports.get(_cl_to(c), {})
		var outs: Array = fp.get("outputs", [])
		var ins: Array = tp.get("inputs", [])
		var fi := int(c["from_port"])
		var ti := int(c["to_port"])
		if fi < outs.size() and ti < ins.size():
			wires.append({ "from": _cl_from(c), "out": String(outs[fi]["name"]), "to": _cl_to(c), "in": String(ins[ti]["name"]) })
	_arr["wires"] = wires
	for n in _arr.get("nodes", []):
		var gn := get_node_or_null(NodePath(String(n.get("id"))))
		if gn is GraphNode:
			n["pos"] = [(gn as GraphNode).position_offset.x, (gn as GraphNode).position_offset.y]

func _commit() -> void:
	if not _arr.has("format"):
		_arr["format"] = FORMAT
	var f := FileAccess.open(commit_path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(_arr, "\t"))
		f.close()

func _out_index(id: String, port_name: String) -> int:
	var outs: Array = (_node_ports.get(id, {}) as Dictionary).get("outputs", [])
	for i in outs.size():
		if String(outs[i]["name"]) == port_name:
			return i
	return -1

func _in_index(id: String, port_name: String) -> int:
	var ins: Array = (_node_ports.get(id, {}) as Dictionary).get("inputs", [])
	for i in ins.size():
		if String(ins[i]["name"]) == port_name:
			return i
	return -1

# Connection-list dictionaries renamed keys across 4.x; read either spelling.
func _cl_from(c: Dictionary) -> String:
	return String(c.get("from_node", c.get("from", "")))

func _cl_to(c: Dictionary) -> String:
	return String(c.get("to_node", c.get("to", "")))

func _slot_color(type_id: int) -> Color:
	match type_id:
		1: return Color(0.4, 0.8, 1.0)    # number
		2: return Color(1.0, 0.6, 0.3)    # bool
		3: return Color(0.6, 1.0, 0.6)    # vector3
		4: return Color(0.9, 0.7, 1.0)    # transform
		5: return Color(1.0, 0.9, 0.4)    # color
		6: return Color(1.0, 0.5, 0.7)    # model (legacy)
		7: return Color(0.5, 1.0, 0.9)    # image
		8: return Color(1.0, 1.0, 1.0)    # signal
		9: return Color(0.5, 0.9, 0.6)    # scene_node
	return Color(0.7, 0.7, 0.7)            # any / unknown
