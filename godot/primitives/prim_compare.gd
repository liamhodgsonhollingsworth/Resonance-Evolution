class_name PrimCompare
extends Primitive
## Compares two numbers with params.op in {lt, le, eq, ne, gt, ge} and emits a bool. The
## comparison sibling of Math: same source shape (two number inputs, one output, an op table
## in the DATA), so a running graph switches predicate by editing params.op — no new code.
## The missing OPERATOR that lets "distance < radius" be a single wire-able node feeding a
## Logic/Select arrangement (the interaction demo's "near Y", visi-sonor's BRAIN thresholds).
##
## params:
##   op   — one of lt (<), le (<=), eq (==), ne (!=), gt (>), ge (>=). Default "lt".
##   eps  — tolerance for eq/ne (default 0.0 = exact). Guards float round-off in threshold logic.

func _init() -> void:
	prim_type = "Compare"

func input_ports() -> Array:
	return [{ "name": "a", "type": "number" }, { "name": "b", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "result", "type": "bool" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var a := as_num(inputs.get("a"))
	var b := as_num(inputs.get("b"))
	var eps := as_num(params.get("eps", 0.0))
	match String(params.get("op", "lt")):
		"lt": return { "result": a < b }
		"le": return { "result": a <= b }
		"eq": return { "result": absf(a - b) <= eps }
		"ne": return { "result": absf(a - b) > eps }
		"gt": return { "result": a > b }
		"ge": return { "result": a >= b }
	return { "result": false }

## Pure: result is a deterministic function of (a, b, op, eps), no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
