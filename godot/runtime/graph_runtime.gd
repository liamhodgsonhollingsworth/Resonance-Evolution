class_name GraphRuntime
extends Node
## Interprets an "arrangement" (a graph of primitive instances + typed wires, stored as
## plain data) into live primitive nodes, and evaluates the dataflow.
##
## RELOAD IS A DIFF, NOT A REBUILD. This is the hotload model the whole system runs on:
## change the DATA, and the already-loaded primitives are re-wired in place. Unchanged
## primitives (and any live 3D models they hold) are KEPT, their params are updated in
## place, and only added / removed / type-changed nodes are touched. No script reload.

var arrangement: Dictionary = {}
var nodes: Dictionary = {}  # node_id (String) -> Primitive

# type name -> primitive class (GDScript). New primitive TYPES register here; new
# FUNCTIONS are just new arrangements over the already-registered types.
var _registry: Dictionary = {}

func _init() -> void:
	register("Const", PrimConst)
	register("Math", PrimMath)
	register("Log", PrimLog)
	register("Model", PrimModel)
	register("Transform", PrimTransform)

func register(type_name: String, prim_class) -> void:
	_registry[type_name] = prim_class

## Load / replace the arrangement via a diff against the current graph.
func load_arrangement(data: Dictionary) -> void:
	var new_specs := {}
	for n in data.get("nodes", []):
		new_specs[String(n.get("id"))] = n

	# Remove nodes that disappeared or whose type changed.
	for id in nodes.keys():
		var keep: bool = new_specs.has(id) and String(new_specs[id].get("type")) == nodes[id].prim_type
		if not keep:
			nodes[id].queue_free()
			nodes.erase(id)

	# Add new nodes; update params on kept nodes (preserves live instances / models).
	for id in new_specs.keys():
		var spec: Dictionary = new_specs[id]
		if nodes.has(id):
			nodes[id].params = spec.get("params", {})
		else:
			var prim: Primitive = _instance(String(spec.get("type")))
			if prim == null:
				push_warning("GraphRuntime: unknown primitive type '%s'" % spec.get("type"))
				continue
			prim.name = id
			prim.params = spec.get("params", {})
			add_child(prim)
			nodes[id] = prim

	arrangement = data

func _instance(type_name: String) -> Primitive:
	var c = _registry.get(type_name)
	if c == null:
		return null
	return c.new()

## Evaluate the whole dataflow once. Returns node_id -> { output_port -> value }.
func evaluate() -> Dictionary:
	var outputs := {}
	var wires: Array = arrangement.get("wires", [])
	for node_id in _topo_order():
		var prim: Primitive = nodes[node_id]
		var inputs := {}
		for w in wires:
			if String(w.get("to")) == node_id:
				var src: Dictionary = outputs.get(String(w.get("from")), {})
				inputs[String(w.get("in"))] = src.get(String(w.get("out")))
		outputs[node_id] = prim.evaluate(inputs)
	return outputs

# Kahn topological sort over the wire DAG; cycle remnants are appended (never dropped).
func _topo_order() -> Array:
	var ids: Array = nodes.keys()
	var indeg := {}
	var adj := {}
	for id in ids:
		indeg[id] = 0
		adj[id] = []
	for w in arrangement.get("wires", []):
		var f := String(w.get("from"))
		var t := String(w.get("to"))
		if nodes.has(f) and nodes.has(t):
			(adj[f] as Array).append(t)
			indeg[t] += 1
	var queue := []
	for id in ids:
		if indeg[id] == 0:
			queue.append(id)
	var order := []
	while not queue.is_empty():
		var n = queue.pop_front()
		order.append(n)
		for m in adj[n]:
			indeg[m] -= 1
			if indeg[m] == 0:
				queue.append(m)
	for id in ids:
		if not order.has(id):
			order.append(id)
	return order

## Convenience: load an arrangement from a JSON file (res:// or user://).
func load_json(path: String) -> void:
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		load_arrangement(data)
	else:
		push_error("GraphRuntime: failed to parse arrangement JSON '%s'" % path)
