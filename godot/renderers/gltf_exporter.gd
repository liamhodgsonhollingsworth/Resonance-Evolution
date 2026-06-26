class_name GltfExporter
extends RefCounted
## Exports a GraphRuntime.evaluate() result (the renderer-neutral `scene_node` data) to glTF
## (GLB) — the universal, maximally-compatible 3D interchange. It walks the SAME tree builder
## as GodotSceneRenderer (build_static_tree), so what is exported provably matches what is
## rendered on screen.
##
## This is what makes a 3D arrangement PORTABLE: once it is a valid GLB, any glTF consumer
## (three.js, Blender, another engine, the Khronos validator) is "another renderer" — which
## is how substrate-independence is tested end-to-end (see headless_portable_test.gd).

## Export root descriptors to a GLB in memory (PackedByteArray). Empty array on failure.
## `view` (optional): a renderer-neutral `view` descriptor — when non-empty, a glTF camera node
## (driven by GodotSceneRenderer.drive_camera) is added so the SAME single-scene view is portable
## to three.js / <model-viewer> / Blender. Omit it (default {}) to export geometry only, unchanged.
static func export_buffer(roots: Array, view: Dictionary = {}) -> PackedByteArray:
	var scene := _build_export_scene(roots, view)
	if scene == null:
		return PackedByteArray()
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_scene(scene, st)
	if err != OK:
		push_warning("GltfExporter: append_from_scene failed (err %d)" % err)
		scene.free()
		return PackedByteArray()
	var bytes := doc.generate_buffer(st)
	scene.free()
	return bytes

## Export root descriptors to a file (.glb binary, .gltf text). Returns an Error.
## `view` (optional): see export_buffer — adds a glTF camera node when non-empty.
static func export_to_file(roots: Array, out_path: String, view: Dictionary = {}) -> int:
	var scene := _build_export_scene(roots, view)
	if scene == null:
		return ERR_INVALID_DATA
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_scene(scene, st)
	if err == OK:
		err = doc.write_to_filesystem(st, out_path)
	scene.free()
	return err

static func _build_export_scene(roots: Array, view: Dictionary = {}) -> Node3D:
	if roots == null:
		roots = []
	# Drop nulls / non-descriptors (e.g. a Model with no path emits null) so we never write a
	# false-success "valid" GLB out of junk roots.
	var valid := []
	for r in roots:
		if GodotSceneRenderer.is_scene_node(r):
			valid.append(r)
	var has_view: bool = GodotSceneRenderer.is_view(view)
	# Nothing to export (no geometry AND no camera): don't write a false-success "valid" GLB.
	if valid.is_empty() and not has_view:
		return null
	var scene := Node3D.new()
	scene.name = "ResonanceScene"
	GodotSceneRenderer.build_static_tree(valid, scene)
	# A View descriptor becomes a glTF CAMERA node (a Camera3D driven by the SAME drive_camera the live
	# renderer uses, so the exported view provably matches what's shown). GLTFDocument exports a
	# Camera3D in the scene as a glTF perspective camera + its node automatically — that's the portable
	# camera the web / Blender / model-viewer consume.
	if has_view:
		var cam := Camera3D.new()
		cam.name = "ViewCamera"
		scene.add_child(cam)
		# Aim resolves against the built scene roots (target_node / look_at), same as the live path.
		GodotSceneRenderer.drive_camera(cam, view, GltfExporter._roots_with_ids(valid))
	# GLTFDocument.append_from_scene only includes descendants whose `owner` is set.
	_set_owner_recursive(scene, scene)
	return scene

# Wrap raw root descriptors as the { node_id, desc } shape drive_camera's target_node resolution
# expects. Exported roots have no producing-node identity, so target_node aim falls back to the world
# origin (the documented behavior) while an explicit look_at still resolves exactly.
static func _roots_with_ids(valid: Array) -> Array:
	var out := []
	for d in valid:
		out.append({ "node_id": "", "port": "", "desc": d })
	return out

static func _set_owner_recursive(node: Node, owner_root: Node) -> void:
	for c in node.get_children():
		c.owner = owner_root
		_set_owner_recursive(c, owner_root)
