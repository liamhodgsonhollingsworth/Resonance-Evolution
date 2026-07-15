extends Node3D
## ring_scaffold_proof — windowed progress-render driver for RingScaffoldGenerator (Wave 2 item
## 2.1). Builds a modest slice of concentric-ring hallway wedges via renderers/ring_scaffold.gd and
## captures ONE PNG — the progress image for Alethea-cc/state/discord_outbox_media/underground/.
## Mirrors render_view.gd's own `--shot` capture convention (same RenderingServer.frame_post_draw +
## get_viewport capture idiom).
##
##   <godot> --path godot res://ring_scaffold_proof.tscn -- --shot
## writes godot/live/ring_scaffold_proof.png after a few frames, then quits.
##
## INCREMENT 2 (DQ-e9516770) additions to this proof render, so the progress image actually shows
## the new work rather than looking identical to increment 1's screenshot:
##   - a procedural checker StandardMaterial3D (built from build_wedge_mesh's now-real per-vertex
##     UVs — increment 1 had no UVs, so a checker here would have rendered as a flat solid color)
##     applied to the two INNER rings, so the wall UV-unwrap is visibly legible in the shot.
##   - the two OUTER rings built with `dome_apex_height` set, so the roof-convergence shaping (the
##     "two shells converge at a point near the roof" ceiling) is visible alongside the plain-ellipse
##     inner rings for direct comparison in one frame.

const SHOT_OUT := "res://live/ring_scaffold_proof.png"

var _shot_frames := 0

func _ready() -> void:
	_build_env()
	_build_rings()

func _build_env() -> void:
	var cam := Camera3D.new()
	var cpos := Vector3(0.0, 15.0, 22.0)  # 3/4 angle -- shows the domed outer rings' rise AND the inner rings' checker UV in one frame
	cam.transform = Transform3D(Basis.looking_at(Vector3(0.0, 1.0, 0.0) - cpos, Vector3.UP), cpos)
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.1
	add_child(light)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.42, 0.32)  # warm, matches the scene's amber-light direction
	env.ambient_light_energy = 0.7
	env_node.environment = env
	add_child(env_node)

## A small procedural black/amber checker ImageTexture — cheap, dependency-free, and legible against
## build_wedge_mesh's real UVs (proves the wall UV-unwrap: without real per-vertex UVs this would
## render as one flat color, exactly increment 1's look).
func _checker_texture() -> ImageTexture:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	for y in size:
		for x in size:
			var on := ((x / 8) % 2) == ((y / 8) % 2)
			img.set_pixel(x, y, Color(0.75, 0.55, 0.25) if on else Color(0.12, 0.1, 0.08))
	return ImageTexture.create_from_image(img)

func _build_rings() -> void:
	# A modest slice for the progress image: 4 rings at the confirmed topology (flat concentric,
	# single elevation), coarser arc chunking (30deg vs. the spec default 15deg) so this PROOF
	# render is cheap -- not the final scene's chunk granularity.
	var topo := RingScaffoldGenerator.build_topology(4, RingScaffoldGenerator.DEFAULT_RADIUS_START,
		RingScaffoldGenerator.DEFAULT_GAP, RingScaffoldGenerator.DEFAULT_ELEVATION)

	var checker_mat := StandardMaterial3D.new()
	checker_mat.albedo_texture = _checker_texture()
	checker_mat.roughness = 0.85
	checker_mat.uv1_scale = Vector3(1.5, 3.0, 1.0)  # tile the checker legibly at hallway scale

	var domed_mat := StandardMaterial3D.new()
	domed_mat.albedo_color = Color(0.6, 0.52, 0.4)
	domed_mat.roughness = 0.7

	var total_chunks := 0
	var glb_out_dir := "res://live/ring_scaffold_proof_glb"
	var all_meshes: Dictionary = {}
	for ring_data in topo:
		var ring_index: int = int(ring_data["ring"])
		# Inner 2 rings: plain ellipse, checker-textured (shows the UV-unwrap). Outer 2 rings:
		# dome_apex_height set, plain material (shows roof convergence) -- side by side in one shot.
		var domed := ring_index > 2
		var chunks := RingScaffoldGenerator.wedge_chunks([ring_data], 30.0, RingScaffoldGenerator.DEFAULT_GAP)
		for chunk in chunks:
			var mesh: Mesh
			if domed:
				mesh = RingScaffoldGenerator.build_wedge_mesh(chunk, RingScaffoldGenerator.DEFAULT_WALL_THICKNESS,
					RingScaffoldGenerator.DEFAULT_ELLIPSE_RATIO, 8, 2, 4.5)
			else:
				mesh = RingScaffoldGenerator.build_wedge_mesh(chunk)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = domed_mat if domed else checker_mat
			add_child(mi)
			all_meshes["%d_%d" % [ring_index, int(chunk["arc"])]] = mesh
			total_chunks += 1
	# Increment 2: also exercise the actual per-chunk GLB export path on this same slice, so the
	# proof render doubles as a live smoke check of export_wedge_chunks_glb (not just the headless
	# unit test) -- writes into the gitignored godot/live/ tree, not committed.
	var export_errors := RingScaffoldGenerator.export_wedge_chunks_glb(all_meshes, glb_out_dir)
	var export_ok := 0
	for k in export_errors.keys():
		if int(export_errors[k]) == OK:
			export_ok += 1
	print("[ring_scaffold_proof] built %d wedge meshes across %d rings (2 plain checker-UV, 2 dome_apex_height=4.5); GLB export %d/%d OK -> %s" %
		[total_chunks, topo.size(), export_ok, export_errors.size(), glb_out_dir])

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(SHOT_OUT)
		print("[ring_scaffold_proof] captured -> ", SHOT_OUT)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
