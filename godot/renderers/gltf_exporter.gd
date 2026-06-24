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
static func export_buffer(roots: Array) -> PackedByteArray:
	var scene := _build_export_scene(roots)
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
static func export_to_file(roots: Array, out_path: String) -> int:
	var scene := _build_export_scene(roots)
	if scene == null:
		return ERR_INVALID_DATA
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var err := doc.append_from_scene(scene, st)
	if err == OK:
		err = doc.write_to_filesystem(st, out_path)
	scene.free()
	return err

static func _build_export_scene(roots: Array) -> Node3D:
	if roots == null:
		return null
	# Drop nulls / non-descriptors (e.g. a Model with no path emits null) so we never write a
	# false-success "valid" GLB out of junk roots.
	var valid := []
	for r in roots:
		if GodotSceneRenderer.is_scene_node(r):
			valid.append(r)
	if valid.is_empty():
		return null
	var scene := Node3D.new()
	scene.name = "ResonanceScene"
	GodotSceneRenderer.build_static_tree(valid, scene)
	# GLTFDocument.append_from_scene only includes descendants whose `owner` is set.
	_set_owner_recursive(scene, scene)
	return scene

static func _set_owner_recursive(node: Node, owner_root: Node) -> void:
	for c in node.get_children():
		c.owner = owner_root
		_set_owner_recursive(c, owner_root)
