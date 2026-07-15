extends Node3D
## underground_wave3_rock_floor_proof -- windowed progress-render driver for Wave 3 item 3.2
## (ProceduralRockTexture, renderers/procedural_rock_texture.gd + ReflectiveFloorMaterial,
## renderers/reflective_floor_material.gd), DQ-2e1202ca. Reuses the SAME ring-scaffold + cavity-
## carve setup underground_wave3_proof.gd (DQ-6963c689) already proved, swapping its flat-color
## `wall_mat` for a real synthesized rock texture and adding a solid-color glossy REFLECTIVE floor
## slab beneath the structure -- so this shot demonstrates nodes 3+4 actually composing with the
## already-merged nodes 1+2+8 (RingScaffoldGenerator / ConstructionSequencer / NonOverlappingCavityCarver,
## PRs #189-191), not a standalone toy scene.
##
## Two shots, mirroring underground_wave3_proof.gd's own --wide convention:
##   <godot> --path godot res://underground_wave3_rock_floor_proof.tscn -- --shot
##     writes godot/live/underground_wave3_rock_floor_proof_wide.png -- structure + floor
##     reflection, the framing that sells node 4 (ReflectiveFloorMaterial/SSR).
##   <godot> --path godot res://underground_wave3_rock_floor_proof.tscn -- --shot --detail
##     writes godot/live/underground_wave3_rock_floor_proof_detail.png -- close on the rock wall,
##     the framing that sells node 3 (ProceduralRockTexture)'s actual surface detail.

const SHOT_OUT_WIDE := "res://live/underground_wave3_rock_floor_proof_wide.png"
const SHOT_OUT_DETAIL := "res://live/underground_wave3_rock_floor_proof_detail.png"

var _shot_frames := 0
var _detail_mode := false
var _shot_out := SHOT_OUT_WIDE

func _ready() -> void:
	_detail_mode = "--detail" in OS.get_cmdline_user_args() or "--detail" in OS.get_cmdline_args()
	_shot_out = SHOT_OUT_DETAIL if _detail_mode else SHOT_OUT_WIDE
	_build_scene()

func _build_env(env: Environment, floor_y: float) -> void:
	var cam := Camera3D.new()
	if _detail_mode:
		# Close on the rock-textured outer wall of the inner ring -- shows the layered
		# fbm+voronoi+value_noise surface detail at a legible scale (the wide shot's texture reads
		# as a small mottled patch from a distance; this is the "is it actually rock, not a flat
		# color" proof).
		var cpos := Vector3(3.6, 0.6, 5.4)
		var target := Vector3(0.0, 0.4, 0.0)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 45.0
	else:
		# Low, grazing-angle vantage just above the floor slab, well outside the ring structure --
		# this is the framing that actually SELLS a reflective floor (a top-down or distant shot
		# foreshortens SSR's reflection away almost entirely). Looking back toward the ring structure
		# from floor height so the rock-textured outer wall is mirrored in the glossy floor in front of it.
		var cpos := Vector3(15.0, floor_y + 2.2, 17.0)
		var target := Vector3(0.0, floor_y + 1.0, 0.0)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 55.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -50, 0)
	light.light_energy = 1.3
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(6.0, floor_y + 3.0, 10.0)
	fill.light_energy = 4.0
	fill.omni_range = 20.0
	add_child(fill)
	var env_node := WorldEnvironment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.05, 0.06, 0.08)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.5, 0.44, 0.34)
	env.ambient_light_energy = 0.7
	env_node.environment = env
	add_child(env_node)

func _build_scene() -> void:
	var ring_count := 2
	var gap := 4.5
	var radius_start := 5.0
	var segment_arc_deg := 20.0

	var topo := RingScaffoldGenerator.build_topology(ring_count, radius_start, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)

	var carve_result := NonOverlappingCavityCarver.carve(topo, wall_by_ring,
		{"shape": "mix", "min_spacing": 1.8, "density": 0.85, "depth": 1.0, "seed": 2026,
		"cavity_size": 0.85, "max_carve_depth": 1.6})
	var instances: Array = carve_result["cavity_instances"]

	# node 3: the wall material -- ONE synthesized rock tile shared across every wedge (a single
	# StandardMaterial3D instance, so Godot batches them; matches wall_mat's own reuse pattern in
	# underground_wave3_proof.gd).
	var rock_mat := ProceduralRockTexture.build_material(
		{"noise_seed": 4177, "noise_scale": 6.0, "palette_handle": "slate"},
		wall_by_ring.get(1, {}))

	var niche_mat := StandardMaterial3D.new()
	niche_mat.albedo_color = Color(0.22, 0.14, 0.09)
	niche_mat.roughness = 0.9

	var through_mat := StandardMaterial3D.new()
	through_mat.albedo_color = Color(0.85, 0.6, 0.28)
	through_mat.emission_enabled = true
	through_mat.emission = Color(0.6, 0.35, 0.08)
	through_mat.emission_energy_multiplier = 0.6
	through_mat.roughness = 0.5

	# node 4: the reflective floor -- material + environment SSR patch (the two-piece descriptor
	# build() returns; a scene driver is exactly the caller that has both a floor mesh AND a
	# WorldEnvironment to wire it onto). floor_y (bottom of the outer ellipse -- same _shell_extents
	# math ring_scaffold.gd's build_wedge_mesh uses: hh_outer = (gap/2) * DEFAULT_ELLIPSE_RATIO)
	# is computed here, before the camera is framed, so the camera can be positioned relative to it.
	var floor_result := ReflectiveFloorMaterial.build(
		{"base_color": Color(0.08, 0.09, 0.12), "gloss": 0.9, "reflection_mode": "ssr"})
	var floor_mat: StandardMaterial3D = floor_result["material"]
	var env := Environment.new()
	ReflectiveFloorMaterial.apply_environment(env, floor_result["environment_patch"])
	var hh_outer := (gap * 0.5) * RingScaffoldGenerator.DEFAULT_ELLIPSE_RATIO
	var floor_y := -hh_outer - 0.05
	_build_env(env, floor_y)

	var built_chunks := 0
	for ring_data in topo:
		var chunks := RingScaffoldGenerator.wedge_chunks([ring_data], segment_arc_deg, gap)
		for chunk in chunks:
			var mesh := RingScaffoldGenerator.build_wedge_mesh(chunk)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = rock_mat
			add_child(mi)
			built_chunks += 1

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

	# Floor slab: a large flat box (PlaneMesh would work too, but a thin box gives the slab visible
	# depth/edge from a low camera angle) sized to span the whole 2-ring structure, sat at floor_y
	# (computed above, before the camera).
	var outer_radius: float = radius_start + gap * float(ring_count - 1) + gap * 0.6
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(outer_radius * 2.2, 0.1, outer_radius * 2.2)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = floor_mat
	floor_mi.position = Vector3(0.0, floor_y - 0.05, 0.0)
	add_child(floor_mi)

	print("[underground_wave3_rock_floor_proof] built %d wedges (rock texture: seed=4177 scale=6.0 palette=slate); carved %d niches + %d through-passages; floor y=%.2f ssr_enabled=%s" %
		[built_chunks, niche_count, through_count, floor_y, str(env.ssr_enabled)])

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_shot_out)
		print("[underground_wave3_rock_floor_proof] captured -> ", _shot_out)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
