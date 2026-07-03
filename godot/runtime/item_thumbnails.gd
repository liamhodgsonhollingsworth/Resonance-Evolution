extends RefCounted
## ITEM THUMBNAILS — small low-quality image previews for inventory items.
##
## Spec (Liam, 2026-07-03 verbatim): "I want a small image preview on the inventory items,
## perhaps a low quality image screenshot of them or something."
##
## HOW IT WORKS (cheap + deterministic, the "low quality image screenshot" route):
##   * Each palette entry (a primitive block shape OR a manifest GLB asset) is rendered ONCE
##     to a tiny (~64px) PNG by a throwaway off-screen SubViewport: a neutral 3/4 camera, one
##     key light, the mesh centred + framed to fill the frame. The pixels are grabbed and
##     saved to a per-host cache dir.
##   * The cache is keyed by a stable id (the palette entry name for blocks, the asset id for
##     assets). A thumbnail already on disk is reused — so the render cost is paid once per
##     machine, on first run, then never again (generated-on-first-run, not committed: the
##     PNGs are per-host derived state, like the .godot cache and the embeddings vectors).
##   * Blocks render synchronously (their mesh is built in-process from the primitive vocab).
##     Assets render as their lazily-loaded GLB template WHEN the AssetLibrary has it; until
##     then the inventory shows the flat colour tint (unchanged) and the thumbnail fills in on
##     a later open once the load has landed.
##
## WHERE: G:/Wavelet/Alethea-cc/state/sandbox/thumbnails/*.png (gitignored Wavelet state — the
## same "load-bearing/derived user state lives OUTSIDE the repo" rule the world store follows;
## overridable via SANDBOX_THUMBNAILS_DIR for tests).
##
## No class_name (mistake #046): consumers preload() this file by path.

const GodotSceneRenderer := preload("res://renderers/godot_scene_renderer.gd")

const DEFAULT_DIR := "G:/Wavelet/Alethea-cc/state/sandbox/thumbnails"
const SIZE := 64                                             # px (low-quality on purpose)

var dir: String = DEFAULT_DIR
var _cache: Dictionary = {}                                  # key -> Texture2D (in-memory, this run)
var _tree: SceneTree = null                                  # needed to add the temp SubViewport


func _init(tree: SceneTree = null, dir_override: String = "") -> void:
	_tree = tree
	var env := OS.get_environment("SANDBOX_THUMBNAILS_DIR")
	if dir_override != "":
		dir = dir_override
	elif env != "":
		dir = env
	DirAccess.make_dir_recursive_absolute(dir)


func _path_for(key: String) -> String:
	# Sanitize the key into a safe filename (asset ids + block names are already tame, but be safe).
	var safe := ""
	for c in key:
		if c.is_valid_identifier() or c == "_" or c == "-":
			safe += c
		else:
			var lc := String(c).to_lower()
			var uc := String(c).to_upper()
			# letters/digits pass; everything else becomes "_"
			if lc != uc or String(c).is_valid_int():
				safe += c
			else:
				safe += "_"
	if safe == "":
		safe = "thumb"
	return dir.path_join("%s.png" % safe)


## True if a thumbnail already exists on disk (in-memory OR cached file) for this key.
func has_thumbnail(key: String) -> bool:
	return _cache.has(key) or FileAccess.file_exists(_path_for(key))


## Return a Texture2D for a key if one is available (memory → disk), else null.
func get_texture(key: String) -> Texture2D:
	if _cache.has(key):
		return _cache[key]
	var p := _path_for(key)
	if FileAccess.file_exists(p):
		var img := Image.load_from_file(p)
		if img != null:
			var tex := ImageTexture.create_from_image(img)
			_cache[key] = tex
			return tex
	return null


## Render a thumbnail for a BLOCK palette entry (primitive shape) — awaits one render frame.
## Returns the Texture2D (and writes the PNG cache). Returns existing if already cached.
func ensure_block(key: String, shape: String, params: Dictionary, albedo: Array) -> Texture2D:
	var existing := get_texture(key)
	if existing != null:
		return existing
	if _tree == null:
		return null
	var mesh := GodotSceneRenderer._primitive_mesh(shape, params)
	if mesh == null:
		return null
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	var mat := StandardMaterial3D.new()
	if typeof(albedo) == TYPE_ARRAY and albedo.size() >= 3:
		mat.albedo_color = Color(albedo[0], albedo[1], albedo[2])
	mi.material_override = mat
	return await _render_node(key, mi)


## Render a thumbnail for a loaded ASSET template (a Node3D from the AssetLibrary).
func ensure_asset(key: String, template: Node3D) -> Texture2D:
	var existing := get_texture(key)
	if existing != null:
		return existing
	if _tree == null or template == null:
		return null
	var inst := template.duplicate() as Node3D
	return await _render_node(key, inst)


## Core: put `subject` (a fresh Node3D not yet in the tree) into a throwaway off-screen
## SubViewport, frame it, render one frame, grab the pixels, save the PNG, free everything.
func _render_node(key: String, subject: Node3D) -> Texture2D:
	var vp := SubViewport.new()
	vp.size = Vector2i(SIZE, SIZE)
	vp.transparent_bg = true
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	vp.own_world_3d = true
	_tree.root.add_child(vp)

	var scene := Node3D.new()
	vp.add_child(scene)
	scene.add_child(subject)

	# Frame the subject: centre it on its AABB, then place a 3/4 camera far enough to fill.
	var aabb := _node_aabb(subject)
	var centre := aabb.get_center()
	var radius := maxf(aabb.size.length() * 0.5, 0.5)
	subject.position -= centre                       # recentre to origin

	var cam := Camera3D.new()
	scene.add_child(cam)
	var dist := radius * 2.6
	cam.position = Vector3(dist * 0.75, dist * 0.65, dist * 0.9)
	cam.look_at(Vector3.ZERO, Vector3.UP)
	cam.fov = 45.0

	var key_light := DirectionalLight3D.new()
	key_light.rotation_degrees = Vector3(-45, -40, 0)
	key_light.light_energy = 1.4
	scene.add_child(key_light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-20, 140, 0)
	fill.light_energy = 0.5
	scene.add_child(fill)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_CLEAR_COLOR
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.6, 0.62, 0.66)
	env.ambient_light_energy = 0.8
	env_node.environment = env
	scene.add_child(env_node)

	# One render pass, then grab.
	await RenderingServer.frame_post_draw
	var img := vp.get_texture().get_image()
	var tex: Texture2D = null
	if img != null:
		var p := _path_for(key)
		img.save_png(p)
		tex = ImageTexture.create_from_image(img)
		_cache[key] = tex
	vp.queue_free()
	return tex


## Combined AABB of every mesh under a node (local to that node).
func _node_aabb(root: Node3D) -> AABB:
	var merged := AABB()
	var found := false
	var stack: Array = [[root, Transform3D.IDENTITY]]
	while not stack.is_empty():
		var top: Array = stack.pop_back()
		var n: Node = top[0]
		var xf: Transform3D = top[1]
		var here := xf
		if n is Node3D and n != root:
			here = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			var a := here * (n as MeshInstance3D).mesh.get_aabb()
			merged = a if not found else merged.merge(a)
			found = true
		for c in n.get_children():
			stack.append([c, here])
	return merged if found else AABB(Vector3(-0.5, -0.5, -0.5), Vector3.ONE)
