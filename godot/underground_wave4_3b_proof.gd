extends Node3D
## underground_wave4_3b_proof -- progress-render driver for Wave 4 item 4.3 (B) PlantScatterInCavities,
## DQ-6c2dc2f2. Composes every already-merged Wave 1-4 primitive (RingScaffoldGenerator,
## NonOverlappingCavityCarver, ProceduralRockTexture, ReflectiveFloorMaterial, AmberLightCubeScatterer,
## RoofGlowCutoff, AtmosphericFogVolume -- reusing underground_wave4_proof.gd's own scene-build shape,
## same wave4_best_tunables.json) with the NEW node: `PlantScatterInCavities.scatter()` placing
## procedural L-system plants into the floor-level (`cavity_cutaway_field`) cavities, instanced via
## `GodotSceneRenderer.build_static_tree()` (REUSE -- the same renderer-neutral scene_node -> live
## Node3D builder the graph runtime and glTF exporter already share; no new instancing code).
##
## Camera pose is the SAME "underground_halls_wave4" establishing shot underground_wave4_proof.gd
## uses, so this render is directly comparable (same reference-camera-score baseline before/after
## plants land).
##
##   <godot> --path godot res://underground_wave4_3b_proof.tscn -- --shot
##     writes godot/live/underground_wave4_3b_proof.png

const SHOT_OUT_WIDE := "res://live/underground_wave4_3b_proof.png"
const SHOT_OUT_DETAIL := "res://live/underground_wave4_3b_proof_detail.png"
const BEST_TUNABLES_PATH := "res://wave4_best_tunables.json"

var _shot_frames := 0
var _detail_mode := false
var _shot_out := SHOT_OUT_WIDE

func _ready() -> void:
	_detail_mode = "--detail" in OS.get_cmdline_user_args() or "--detail" in OS.get_cmdline_args()
	_shot_out = SHOT_OUT_DETAIL if _detail_mode else SHOT_OUT_WIDE
	_build_scene()

func _load_json_dict(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	return parsed if parsed is Dictionary else {}

func _color_from_json(v, fallback: Color) -> Color:
	if v is Array and v.size() >= 3:
		var a: float = float(v[3]) if v.size() > 3 else 1.0
		return Color(float(v[0]), float(v[1]), float(v[2]), a)
	return fallback

func _build_camera(cavity_focus: Vector3, have_focus: bool) -> void:
	var cam := Camera3D.new()
	if _detail_mode and have_focus:
		# DYNAMIC framing off a real carved (floor-level/cutaway) cavity's own position -- a fixed
		# guessed pose was invisible at ring scale for the Wave 3 proof's own cavity shots (see
		# underground_wave3_proof.gd's header note); same lesson applies here, the cutaway cavities
		# this module targets sit wherever the carver's connect_adjacent seed happened to place them.
		var cpos := cavity_focus + Vector3(2.6, 1.6, 4.2)
		var look_target := cavity_focus + Vector3(0.0, 0.9, 0.0)
		cam.transform = Transform3D(Basis.looking_at(look_target - cpos, Vector3.UP), cpos)
		cam.fov = 50.0
	else:
		# Identical pose to underground_wave4_proof.gd's non-detail shot -- see that file's own
		# geometry note on why the camera must stand INSIDE ring 1's tube, not the central plaza.
		var cpos := Vector3(8.912, -1.98, 1.253)
		var target := Vector3(10.165, -1.48, -7.660)
		cam.transform = Transform3D(Basis.looking_at(target - cpos, Vector3.UP), cpos)
		cam.fov = 65.0
	add_child(cam)

func _build_env() -> Environment:
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-45, -40, 0)
	light.light_energy = 1.1
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(2.0, 3.0, -6.0)
	fill.light_energy = 3.0
	fill.omni_range = 18.0
	fill.light_color = Color(1.0, 0.85, 0.6)
	add_child(fill)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.03, 0.03, 0.04)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.4, 0.36, 0.3)
	env.ambient_light_energy = 0.55
	var env_node := WorldEnvironment.new()
	env_node.environment = env
	add_child(env_node)
	return env

func _build_scene() -> void:
	var ring_count := 3
	var gap := 6.0
	var radius_start := 9.0
	var segment_arc_deg := 16.0

	var env := _build_env()
	var tunables := _load_json_dict(BEST_TUNABLES_PATH)

	var topo := RingScaffoldGenerator.build_topology(ring_count, radius_start, gap, 0.0)
	var wall_by_ring: Dictionary = {}
	for ring_data in topo:
		wall_by_ring[int(ring_data["ring"])] = RingScaffoldGenerator.wall_surface_uv(ring_data)

	var carve_result := NonOverlappingCavityCarver.carve(topo, wall_by_ring,
		{"shape": "mix", "min_spacing": 1.6, "density": 0.9, "depth": 1.0, "seed": 2026,
		"cavity_size": 0.85, "max_carve_depth": 1.6})
	var instances: Array = carve_result["cavity_instances"]
	var cutaway: Array = carve_result["cavity_cutaway_field"]

	var cavity_focus := Vector3.ZERO
	var have_focus := not cutaway.is_empty()
	if have_focus:
		cavity_focus = (cutaway[0]["transform"] as Transform3D).origin
	_build_camera(cavity_focus, have_focus)

	var rock_mat := ProceduralRockTexture.build_material(
		{"noise_seed": 4177, "noise_scale": 6.0, "palette_handle": "sandstone"}, wall_by_ring.get(1, {}))

	var roof_t: Dictionary = tunables.get("roof", {})
	RoofGlowCutoff.apply_as_overlay(rock_mat, {
		"cutoff_elevation": float(roof_t.get("cutoff_elevation", RoofGlowCutoff.DEFAULT_CUTOFF_ELEVATION)),
		"glow_color": _color_from_json(roof_t.get("glow_color"), RoofGlowCutoff.DEFAULT_GLOW_COLOR),
		"glow_energy": float(roof_t.get("glow_energy", RoofGlowCutoff.DEFAULT_GLOW_ENERGY)),
		"blend_softness": float(roof_t.get("blend_softness", RoofGlowCutoff.DEFAULT_BLEND_SOFTNESS)),
	})

	var floor_result := ReflectiveFloorMaterial.build(
		{"base_color": Color(0.08, 0.09, 0.12), "gloss": 0.85, "reflection_mode": "ssr"})
	var floor_mat: StandardMaterial3D = floor_result["material"]
	ReflectiveFloorMaterial.apply_environment(env, floor_result["environment_patch"])

	var fog_t: Dictionary = tunables.get("fog", {})
	AtmosphericFogVolume.apply_environment(env, AtmosphericFogVolume.build_environment_patch({
		"density": float(fog_t.get("density", AtmosphericFogVolume.DEFAULT_DENSITY)),
		"color": _color_from_json(fog_t.get("color"), AtmosphericFogVolume.DEFAULT_COLOR),
		"height": float(fog_t.get("height", AtmosphericFogVolume.DEFAULT_HEIGHT)),
		"height_density": float(fog_t.get("height_density", AtmosphericFogVolume.DEFAULT_HEIGHT_DENSITY)),
		"sun_scatter": float(fog_t.get("sun_scatter", AtmosphericFogVolume.DEFAULT_SUN_SCATTER)),
	}))

	var hh_outer := (gap * 0.5) * RingScaffoldGenerator.DEFAULT_ELLIPSE_RATIO
	var floor_y := -hh_outer - 0.05
	var outer_radius: float = radius_start + gap * float(ring_count - 1) + gap * 0.6
	var floor_mesh := BoxMesh.new()
	floor_mesh.size = Vector3(outer_radius * 2.2, 0.1, outer_radius * 2.2)
	var floor_mi := MeshInstance3D.new()
	floor_mi.mesh = floor_mesh
	floor_mi.material_override = floor_mat
	floor_mi.position = Vector3(0.0, floor_y - 0.05, 0.0)
	add_child(floor_mi)

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

	var cavity_wall_mat := StandardMaterial3D.new()
	cavity_wall_mat.albedo_color = Color(0.18, 0.12, 0.08)
	cavity_wall_mat.roughness = 0.9
	for inst in instances:
		var mesh: Mesh = inst["mesh"]
		if mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		mi.material_override = cavity_wall_mat
		add_child(mi)

	var amber_t: Dictionary = tunables.get("amber", {})
	var amber_tunables := {
		"density": float(amber_t.get("density", AmberLightCubeScatterer.DEFAULT_DENSITY)),
		"min_spacing": float(amber_t.get("min_spacing", AmberLightCubeScatterer.DEFAULT_MIN_SPACING)),
		"size_min": float(amber_t.get("size_min", AmberLightCubeScatterer.DEFAULT_SIZE_MIN)),
		"size_max": float(amber_t.get("size_max", AmberLightCubeScatterer.DEFAULT_SIZE_MAX)),
		"hue": float(amber_t.get("hue", AmberLightCubeScatterer.DEFAULT_HUE)),
		"hue_jitter": float(amber_t.get("hue_jitter", AmberLightCubeScatterer.DEFAULT_HUE_JITTER)),
		"saturation": float(amber_t.get("saturation", AmberLightCubeScatterer.DEFAULT_SATURATION)),
		"value": float(amber_t.get("value", AmberLightCubeScatterer.DEFAULT_VALUE)),
		"emission_energy": float(amber_t.get("emission_energy", AmberLightCubeScatterer.DEFAULT_EMISSION_ENERGY)),
		"glass_alpha": float(amber_t.get("glass_alpha", AmberLightCubeScatterer.DEFAULT_GLASS_ALPHA)),
		"cavity_fill_probability": float(amber_t.get("cavity_fill_probability", AmberLightCubeScatterer.DEFAULT_CAVITY_FILL_PROBABILITY)),
		"protrusion": float(amber_t.get("protrusion", AmberLightCubeScatterer.DEFAULT_PROTRUSION)),
		"seed": int(amber_t.get("seed", 2026)),
	}
	var cube_count := 0
	for ring_data in topo:
		var ring_index := int(ring_data["ring"])
		var wall_uv: Dictionary = wall_by_ring.get(ring_index, {})
		cube_count += _instance_cubes(AmberLightCubeScatterer.scatter_wall(wall_uv, amber_tunables), amber_tunables)
	cube_count += _instance_cubes(AmberLightCubeScatterer.scatter_cavities(instances, amber_tunables), amber_tunables)

	# ── Wave 4 item 4.3 (B): PlantScatterInCavities -- the node this proof exists to demonstrate ────
	var plant_placements := PlantScatterInCavities.scatter(instances, cutaway,
		{"tree_asset_handle": "lsystem:default", "density": 0.7, "seed": 2026, "size_min": 0.5, "size_max": 1.1})
	var plant_count := _instance_plants(plant_placements)

	print("[underground_wave4_3b_proof] built %d wedges; %d cavities; %d amber cubes; %d floor-level (cutaway) cavities; %d plants placed" %
		[built_chunks, instances.size(), cube_count, cutaway.size(), plant_count])

func _instance_cubes(placements: Array, amber_tunables: Dictionary) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = int(amber_tunables.get("seed", 2026)) + 777
	var n := 0
	for p in placements:
		var mi := MeshInstance3D.new()
		mi.mesh = p["mesh"]
		mi.material_override = AmberLightCubeScatterer.jittered_material(amber_tunables, rng)
		mi.transform = p["transform"]
		add_child(mi)
		n += 1
	return n

## Instance every plant placement's scene_node (when resolved -- lsystem: handles) as a static subtree
## positioned at its own placement transform, via GodotSceneRenderer.build_static_tree() (REUSE -- the
## same renderer-neutral builder the graph runtime + glTF exporter already share). Placements whose
## scene_node is null (a CC0 asset-seam handle awaiting ingestion) are skipped -- nothing to render yet.
func _instance_plants(placements: Array) -> int:
	var plant_mat := StandardMaterial3D.new()
	plant_mat.albedo_color = Color(0.22, 0.42, 0.16)
	plant_mat.roughness = 0.85
	var n := 0
	for p in placements:
		var scene_node = p.get("scene_node")
		if scene_node == null:
			continue
		var wrapper := Node3D.new()
		wrapper.transform = p["transform"]
		add_child(wrapper)
		GodotSceneRenderer.build_static_tree([scene_node], wrapper)
		for mi in _find_mesh_instances(wrapper):
			mi.material_override = plant_mat
		n += 1
	return n

func _find_mesh_instances(node: Node) -> Array:
	var out := []
	if node is MeshInstance3D:
		out.append(node)
	for c in node.get_children():
		out.append_array(_find_mesh_instances(c))
	return out

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_shot_out)
		print("[underground_wave4_3b_proof] captured -> ", _shot_out)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
