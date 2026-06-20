class_name PrimChip
extends Primitive
## A Chip is a cluster of wired primitives wrapped as ONE primitive — the Media Molecule
## *Dreams* "microchip" model. params.arrangement holds the nested graph; params.ports maps
## the chip's outer typed ports to inner (node, port) sites. evaluate() runs a recursive
## GraphRuntime over the nested arrangement, so nesting / "procedural all the way down"
## falls out of the existing machinery for free. A chip is a new FUNCTION, not new code:
## pure data over the already-registered primitive types.
##
## params shape:
##   {
##     "arrangement": { "format": ..., "nodes": [...], "wires": [...] },
##     "ports": {
##       "inputs":  [ { "name": "in_0",  "type": "number", "node": "<inner id>", "port": "a" }, ... ],
##       "outputs": [ { "name": "out_0", "type": "number", "node": "<inner id>", "port": "result" }, ... ]
##     }
##   }

var _sub: GraphRuntime = null

func _init() -> void:
	prim_type = "Chip"

func input_ports() -> Array:
	return _ports("inputs")

func output_ports() -> Array:
	return _ports("outputs")

func _ports(which: String) -> Array:
	var out := []
	var ports: Dictionary = params.get("ports", {})
	for p in ports.get(which, []):
		out.append({ "name": String(p.get("name")), "type": String(p.get("type", "any")) })
	return out

func evaluate(inputs: Dictionary) -> Dictionary:
	var arr: Dictionary = params.get("arrangement", {})
	if _sub == null:
		_sub = GraphRuntime.new()
		add_child(_sub)
	# Diff-hotload the inner graph: unchanged inner instances / live models are kept.
	_sub.load_arrangement(arr)
	# Feed the chip's incoming port values into their mapped inner sites.
	var ports: Dictionary = params.get("ports", {})
	var ext := {}
	for p in ports.get("inputs", []):
		var node_id := String(p.get("node"))
		var in_port := String(p.get("port"))
		if not ext.has(node_id):
			ext[node_id] = {}
		ext[node_id][in_port] = inputs.get(String(p.get("name")))
	_sub.set_external_inputs(ext)
	var outs := _sub.evaluate()
	# Read the chip's outgoing ports from their mapped inner sites.
	var result := {}
	for p in ports.get("outputs", []):
		var src: Dictionary = outs.get(String(p.get("node")), {})
		result[String(p.get("name"))] = src.get(String(p.get("port")))
	return result
