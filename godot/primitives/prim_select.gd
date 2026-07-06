class_name PrimSelect
extends Primitive
## The MUX / ternary primitive: a bool `cond` picks between `a` (when true) and `b` (when
## false), passing the chosen value straight through on `result`. The if/else sibling of Math —
## the branch operator that lets a whole if/else be a single wire-able node instead of engine
## code. Wired downstream of a Compare/Logic arrangement it is the DATA form of `cond ? a : b`
## (the interaction demo's branches; visi-sonor "if freq in band, this color, else that").
## Value ports are `any` so it muxes numbers, bools, colors, scene_node data — anything on a wire.
##
## params:
##   default_cond — the cond used when the `cond` input is unconnected (null). Default false.

func _init() -> void:
	prim_type = "Select"

func input_ports() -> Array:
	return [
		{ "name": "cond", "type": "bool" },
		{ "name": "a", "type": "any" },
		{ "name": "b", "type": "any" },
	]

func output_ports() -> Array:
	return [{ "name": "result", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var c = inputs.get("cond")
	var cond := PrimLogic.as_bool(c) if c != null else bool(params.get("default_cond", false))
	return { "result": inputs.get("a") if cond else inputs.get("b") }

## Pure: result is a deterministic selection of its inputs, no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
