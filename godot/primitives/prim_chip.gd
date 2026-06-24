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

## Maximum Chip nesting depth before a branch is halted. Real homoiconic nesting is far
## shallower than this; the cap exists only to stop runaway recursion — accidental very-deep
## nesting, or (once chips become shared/named definitions) a definition referencing itself.
const MAX_DEPTH := 64

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
	# Depth guard: my owning runtime carries this chip's nesting depth. Halt this branch
	# gracefully (every output null) rather than overflowing the stack on runaway recursion.
	var parent_depth := 0
	var pr := get_parent()
	if pr is GraphRuntime:
		parent_depth = (pr as GraphRuntime).depth
	if parent_depth >= MAX_DEPTH:
		push_error("PrimChip: max nesting depth (%d) exceeded — halting this branch" % MAX_DEPTH)
		var halted := {}
		for p in (params.get("ports", {}) as Dictionary).get("outputs", []):
			halted[String(p.get("name"))] = null
		return halted
	if _sub == null:
		_sub = GraphRuntime.new()
		add_child(_sub)
	_sub.depth = parent_depth + 1
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
