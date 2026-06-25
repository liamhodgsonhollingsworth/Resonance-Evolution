extends SceneTree
## Headless proof of Character Increment A — a FLAME-style genome on a wire, two style_modes.
##
##   godot --headless --path godot -s res://headless_character_test.gd
##
## Proves the whole proof-slice end to end, reusing the already-shipped seams (zero floor edits):
##   (A) the Python resolver (tools/character_resolver.py) turns a genome VECTOR into a GLB WITH MORPH
##       TARGETS, surfaced as a renderer-neutral scene_node { mesh.source="character", genome, glb,
##       morph_weights } — JSON round-trippable DATA, no live Godot object on the wire;
##   (B) the Godot delegate (GodotSceneRenderer.build_node, the "character" branch added this increment)
##       builds a live mesh from the descriptor, the imported mesh CARRIES blend shapes (the morph
##       targets), and morph_weights drive the blend-shape values (live tunability);
##   (C) the engine's own exporter ROUND-TRIPS the morph targets (the gltf_exporter.gd gap closed:
##       Godot append_from_scene preserves the imported blend shapes) — re-import still has them;
##   (D) TWO genomes → two VISIBLY DIFFERENT valid faces (the spec's distinctness gate, in-engine);
##   (E) the SAME genome under the two `modulate` style_mode Contexts (realistic vs arcane) renders
##       TWO DISTINCT FRAMES — realistic (stylize_amount:0, no effects) vs arcane (stylize_amount:1 +
##       the painterly effect_stack) — over the SAME character + effect nodes, only overrides differ.
##
## The external glTF-validator + three.js parity + the cross-renderer distinctness oracle run
## separately (godot/oracle/validate_glb.mjs + character_oracle.mjs) on the GLBs this test writes.

const LIVE := "res://live"
const PY_REL := "tools/character_resolver.py"   # repo-root-relative (sibling of godot/)

func _initialize() -> void:
	var ok := true

	# Resolve two DISTINCT genomes (realistic) + a same-genome arcane variant, via the Python resolver.
	var face_a := LIVE + "/char_a.glb"
	var face_b := LIVE + "/char_b.glb"
	var face_arcane := LIVE + "/char_a_arcane.glb"
	DirAccess.make_dir_recursive_absolute(LIVE)
	ok = _check("resolver produced face A (genome 1)",
		_run_resolver(["--identity", "1.5", "0.0", "-0.8", "0.3", "--expression", "0.2", "0.0",
			"--stylize-amount", "0.0", "--out", _abs(face_a)])) and ok
	ok = _check("resolver produced face B (genome 2, distinct identity)",
		_run_resolver(["--identity", "-0.6", "1.2", "0.4", "-0.9", "--expression", "-0.1", "0.5",
			"--stylize-amount", "0.0", "--out", _abs(face_b)])) and ok
	ok = _check("resolver produced face A arcane (same genome, stylize_amount=1)",
		_run_resolver(["--identity", "1.5", "0.0", "-0.8", "0.3", "--expression", "0.2", "0.0",
			"--stylize-amount", "1.0", "--out", _abs(face_arcane)])) and ok
	ok = _check("face A GLB on disk", FileAccess.file_exists(face_a)) and ok
	ok = _check("face B GLB on disk", FileAccess.file_exists(face_b)) and ok

	# (A) The scene_node descriptor: source="character", JSON round-trippable, carries the genome.
	var desc_a := _character_desc("char_a", face_a, { "expr0": 0.2 },
		{ "kind": "character", "identity": [1.5, 0.0, -0.8, 0.3], "stylize_amount": 0.0 })
	ok = _check("character descriptor matches is_scene_node",
		GodotSceneRenderer.is_scene_node(desc_a)) and ok
	ok = _check("character descriptor mesh.source == 'character'",
		String((desc_a["mesh"] as Dictionary).get("source")) == "character") and ok
	ok = _check("character descriptor is JSON round-trippable (no live objects)",
		typeof(JSON.parse_string(JSON.stringify(desc_a))) == TYPE_DICTIONARY) and ok

	# (B) The Godot delegate builds a live mesh that CARRIES blend shapes (the morph targets).
	var node_a := GodotSceneRenderer.build_node(desc_a)
	get_root().add_child(node_a)
	var mi_a := _first_mesh_instance(node_a)
	ok = _check("delegate built a MeshInstance3D for the character", mi_a != null) and ok
	ok = _check("imported character mesh carries blend shapes (morph targets)",
		mi_a != null and mi_a.mesh != null and mi_a.mesh.get_blend_shape_count() > 0) and ok

	# (B') morph_weights from the descriptor drive the live blend-shape value (tunable face).
	if mi_a != null and mi_a.mesh != null and mi_a.mesh.get_blend_shape_count() > 0:
		var w0 := mi_a.get_blend_shape_value(0)
		ok = _check("morph_weights applied to blend-shape 0 (== 0.2 from the genome)",
			abs(w0 - 0.2) < 1e-3) and ok

	# (C) The engine's exporter ROUND-TRIPS morph targets (the gltf_exporter gap closed). Export the
	# character descriptor through GltfExporter, re-import, and assert the blend shapes survive.
	var export_path := LIVE + "/char_a_exported.glb"
	var wrote := GltfExporter.export_to_file([desc_a], export_path)
	ok = _check("character exported through GltfExporter", wrote == OK and FileAccess.file_exists(export_path)) and ok
	var reimport_blends := _blend_shape_count_of_glb(export_path)
	ok = _check("exported GLB re-imports WITH morph targets (round-trip preserved blend shapes)",
		reimport_blends > 0) and ok

	# (D) Two genomes → two VISIBLY DIFFERENT faces (in-engine vertex comparison).
	var node_b := GodotSceneRenderer.build_node(_character_desc("char_b", face_b, {}, {}))
	get_root().add_child(node_b)
	var mi_b := _first_mesh_instance(node_b)
	ok = _check("face A and face B are geometrically DISTINCT (different genomes)",
		mi_a != null and mi_b != null and _meshes_distinct(mi_a.mesh, mi_b.mesh)) and ok

	# (E) The SAME genome under the two style_mode Contexts → two DISTINCT FRAMES. realistic uses the
	# realistic-stylize GLB + empty effect_stack; arcane uses the arcane-stylize GLB + the painterly
	# effect_stack. Both Context configs are DATA (godot/contexts/*.json), modulate handler, same nodes.
	var ctx_real: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://contexts/style_mode_realistic.json"))
	var ctx_arc: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://contexts/style_mode_arcane.json"))
	ok = _check("style_mode_realistic.json loaded (handler=modulate)",
		ctx_real != null and String(ctx_real.get("handler")) == "modulate") and ok
	ok = _check("style_mode_arcane.json loaded (handler=modulate, default arcane)",
		ctx_arc != null and String(ctx_arc.get("handler")) == "modulate"
		and String(ctx_arc.get("style_mode")) == "arcane") and ok

	# Render each style_mode to a frame: rasterize the resolved character to an Image, then apply the
	# Context's effect_stack override via EffectStackCpu (the shipped CPU oracle). Distinct frames prove
	# style_mode is a Context over identical nodes, and the boil-down (geometry + paint) is free.
	var stylize_real := float(((ctx_real.get("modulation", {}) as Dictionary).get("character", {}) as Dictionary).get("stylize_amount", 0.0))
	var stylize_arc := float(((ctx_arc.get("modulation", {}) as Dictionary).get("character", {}) as Dictionary).get("stylize_amount", 1.0))
	ok = _check("realistic Context overrides stylize_amount -> 0", stylize_real == 0.0) and ok
	ok = _check("arcane Context overrides stylize_amount -> 1", stylize_arc == 1.0) and ok

	var stack_real: Array = ((ctx_real.get("modulation", {}) as Dictionary).get("effect", {}) as Dictionary).get("effect_stack", [])
	var stack_arc: Array = ((ctx_arc.get("modulation", {}) as Dictionary).get("effect", {}) as Dictionary).get("effect_stack", [])
	ok = _check("realistic effect_stack is empty (no paint)", stack_real.is_empty()) and ok
	ok = _check("arcane effect_stack is the painterly NPR pass (kuwahara..paper_grain)",
		stack_arc.size() == 5) and ok

	# The two frames: the realistic genome render with NO effects vs the arcane genome render WITH the
	# painterly stack. Use the resolved meshes' projected silhouettes as the source frame (a cheap
	# deterministic raster), then run EffectStackCpu. Distinct geometry + distinct effects => distinct.
	var frame_real := _silhouette_frame(mi_a.mesh)                      # realistic geometry, no paint
	var node_arc := GodotSceneRenderer.build_node(_character_desc("char_a_arc", face_arcane, {}, {}))
	var mi_arc := _first_mesh_instance(node_arc)
	var frame_arc_src := _silhouette_frame(mi_arc.mesh)                 # arcane geometry
	var frame_arc := EffectStackCpu.apply({ "stack": stack_arc }, frame_arc_src)  # + painterly paint
	var frame_real_painted := EffectStackCpu.apply({ "stack": stack_real }, frame_real)
	ok = _check("realistic frame (empty stack) == its source (no-op paint)",
		_images_equal(frame_real, frame_real_painted)) and ok
	ok = _check("style_mode realistic vs arcane => TWO DISTINCT FRAMES (same character, two Contexts)",
		not _images_equal(frame_real, frame_arc)) and ok

	# Free the off-tree node built for the arcane silhouette (the on-tree node_a/node_b are freed by the
	# SceneTree at quit). Keeps the headless run leak-clean.
	if node_arc != null:
		node_arc.free()

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- resolver invocation ---------------------------------------------------------------------

func _abs(res_path: String) -> String:
	return ProjectSettings.globalize_path(res_path)

func _repo_root() -> String:
	# godot/ is the project dir; the resolver lives one level up (repo root).
	var godot_dir := ProjectSettings.globalize_path("res://")
	return godot_dir.path_join("..").simplify_path()

func _run_resolver(args: Array) -> bool:
	var script := _repo_root().path_join(PY_REL)
	if not FileAccess.file_exists(script):
		push_warning("resolver script not found at %s" % script)
		return false
	var full := [script]
	full.append_array(args)
	var out := []
	# `py` is the Windows launcher convention in this repo; fall back to python3 elsewhere.
	var code := OS.execute("py", full, out, true)
	if code != 0:
		code = OS.execute("python3", full, out, true)
	if code != 0:
		push_warning("resolver failed (code %d): %s" % [code, "\n".join(out)])
		return false
	return true

# --- descriptor + scene helpers --------------------------------------------------------------

func _character_desc(nm: String, glb: String, morph_weights: Dictionary, genome: Dictionary) -> Dictionary:
	return {
		"name": nm,
		"translation": [0.0, 0.0, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0],
		"scale": [1.0, 1.0, 1.0],
		"mesh": {
			"source": "character",
			"genome": genome,
			"glb": ProjectSettings.globalize_path(glb),
			"morph_weights": morph_weights,
		},
		"children": [],
	}

func _first_mesh_instance(node: Node) -> MeshInstance3D:
	if node is MeshInstance3D:
		return node
	for c in node.get_children():
		var r := _first_mesh_instance(c)
		if r != null:
			return r
	return null

func _blend_shape_count_of_glb(path: String) -> int:
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	if doc.append_from_file(ProjectSettings.globalize_path(path), st) != OK:
		return 0
	var scene := doc.generate_scene(st)
	if scene == null:
		return 0
	var mi := _first_mesh_instance(scene)
	var n := 0
	if mi != null and mi.mesh != null:
		n = mi.mesh.get_blend_shape_count()
	scene.queue_free()
	return n

func _meshes_distinct(a: Mesh, b: Mesh) -> bool:
	var va := _verts_of(a)
	var vb := _verts_of(b)
	if va.size() != vb.size() or va.is_empty():
		return va.size() != vb.size()
	var diff := 0.0
	for i in va.size():
		diff += (va[i] - vb[i]).length()
	return (diff / va.size()) > 1e-4

func _verts_of(m: Mesh) -> PackedVector3Array:
	var out := PackedVector3Array()
	if m == null:
		return out
	for s in m.get_surface_count():
		var arr := m.surface_get_arrays(s)
		if arr.size() > Mesh.ARRAY_VERTEX and arr[Mesh.ARRAY_VERTEX] != null:
			out.append_array(arr[Mesh.ARRAY_VERTEX])
	return out

# A cheap, deterministic raster of a mesh's silhouette into a fixed-size Image — enough to make two
# DIFFERENT geometries produce two DIFFERENT frames without standing up a full viewport/camera. Each
# vertex is orthographically projected (XY) into a WxH luminance buffer. Distinct geometry => distinct
# buffer; the effect_stack then layers the painted look on top.
const FRAME_W := 64
const FRAME_H := 64
func _silhouette_frame(m: Mesh) -> Image:
	var img := Image.create(FRAME_W, FRAME_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.15, 0.15, 0.2, 1.0))
	var verts := _verts_of(m)
	if verts.is_empty():
		return img
	var minv := verts[0]
	var maxv := verts[0]
	for v in verts:
		minv = minv.min(v)
		maxv = maxv.max(v)
	var span := (maxv - minv)
	span.x = maxf(span.x, 1e-3); span.y = maxf(span.y, 1e-3); span.z = maxf(span.z, 1e-3)
	for v in verts:
		var px := int(clampf((v.x - minv.x) / span.x, 0.0, 1.0) * (FRAME_W - 1))
		var py := int(clampf((v.y - minv.y) / span.y, 0.0, 1.0) * (FRAME_H - 1))
		# depth -> shade, so the geometry difference reads as a luminance difference.
		var shade := clampf((v.z - minv.z) / span.z, 0.0, 1.0)
		img.set_pixel(px, py, Color(shade, shade * 0.9, shade * 0.8, 1.0))
	return img

func _images_equal(a: Image, b: Image) -> bool:
	if a.get_width() != b.get_width() or a.get_height() != b.get_height():
		return false
	return a.get_data() == b.get_data()

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
