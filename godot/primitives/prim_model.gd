class_name PrimModel
extends Primitive
## Loads a glTF/GLB at RUNTIME (no editor import step) and holds it as a live Node3D,
## exposed on its "node" output port. This is the "add any 3D model into the live game
## as a node" capability — including a model freshly made from a photo (Phase 3).
##
## params.path = a res:// , user:// , or absolute path to a .glb / .gltf.
##
## Because GraphRuntime keeps this primitive across hotloads (and only updates params),
## the loaded model is reloaded ONLY when params.path changes — a live model survives
## re-wiring of everything around it.

var model_root: Node3D = null
var _loaded_path: String = ""

func _init() -> void:
	prim_type = "Model"

func output_ports() -> Array:
	return [{ "name": "node", "type": "model" }]

func _ensure_loaded() -> void:
	var path := String(params.get("path", ""))
	if path == _loaded_path and model_root != null:
		return
	if model_root != null:
		model_root.queue_free()
		model_root = null
	_loaded_path = path
	if path == "":
		return
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(path, state)
	if err != OK:
		push_warning("PrimModel: failed to load '%s' (err %d)" % [path, err])
		return
	var scene := doc.generate_scene(state)
	if scene == null:
		push_warning("PrimModel: generate_scene returned null for '%s'" % path)
		return
	if scene is Node3D:
		model_root = scene
	else:
		model_root = Node3D.new()
		model_root.add_child(scene)
	add_child(model_root)

func evaluate(_inputs: Dictionary) -> Dictionary:
	_ensure_loaded()
	return { "node": model_root }
