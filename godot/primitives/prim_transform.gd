class_name PrimTransform
extends Primitive
## Positions / scales / rotates a 3D node (e.g. a Model) from params, then passes the
## same node through. You compose placement by WIRING (Model -> Transform), keeping the
## Model primitive itself free of placement concerns — one function per node.
##
## params: position [x,y,z], scale [x,y,z], rotation [x,y,z] (degrees).

func _init() -> void:
	prim_type = "Transform"

func input_ports() -> Array:
	return [{ "name": "node", "type": "model" }]

func output_ports() -> Array:
	return [{ "name": "node", "type": "model" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var n = inputs.get("node")
	if n is Node3D:
		n.position = _v3(params.get("position", [0, 0, 0]), Vector3.ZERO)
		n.scale = _v3(params.get("scale", [1, 1, 1]), Vector3.ONE)
		n.rotation_degrees = _v3(params.get("rotation", [0, 0, 0]), Vector3.ZERO)
	return { "node": n }

func _v3(a, fallback: Vector3) -> Vector3:
	if a is Array and a.size() >= 3:
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	return fallback
