extends Node3D
## underground_wave3_proof -- windowed progress-render driver for Wave 3 item 3.1
## (NonOverlappingCavityCarver, renderers/cavity_carver.gd) + the ConstructionSequencer
## (renderers/construction_sequencer.gd), DQ-6963c689. Builds a modest ring-scaffold slice via
## renderers/ring_scaffold.gd, carves cavities into the walls (both shallow niches and
## connect_adjacent through-passages), and drives the OUTERMOST ring's wedge emission through a
## ConstructionSequencer PARTWAY, so the captured frame shows both new pieces at once: the carved
## walls on the two fully-built inner rings, and the outer ring visibly "under construction"
## (only some of its wedges emitted yet). Mirrors ring_scaffold_proof.gd's own `--shot` capture
## convention (RenderingServer.frame_post_draw + get_viewport capture idiom).
##
## The camera is framed DYNAMICALLY off an actual carved through-passage's world position (picked
## after carving runs) rather than a guessed fixed transform -- a small cavity is otherwise
## invisible against a 5-14m-radius ring from any generic wide shot.
##
##   <godot> --path godot res://underground_wave3_proof.tscn -- --shot
## writes godot/live/underground_wave3_proof.png after a few frames, then quits.

const SHOT_OUT_DETAIL := "res://live/underground_wave3_proof_detail.png"
const SHOT_OUT_WIDE := "res://live/underground_wave3_proof_wide.png"

var _shot_frames := 0
var _wide_mode := false
var _shot_out := SHOT_OUT_DETAIL

func _ready() -> void:
	_wide_mode = "--wide" in OS.get_cmdline_user_args() or "--wide" in OS.get_cmdline_args()
	_shot_out = SHOT_OUT_WIDE if _wide_mode else SHOT_OUT_DETAIL
	_build_scene()

func _build_env(focus: Vector3, wall_normal: Vector3) -> void:
	var cam := Camera3D.new()
	if _wide_mode:
		# Overview: outside the whole 3-ring structure, 3/4 angle -- shows the two fully-built
		# inner rings alongside the outer ring's PARTIAL (ConstructionSequencer, ~60%) wedge set,
		# and the amber through-passages as small bright accents (context, not detail).
		var cpos := Vector3(4.0, 16.0, 20.0)
		cam.transform = Transform3D(Basis.looking_at(Vector3(0.0, 1.0, 0.0) - cpos, Vector3.UP), cpos)
		cam.fov = 50.0
	else:
		# Detail: stand back from a real carved cavity's position along its own wall-normal (+Z of
		# the cavity's transform = AWAY from the shell material = back toward the corridor
		# interior, per wall_surface_uv's own "-Z points into the shell material" convention) -- a
		# SMALL offset, since a hallway cross-section is only ~2-3m across; a large offset
		# overshoots clean through the opposite wall and out the far side of the next ring entirely.
		var cpos := focus + wall_normal * 1.4 + Vector3(0.0, 0.4, 0.0)
		cam.transform = Transform3D(Basis.looking_at(focus - cpos, Vector3.UP), cpos)
		cam.fov = 65.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.15
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = cam.transform.origin + Vector3(0.0, 1.0, 0.0)
	fill.light_energy = 3.0
	fill.omni_range = 12.0
	add_child(fill)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.09)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.42, 0.32)
	env.ambient_light_energy = 0.75
	env_node.environment = env
	add_child(env_node)

func _build_scene() -> void:
	var ring_count := 3
	var gap := 4.5
	var radius_start := 5.0
	var segment_arc_deg := 20.0

	var topo := RingScaffoldGenerator.build_topology(ring_count, radius_start, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)

	# Cavity carving FIRST (connect_adjacent, depth=1.0, shape=mix) -- both so the camera can be
	# framed off a REAL carved cavity's position (below) and because carving only ever consumes
	# wall_surface_uv, never the wedge meshes themselves, so ordering vs. mesh-building doesn't
	# matter to correctness.
	var carve_result := NonOverlappingCavityCarver.carve(topo, wall_by_ring,
		{"shape": "mix", "min_spacing": 1.8, "density": 0.85, "depth": 1.0, "seed": 2026,
		"cavity_size": 0.85, "max_carve_depth": 1.6})
	var instances: Array = carve_result["cavity_instances"]

	# Pick a representative THROUGH cavity (ring 1<->2, the two FULLY-built rings) to frame the
	# camera on -- falls back to any instance if none happened to land there for some tunable combo.
	var focus_inst: Dictionary = {}
	for inst in instances:
		if inst["through"] and int(inst["ring"]) == 1:
			focus_inst = inst
			break
	if focus_inst.is_empty() and instances.size() > 0:
		focus_inst = instances[0]
	var focus_transform: Transform3D = focus_inst.get("transform", Transform3D())
	_build_env(focus_transform.origin, focus_transform.basis.z)

	var wall_mat := StandardMaterial3D.new()
	wall_mat.albedo_color = Color(0.55, 0.5, 0.42)
	wall_mat.roughness = 0.85

	var niche_mat := StandardMaterial3D.new()
	niche_mat.albedo_color = Color(0.22, 0.14, 0.09)
	niche_mat.roughness = 0.9

	var through_mat := StandardMaterial3D.new()
	through_mat.albedo_color = Color(0.85, 0.6, 0.28)
	through_mat.emission_enabled = true
	through_mat.emission = Color(0.6, 0.35, 0.08)
	through_mat.emission_energy_multiplier = 0.6
	through_mat.roughness = 0.5

	# Rings 1-2: FULLY built (every wedge instanced directly) -- these are the rings whose carved
	# walls (shallow niches + the connect-adjacent through-passage between them) the shot is meant
	# to show clearly.
	var built_chunks := 0
	for ring_data in topo:
		var ring_index: int = int(ring_data["ring"])
		if ring_index == ring_count:
			continue  # outermost ring: built incrementally below, via ConstructionSequencer
		var chunks := RingScaffoldGenerator.wedge_chunks([ring_data], segment_arc_deg, gap)
		for chunk in chunks:
			var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = wall_mat
			add_child(mi)
			built_chunks += 1

	# Outermost ring: driven through ConstructionSequencer, stopped PARTWAY -- the "node by node"
	# visible-construction snapshot. ring-by-ring order with a small tick so a single big advance()
	# call reproducibly lands partway through this ring's own wedge count.
	var outer_ring_data: Dictionary = topo[ring_count - 1]
	var outer_chunks := RingScaffoldGenerator.wedge_chunks([outer_ring_data], segment_arc_deg, gap)
	var sequencer := ConstructionSequencer.build(outer_chunks, {"ordering_mode": "ring-by-ring", "tick_interval_ms": 40})
	var target_fraction := 0.6
	var events := sequencer.advance(float(sequencer.total()) * target_fraction * 40.0)
	for event in events:
		var chunk: Dictionary = event["chunk"]
		var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = wall_mat
		add_child(mi)
		built_chunks += 1

	# Instance every carved cavity's mesh -- shallow niches (dark recess material) and
	# connect_adjacent through-passages (warm amber-emissive, foreshadowing the plan's own
	# amber-light-cube tier that will occupy these same openings later).
	var niche_count := 0
	var through_count := 0
	for inst in instances:
		var mesh: Mesh = inst["mesh"]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = through_mat if inst["through"] else niche_mat
		add_child(mi)
		if inst["through"]:
			through_count += 1
		else:
			niche_count += 1

	print("[underground_wave3_proof] built %d/%d wedges (rings 1-%d full, ring %d at %.0f%% via ConstructionSequencer); carved %d niches + %d through-passages (%d cavity_cutaway_field entries)" %
		[built_chunks, built_chunks + (outer_chunks.size() - events.size()), ring_count - 1, ring_count,
		sequencer.progress() * 100.0, niche_count, through_count, (carve_result["cavity_cutaway_field"] as Array).size()])

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_shot_out)
		print("[underground_wave3_proof] captured -> ", _shot_out)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
