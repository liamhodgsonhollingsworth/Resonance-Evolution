class_name ApertureBoard
extends GraphEdit
## The GODOT APERTURE (GZ-3D.3): a READ-ONLY in-engine renderer for the SAME system-neutral
## {nodes, edges} artifact the WEB Aperture shows. It is a DUMB DELEGATE over the {nodes,edges}
## DATA — it loads a JSON graph, normalizes it via the pure-data ApertureGraph adapter (no engine
## type on the data path), and draws each node as a labeled GraphNode with its edges as wires.
## No editing: this slice only renders.
##
## Reuse, don't rebuild: the canonical-arrangement shape, the typed-slot vocabulary (PortTypes),
## and the slot-color scheme are SHARED with editor/graph_panel.gd (the editable twin). The
## board renders generic in/out ports for arbitrary Aperture node types, so it draws ANY graph,
## not only graphs of registered primitives.
##
## Run windowed + screenshot (one-shot):
##   godot --path godot res://aperture/aperture_board.tscn -- --shot
##     -> renders the bundled sample (or a path arg) and saves godot/live/aperture_board.png, quits.

## The graph file to load. Defaults to the bundled sample; overridable via the `--graph <path>`
## user-arg or by setting before _ready.
@export var graph_path: String = "res://aperture/sample_graph.json"

## Optional per-schema field-map override handed to the adapter (retarget big_projects_graph.json
## here with at most a tiny tweak — see ApertureGraph.default_field_map).
var field_overrides: Dictionary = {}

var _arr: Dictionary = {}                 # the normalized canonical arrangement currently shown
var _node_ports: Dictionary = {}          # node_id -> { "inputs":[name...], "outputs":[name...] }

# --- public API (data path is pure; rendering is the only Godot-coupled part) ----------------

## Load a {nodes, edges|wires} graph from a JSON file path, normalize it, and render it.
## Returns false (and renders an empty board) on a missing/malformed file — never crashes.
func load_graph_file(path: String) -> bool:
	graph_path = path
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		render_arrangement(ApertureGraph.normalize(null, field_overrides))
		return false
	var data = JSON.parse_string(text)
	render_arrangement(ApertureGraph.normalize(data, field_overrides))
	return typeof(data) == TYPE_DICTIONARY

## Normalize an in-memory {nodes, edges} graph and render it.
func load_graph(graph) -> void:
	render_arrangement(ApertureGraph.normalize(graph, field_overrides))

## Render an ALREADY-normalized canonical arrangement ({nodes:[{id,type,label,pos}], wires:[...]}).
## This is the dumb-delegate core: clear, rebuild GraphNodes, reconnect wires.
func render_arrangement(arr: Dictionary) -> void:
	_arr = arr.duplicate(true)
	clear_connections()
	for c in get_children():
		if c is GraphNode:
			remove_child(c)
			c.free()
	_node_ports.clear()

	var nodes: Array = _arr.get("nodes", [])
	var auto_i := 0
	for n in nodes:
		_node_ports[String(n.get("id"))] = ApertureGraph.ports_for_node(String(n.get("id")), _arr)
		_add_node(n, auto_i, nodes.size())
		auto_i += 1

	for w in _arr.get("wires", []):
		var fi := _out_index(String(w.get("from")), String(w.get("out")))
		var ti := _in_index(String(w.get("to")), String(w.get("in")))
		if fi >= 0 and ti >= 0:
			connect_node(String(w.get("from")), fi, String(w.get("to")), ti)

# --- internals -------------------------------------------------------------

func _add_node(n: Dictionary, index: int, total: int) -> void:
	var id := String(n.get("id"))
	var ports: Dictionary = _node_ports[id]
	var ins: Array = ports["inputs"]
	var outs: Array = ports["outputs"]

	var gn := GraphNode.new()
	gn.name = id
	var label := String(n.get("label", id))
	var ntype := String(n.get("type", "node"))
	gn.title = "%s  [%s]" % [label, ntype]

	# Honor a supplied [x,y]; otherwise auto-lay-out in a readable grid so the board is legible
	# out of the box without positions in the data.
	var pos = n.get("pos", [0, 0])
	if pos is Array and (pos as Array).size() >= 2 and (float(pos[0]) != 0.0 or float(pos[1]) != 0.0):
		gn.position_offset = Vector2(float(pos[0]), float(pos[1]))
	else:
		gn.position_offset = _auto_pos(index, total)

	var rows: int = maxi(maxi(ins.size(), outs.size()), 1)
	for i in rows:
		var lbl := Label.new()
		var li := String(ins[i]) if i < ins.size() else ""
		var lo := String(outs[i]) if i < outs.size() else ""
		lbl.text = ("%-8s" % li) + lo
		gn.add_child(lbl)
	add_child(gn)

	for i in rows:
		var has_in := i < ins.size()
		var has_out := i < outs.size()
		# Generic Aperture ports are type "any" (slot id 0) — they accept any connection, which is
		# correct for a read-only display of an arbitrary system-neutral graph.
		gn.set_slot(i, has_in, 0, _slot_color(0), has_out, 0, _slot_color(0))

func _auto_pos(index: int, total: int) -> Vector2:
	# Simple left-to-right columns of up to 4 rows; keeps an unpositioned graph legible.
	var per_col := 4
	var col := index / per_col
	var row := index % per_col
	return Vector2(40.0 + col * 280.0, 40.0 + row * 150.0)

func _out_index(id: String, port_name: String) -> int:
	var outs: Array = (_node_ports.get(id, {}) as Dictionary).get("outputs", [])
	for i in outs.size():
		if String(outs[i]) == port_name:
			return i
	return -1

func _in_index(id: String, port_name: String) -> int:
	var ins: Array = (_node_ports.get(id, {}) as Dictionary).get("inputs", [])
	for i in ins.size():
		if String(ins[i]) == port_name:
			return i
	return -1

# Shared slot-color scheme with editor/graph_panel.gd (one visual vocabulary across both surfaces).
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
