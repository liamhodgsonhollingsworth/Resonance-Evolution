class_name PrimLog
extends Primitive
## Sink primitive: records and prints whatever reaches its input. Makes dataflow
## observable and lets the hotload spine be verified headlessly (no GUI needed).

var last_value: Variant = null

func _init() -> void:
	prim_type = "Log"

func input_ports() -> Array:
	return [{ "name": "in", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	last_value = inputs.get("in")
	print("[Log:%s] %s" % [name, str(last_value)])
	return {}
