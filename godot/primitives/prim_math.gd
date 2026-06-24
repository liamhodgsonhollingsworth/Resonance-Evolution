class_name PrimMath
extends Primitive
## Combines two numbers with params.op in {add, sub, mul, div}. A canonical compute
## primitive: change op in the DATA and the running graph re-evaluates — no new code.

func _init() -> void:
	prim_type = "Math"

func input_ports() -> Array:
	return [{ "name": "a", "type": "number" }, { "name": "b", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "result", "type": "number" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var a := as_num(inputs.get("a"))
	var b := as_num(inputs.get("b"))
	match String(params.get("op", "add")):
		"add": return { "result": a + b }
		"sub": return { "result": a - b }
		"mul": return { "result": a * b }
		"div": return { "result": (a / b) if b != 0.0 else 0.0 }
	return { "result": 0.0 }

## Pure: result is a deterministic function of (a, b, op), no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
