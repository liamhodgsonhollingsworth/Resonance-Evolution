extends Node3D
## ring_scaffold_proof — windowed progress-render driver for RingScaffoldGenerator (Wave 2 item
## 2.1, increment 1). Builds a modest slice of concentric-ring hallway wedges via
## renderers/ring_scaffold.gd and captures ONE PNG — the progress image for
## Alethea-cc/state/discord_outbox_media/underground/. Mirrors render_view.gd's own `--shot`
## capture convention (same RenderingServer.frame_post_draw + get_viewport capture idiom).
##
##   <godot> --path godot res://ring_scaffold_proof.tscn -- --shot
## writes godot/live/ring_scaffold_proof.png after a few frames, then quits.

const SHOT_OUT := "res://live/ring_scaffold_proof.png"

var _shot_frames := 0

func _ready() -> void:
	_build_env()
	_build_rings()

func _build_env() -> void:
	var cam := Camera3D.new()
	var cpos := Vector3(0.0, 20.0, 19.0)
	cam.transform = Transform3D(Basis.looking_at(Vector3.ZERO - cpos, Vector3.UP), cpos)
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

func _build_rings() -> void:
	# A modest slice for the progress image: 4 rings at the confirmed topology (flat concentric,
	# single elevation), coarser arc chunking (30deg vs. the spec default 15deg) so this PROOF
	# render is cheap -- not the final scene's chunk granularity.
	var topo := RingScaffoldGenerator.build_topology(4, RingScaffoldGenerator.DEFAULT_RADIUS_START,
		RingScaffoldGenerator.DEFAULT_GAP, RingScaffoldGenerator.DEFAULT_ELEVATION)
	var chunks := RingScaffoldGenerator.wedge_chunks(topo, 30.0, RingScaffoldGenerator.DEFAULT_GAP)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.55, 0.5, 0.42)
	mat.roughness = 0.85
	for chunk in chunks:
		var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = mat
		add_child(mi)
	print("[ring_scaffold_proof] built %d wedge meshes across %d rings" % [chunks.size(), topo.size()])

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
