class_name PrimLogic
extends Primitive
## Combines two booleans with params.op in {and, or, xor, nand, nor, xnor} — or negates `a`
## when op == not. The boolean sibling of Math: same source shape (an op table in the DATA),
## so a running graph switches gate by editing params.op — no new code. Wired downstream of
## Compare nodes it makes "near Y AND pressed X" a single wire-able node (the interaction
## demo's conjunctions, an arrangement of these IS visi-sonor's BRAIN threshold logic).
##
## params:
##   op — one of and, or, xor, nand, nor, xnor (two inputs) or not (unary on `a`). Default "and".
## Unconnected bool inputs arrive as null → coerced to false (as_bool), so a missing wire is a
## defined FALSE, never a crash.

func _init() -> void:
	prim_type = "Logic"

func input_ports() -> Array:
	return [{ "name": "a", "type": "bool" }, { "name": "b", "type": "bool" }]

func output_ports() -> Array:
	return [{ "name": "result", "type": "bool" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var a := as_bool(inputs.get("a"))
	var b := as_bool(inputs.get("b"))
	match String(params.get("op", "and")):
		"and": return { "result": a and b }
		"or": return { "result": a or b }
		"xor": return { "result": a != b }
		"nand": return { "result": not (a and b) }
		"nor": return { "result": not (a or b) }
		"xnor": return { "result": a == b }
		"not": return { "result": not a }
	return { "result": false }

## Coerce a possibly-null wire value (unconnected inputs arrive as null) to a bool. A number
## is truthy when non-zero (so a Compare/number can also drive a gate); a string is truthy
## when non-empty. Mirrors Primitive.as_num's null-tolerant contract for the bool domain.
static func as_bool(v) -> bool:
	if v == null:
		return false
	match typeof(v):
		TYPE_BOOL:
			return v
		TYPE_INT, TYPE_FLOAT:
			return float(v) != 0.0
		TYPE_STRING:
			return not (v as String).is_empty()
	return false

## Pure: result is a deterministic function of (a, b, op), no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
