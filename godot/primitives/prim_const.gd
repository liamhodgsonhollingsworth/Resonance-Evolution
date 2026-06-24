class_name PrimConst
extends Primitive
## Emits a constant value from params.value. The simplest source primitive — useful as
## a wire-able knob and for testing dataflow.

func _init() -> void:
	prim_type = "Const"

func output_ports() -> Array:
	return [{ "name": "value", "type": "number" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	return { "value": params.get("value", 0) }

## Pure: output is a constant of params, no inputs, no side effect. Safe to memoize.
func is_cacheable() -> bool:
	return true
