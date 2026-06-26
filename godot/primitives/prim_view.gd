class_name PrimView
extends Primitive
## Emits a renderer-NEUTRAL camera/view descriptor on the `view` port — as DATA, never a live
## Godot Camera3D. The actual Camera3D build + drive happens in the renderer delegate
## (GodotSceneRenderer), so the view is portable to any renderer and the same descriptor exports
## straight back out to a glTF camera node.
##
## This is the substrate-independence law applied to the CAMERA: a "view" on a wire is glTF-2.0
## camera DATA, not a Godot object — so a scene + its view port across engines (Godot, three.js,
## <model-viewer>, Blender) exactly like the Model/Transform/Group arrangements already do. The
## "single scene → static view" keystone: render(scene, view) becomes data, not hardcoded camera.
##
## The descriptor is glTF-2.0-camera-aligned:
##   { type:"perspective", yfov:<rad>, znear:<f>, zfar:<f>,
##     transform:{ translation:[x,y,z], rotation:[x,y,z,w], scale:[x,y,z] },
##     look_at:[x,y,z]?, target_node:"<id>"? }
##
## params:
##   position [x,y,z] (meters)            — camera placement (default 2.5,2.0,3.5, matching the
##                                          prior hardcoded main.gd camera so framing is preserved).
##   rotation [x,y,z] (degrees, author)   — emitted as a glTF quaternion. Ignored when look_at /
##                                          target are given (the delegate aims the camera instead).
##   look_at  [x,y,z]                     — optional aim point; when present the renderer orients
##                                          the camera toward it (overrides rotation).
##   target   "<node_id>" | target_node   — optional id of a scene node to aim at (resolved by the
##                                          delegate against the rendered scene; falls back to origin).
##   yfov     (degrees, author)           — vertical field of view; emitted as RADIANS (glTF unit).
##   znear, zfar (meters)                 — clip planes.

const DEFAULT_POSITION := [2.5, 2.0, 3.5]
const DEFAULT_YFOV_DEG := 75.0
const DEFAULT_ZNEAR := 0.05
const DEFAULT_ZFAR := 4000.0

func _init() -> void:
	prim_type = "View"

func output_ports() -> Array:
	return [{ "name": "view", "type": "view" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var translation := _v3(params.get("position", DEFAULT_POSITION), [2.5, 2.0, 3.5])
	var view := {
		"type": "perspective",
		"yfov": deg_to_rad(float(params.get("yfov", DEFAULT_YFOV_DEG))),
		"znear": float(params.get("znear", DEFAULT_ZNEAR)),
		"zfar": float(params.get("zfar", DEFAULT_ZFAR)),
		"transform": {
			"translation": translation,
			"rotation": _euler_deg_to_quat(params.get("rotation", [0, 0, 0])),
			"scale": [1.0, 1.0, 1.0]
		}
	}
	# Optional aim: an explicit look_at point, or a target node id the delegate resolves. Both are
	# carried as DATA; the renderer-neutral descriptor stays self-describing (no Godot lookup here).
	if params.has("look_at"):
		view["look_at"] = _v3(params.get("look_at"), [0.0, 0.0, 0.0])
	var target = params.get("target", params.get("target_node", null))
	if target != null and String(target) != "":
		view["target_node"] = String(target)
	return { "view": view }

# Returns a plain 3-array (NOT a Vector3) so the wire value stays JSON-serializable.
func _v3(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	return fallback

# Author convenience (Euler degrees) -> portable glTF quaternion [x,y,z,w], matching PrimTransform.
func _euler_deg_to_quat(a) -> Array:
	var e := _v3(a, [0.0, 0.0, 0.0])
	var q := Quaternion.from_euler(Vector3(deg_to_rad(e[0]), deg_to_rad(e[1]), deg_to_rad(e[2])))
	return [q.x, q.y, q.z, q.w]
