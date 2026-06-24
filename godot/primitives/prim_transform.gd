class_name PrimTransform
extends Primitive
## Sets the placement (translation / rotation / scale) of a scene_node descriptor and passes
## the new descriptor through — as DATA. It no longer touches any live Godot node: placement
## is recorded in the renderer-neutral, glTF-aligned descriptor and the renderer delegate
## applies it. You still compose placement by WIRING (Model -> Transform), one function per
## node; the difference is the value on the wire is now portable.
##
## Rotation is authored in DEGREES (convenience) but EMITTED as a glTF unit quaternion
## [x, y, z, w], so the wire value carries no Euler-order ambiguity across engines.
##
## params: position [x,y,z] (meters), scale [x,y,z], rotation [x,y,z] (degrees, author input).

func _init() -> void:
	prim_type = "Transform"

func input_ports() -> Array:
	return [{ "name": "node", "type": "scene_node" }]

func output_ports() -> Array:
	return [{ "name": "node", "type": "scene_node" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var n = inputs.get("node")
	if typeof(n) != TYPE_DICTIONARY:
		return { "node": n }
	var out: Dictionary = (n as Dictionary).duplicate(true)  # append-only: never mutate input
	out["translation"] = _v3(params.get("position", [0, 0, 0]), [0.0, 0.0, 0.0])
	out["scale"] = _v3(params.get("scale", [1, 1, 1]), [1.0, 1.0, 1.0])
	out["rotation"] = _euler_deg_to_quat(params.get("rotation", [0, 0, 0]))
	return { "node": out }

# Returns a plain 3-array (NOT a Vector3) so the wire value stays JSON-serializable.
func _v3(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	return fallback

# Author convenience (Euler degrees) -> portable glTF quaternion [x,y,z,w]. Uses Godot's
# Quaternion.from_euler (YXZ), matching the old rotation_degrees behavior, so visuals are
# preserved while the on-wire representation becomes portable.
func _euler_deg_to_quat(a) -> Array:
	var e := _v3(a, [0.0, 0.0, 0.0])
	var q := Quaternion.from_euler(Vector3(deg_to_rad(e[0]), deg_to_rad(e[1]), deg_to_rad(e[2])))
	return [q.x, q.y, q.z, q.w]
