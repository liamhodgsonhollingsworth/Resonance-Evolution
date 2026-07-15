extends Node3D
## brick_street_wave_a1_proof -- progress-render driver for Project A ("brick street scene") Wave-A1
## increment 1: `StreetGridScaffold` (BSP rectangle-packing street scaffold), `SkySocket`
## (blank-white sky + near-overhead directional shadow), composed with the already-merged
## `ChunkLifecycleManager`/`DetailField.DetailLODTracker` via `StreetChunkStreamer`. This is Liam's
## FIRST look at Project A (no prior render exists for this scene, per DISPATCH.md's 2026-07-15
## claim-board hygiene note: "Wave 2 itself (RingScaffoldGenerator/StreetGridScaffold) was NOT
## started").
##
## Buildings render as flat brick-red placeholder boxes (`StreetGridScaffold.lot_box_mesh`, varied
## per-lot height) -- real coursed brick is `BrickWallGenerator`, a LATER increment (plan node 4,
## P2 tier); this shot's job is to show the STREET/LOT SCAFFOLD structure itself, not final wall
## texture. Streets render as flat paving-toned strips directly from `street_polygon` -- the exact
## negative-space geometry the scaffold emits, so what's on screen IS the scaffold's real DATA output,
## not a stand-in.
##
##   <godot> --path godot res://brick_street_wave_a1_proof.tscn -- --shot
##     writes godot/live/brick_street_wave_a1_proof_wide.png, camera at the ALREADY-REGISTERED
##     "brick_street_default" pose (Alethea-cc/tools/image_evolver/reference_camera_score.py) --
##     directly scoreable against the "brick_street" reference (Omaha Old Market) with no new pose
##     needed.
##   <godot> --path godot res://brick_street_wave_a1_proof.tscn -- --shot --detail
##     writes godot/live/brick_street_wave_a1_proof_detail.png, an oblique aerial framed off a REAL
##     BSP split gutter's position, so the rectangle-packing structure itself is legible.

const SHOT_OUT_WIDE := "res://live/brick_street_wave_a1_proof_wide.png"
const SHOT_OUT_DETAIL := "res://live/brick_street_wave_a1_proof_detail.png"

# The registered "brick_street_default" CameraPose (reference_camera_score.py _DEFAULT_POSES) --
# duplicated here as plain literals (this driver has no Python interop) so the wide shot uses the
# EXACT SAME pose the scorer already has on file for the "brick_street" reference.
const WIDE_CAM_POS := Vector3(0.0, 1.7, 6.0)
const WIDE_CAM_LOOK_AT := Vector3(0.0, 2.0, -6.0)
const WIDE_CAM_FOV := 55.0

const WORLD_SEED := 2026
const CHUNK_SIZE := 18.0
const LOT_SIZE_MIN := 5.0
const LOT_SIZE_MAX := 12.0
const STREET_WIDTH := 3.0
const GRID_RADIUS := 1  # 3x3 chunks

var _shot_frames := 0
var _detail_mode := false
var _shot_out := SHOT_OUT_WIDE


func _ready() -> void:
	_detail_mode = "--detail" in OS.get_cmdline_user_args() or "--detail" in OS.get_cmdline_args()
	_shot_out = SHOT_OUT_DETAIL if _detail_mode else SHOT_OUT_WIDE
	_build_scene()


func _build_scene() -> void:
	# ── Sky (node 9, SkySocket) -- blank white + near-overhead sun, §12-13 addenda ─────────────────
	var sky_result := SkySocket.build({"mode": "blank_white"})
	var env_node := WorldEnvironment.new()
	env_node.environment = sky_result["environment"]
	add_child(env_node)
	add_child(sky_result["sun"])
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.0, 6.0, 4.0)
	fill.light_energy = 1.4
	fill.omni_range = 30.0
	add_child(fill)

	# ── Scaffolding tier (nodes 1 + 3) -- StreetChunkStreamer composes StreetGridScaffold with the
	# already-merged ChunkLifecycleManager + DetailField.DetailLODTracker ───────────────────────────
	var streamer := StreetChunkStreamer.new(WORLD_SEED, CHUNK_SIZE, GRID_RADIUS,
		StreetGridScaffold.DEFAULT_PACKING_SEED,
		{"lot_size_min": LOT_SIZE_MIN, "lot_size_max": LOT_SIZE_MAX, "street_width": STREET_WIDTH})
	# The camera sits near world origin -- update() around ZERO spawns the full GRID_RADIUS window.
	var diff := streamer.update(Vector3.ZERO)
	var spawn: Array = diff["spawn"]

	# Center the rendered block on the origin (chunk keys run 0-2 on each axis at GRID_RADIUS=1, i.e.
	# the player's OWN chunk is (0,0) with a 1-cell margin -- ChunkLifecycleManager.grid_key_fn
	# already centers the window on wherever `update()` was called FROM, so no extra offset is
	# needed; the player position (world ZERO) already sits inside chunk (0,0)).

	var brick_mat := StandardMaterial3D.new()
	brick_mat.albedo_color = Color(0.612, 0.231, 0.180)  # "#9c3b2e", plan node 4's brick_color default
	brick_mat.roughness = 0.9

	var street_mat := StandardMaterial3D.new()
	street_mat.albedo_color = Color(0.42, 0.38, 0.34)  # brick-paved alley tone (reference image)
	street_mat.roughness = 0.95

	var built_lots := 0
	var built_streets := 0
	var first_split_focus := Vector3.ZERO
	var have_split_focus := false

	for entry in spawn:
		var chunk_key: Vector2i = entry["key"]
		var scaffold: Dictionary = entry["scaffold"]
		var footprints: Array = scaffold["building_footprints"]
		var street_polygon: Array = scaffold["street_polygon"]

		# Buildings: per-lot varied height (2-5 "stories" at ~3.2m/story), a SEPARATE deterministic
		# RNG keyed off (chunk_key, lot id) so the scaffold's own RNG stays untouched by render-only
		# choices (RingScaffoldGenerator's own "this generator only emits real geometry, it never
		# decides render specifics" separation of concerns).
		var height_rng := RandomNumberGenerator.new()
		height_rng.seed = hash([WORLD_SEED, chunk_key.x, chunk_key.y, "height"])
		for lot in footprints:
			var height: float = height_rng.randf_range(6.4, 16.0)
			var mesh := StreetGridScaffold.lot_box_mesh(lot, height)
			var mi := MeshInstance3D.new()
			mi.mesh = mesh
			mi.material_override = brick_mat
			mi.position = StreetGridScaffold.lot_box_center(lot, height)
			add_child(mi)
			built_lots += 1

		# Streets: the scaffold's own street_polygon strips, rendered as a thin paved slab (a real
		# geometric OUTPUT of the scaffold, not a placeholder ground plane).
		for strip in street_polygon:
			var r: Rect2 = strip as Rect2
			var box := BoxMesh.new()
			box.size = Vector3(maxf(0.05, r.size.x), 0.1, maxf(0.05, r.size.y))
			var mi := MeshInstance3D.new()
			mi.mesh = box
			mi.material_override = street_mat
			var c := r.get_center()
			mi.position = Vector3(c.x, -0.05, c.y)
			add_child(mi)
			built_streets += 1
			if chunk_key == Vector2i(0, 0) and not have_split_focus and street_polygon.find(strip) > 3:
				# Skip the first 4 entries (the forced perimeter-margin ring) so the detail shot
				# frames on a genuine INTERNAL BSP split gutter, not just the chunk's outer edge.
				first_split_focus = Vector3(c.x, 0.0, c.y)
				have_split_focus = true

	_build_camera(first_split_focus, have_split_focus)

	print("[brick_street_wave_a1_proof] built %d lots + %d street strips across %d spawned chunks (StreetGridScaffold + SkySocket blank_white + StreetChunkStreamer/ChunkLifecycleManager/DetailLODTracker composition)" %
		[built_lots, built_streets, spawn.size()])


func _build_camera(split_focus: Vector3, have_focus: bool) -> void:
	var cam := Camera3D.new()
	if _detail_mode:
		# Oblique aerial over a real internal BSP split -- legible rectangle-packing structure.
		var focus := split_focus if have_focus else Vector3.ZERO
		var cpos := focus + Vector3(10.0, 14.0, 10.0)
		cam.transform = Transform3D(Basis.looking_at(focus - cpos, Vector3.UP), cpos)
		cam.fov = 55.0
	else:
		# The EXACT registered "brick_street_default" CameraPose -- directly scoreable against the
		# "brick_street" reference with the pose that already exists (node 20
		# FaithfulViewportCriterion's acceptance hook).
		cam.transform = Transform3D(Basis.looking_at(WIDE_CAM_LOOK_AT - WIDE_CAM_POS, Vector3.UP), WIDE_CAM_POS)
		cam.fov = WIDE_CAM_FOV
	add_child(cam)


func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 15:
		await _capture(_shot_out)
		print("[brick_street_wave_a1_proof] captured -> ", _shot_out)
		get_tree().quit(0)


func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
