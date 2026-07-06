class_name PrimLight
extends Primitive
## Emits a renderer-NEUTRAL light descriptor on the `light` port — as DATA, never a live Godot
## DirectionalLight3D/OmniLight3D/SpotLight3D. The actual light build + drive happens in the renderer
## delegate (GodotSceneRenderer.apply_lights), so a light is portable to any renderer and the same
## descriptor exports straight out to a glTF KHR_lights_punctual light node.
##
## This is the substrate-independence law applied to LIGHTING: a "light" on a wire is glTF-2.0
## KHR_lights_punctual DATA, not a Godot object — so a scene's lights are portable across engines
## (Godot, three.js, <model-viewer>, Blender) exactly like the Model/Transform/Group/View arrangements.
##
## The descriptor is glTF-KHR_lights_punctual-aligned:
##   { kind:"light", type:"directional"|"point"|"spot",
##     color:[r,g,b] (linear 0..1), intensity:<f>,
##     transform:{ translation:[x,y,z], rotation:[x,y,z,w] (quaternion), scale:[x,y,z] },
##     range:<f>? (point/spot falloff distance), shadow:<bool>?,
##     spot:{ inner_cone_deg:<f>, outer_cone_deg:<f> }? (spot only) }
## Renderer-neutral: color [r,g,b], angles authored in degrees -> emitted as a glTF quaternion; no
## Godot object on the wire. glTF's KHR_lights_punctual points a directional/spot light down the node's
## LOCAL -Z (matching Godot's DirectionalLight3D "look down -Z"), so `rotation` fully aims the light.
##
## params:
##   type      "directional" | "point" | "spot"   (default "directional")
##   color     [r,g,b] linear (default [1,1,1])
##   intensity <f> light strength/energy          (default 1.0)
##   position  [x,y,z] meters                      (default [0,0,0]) — placement (point/spot use it)
##   rotation  [x,y,z] degrees (author)            (default [0,0,0]) — aim (directional/spot use it)
##   range     <f> point/spot falloff distance     (default 0 = engine default / infinite)
##   shadow    <bool> cast shadows                 (default false)
##   inner_cone_deg / outer_cone_deg  spot cone half-angles (spot only; defaults 20 / 30)

func _init() -> void:
	prim_type = "Light"

func output_ports() -> Array:
	return [{ "name": "light", "type": "light" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var light := {
		"kind": "light",
		"type": String(params.get("type", "directional")),
		"color": _v3(params.get("color", [1.0, 1.0, 1.0]), [1.0, 1.0, 1.0]),
		"intensity": float(params.get("intensity", 1.0)),
		"transform": {
			"translation": _v3(params.get("position", [0.0, 0.0, 0.0]), [0.0, 0.0, 0.0]),
			"rotation": _euler_deg_to_quat(params.get("rotation", [0.0, 0.0, 0.0])),
			"scale": [1.0, 1.0, 1.0],
		},
	}
	if params.has("range"):
		light["range"] = float(params.get("range"))
	if params.has("shadow"):
		light["shadow"] = bool(params.get("shadow"))
	if String(light["type"]) == "spot":
		light["spot"] = {
			"inner_cone_deg": float(params.get("inner_cone_deg", 20.0)),
			"outer_cone_deg": float(params.get("outer_cone_deg", 30.0)),
		}
	return { "light": light }

# Returns a plain 3-array (NOT a Vector3) so the wire value stays JSON-serializable.
func _v3(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	return fallback

# Author convenience (Euler degrees) -> portable glTF quaternion [x,y,z,w], matching PrimTransform/PrimView.
func _euler_deg_to_quat(a) -> Array:
	var e := _v3(a, [0.0, 0.0, 0.0])
	var q := Quaternion.from_euler(Vector3(deg_to_rad(e[0]), deg_to_rad(e[1]), deg_to_rad(e[2])))
	return [q.x, q.y, q.z, q.w]
