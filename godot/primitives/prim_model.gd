class_name PrimModel
extends Primitive
## Emits a renderer-NEUTRAL scene_node descriptor that REFERENCES a glTF/GLB model by path —
## as DATA, never a live Godot node. The actual GLB load + Node3D build happens in the
## renderer delegate (GodotSceneRenderer), so the arrangement value is portable to any
## renderer and the same descriptor can be exported straight back out to glTF/GLB.
##
## This is the substrate-independence law for the 3D path: a "model" on a wire is DATA
## (a glTF-aligned node descriptor), not a Godot object — so a 3D arrangement ports across
## engines exactly like the Const/Math/Log arrangements already do.
##
## params.path = a res:// , user:// , or absolute path to a .glb / .gltf. (This is a pointer in
##   Godot's namespace; a non-Godot delegate must resolve it itself — the portability boundary.)
## params.name = optional node name (keeping it valid + unique helps glTF round-trips).

func _init() -> void:
	prim_type = "Model"

func output_ports() -> Array:
	return [{ "name": "node", "type": "scene_node" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var path := String(params.get("path", ""))
	if path == "":
		return { "node": null }
	return { "node": {
		"name": String(params.get("name", "model")),
		"translation": [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": { "source": "glb", "path": path },
		"children": []
	} }
