extends Node3D
## brick_street_real_kit_proof -- windowed/headless progress-render driver for DQ-89607a82: the
## FIRST render of a REAL CC0 street kit ("City Kit (Roads)" by Kenney, CC0 1.0 Universal,
## https://kenney.nl/assets/city-kit-roads, vendored via
## `Alethea-cc/tools/asset_ingest_gltf.py ingest-kit --kit-id kenney_city_roads`) driven through the
## merged general kit-grid-placement pipeline: `KitGridPlacer.load_kit_pieces_from_manifest()` (this
## script's own real-asset LOAD verification -- every mesh below is `ResourceLoader.load()`ed off the
## real vendored GLB bytes, not a placeholder) -> `KitGridPlacer.place()` -> `KitGridPlacer.instantiate()`.
##
## GRID: the peer `StreetGridScaffold` generator (DQ-1bcb379f, Project A) had not merged at build time
## (only uncommitted work in a peer worktree) -- per this task's own fallback instruction, this uses the
## SAME synthetic StreetGridScaffold-SHAPED grid `kit_grid_placement_demo.py` / the Python-side real-kit
## test already prove (`cells_from_footprints`/`cells_from_street_polygon`, the exact placement seam a
## live scaffold would hand this module once merged -- swapping in the real grid is then a one-line
## call-site change, no algorithm change).
##
## THREE FILL MODES, same shape the synthetic proof already established, now with REAL geometry:
##   * tile_fill      -- an 8x3m street strip tiled edge-to-edge with 1.0x1.0m road/tile pieces
##                        (road-straight/road-crossroad/road-bend/tile-high, weighted toward straight).
##   * edge_scatter    -- light-square streetlamps scattered along the street strip's inset perimeter.
##   * single_centered -- a sign-highway landmark centered on a small adjoining lot.
##
## This is a GENERIC placement generator with no road-connectivity awareness (kit_grid_placement.py's
## own documented scope) -- pieces are chosen by weighted random tag match per tile, not "does this
## edge join a straight run to a corner." A road-network-aware successor (matching adjacent tile
## orientations) is a documented follow-up, not attempted here (no-auto-generalization rule).
##
##   <godot> --path godot res://brick_street_real_kit_proof.tscn -- --shot
## writes godot/live/brick_street_real_kit_proof.png after a few frames, then quits.

const SHOT_OUT := "res://live/brick_street_real_kit_proof.png"
const MANIFEST_PATH := "res://assets/ingested/manifest.json"
const KIT_ID := "kenney_city_roads"

var _shot_frames := 0

# Real footprint/height overrides -- measured from the vendored GLBs' glTF
# accessors[].min/max on POSITION (see Alethea-cc/tools/test_kit_grid_placement.py's matching
# fixture for the Python-side twin of these same numbers), NOT guessed defaults. Every road/tile
# piece in this kit is a flat 1.0 x 1.0m module (Kenney's own grid convention for this kit).
const OVERRIDES := {
	"kenney_city_roads__road-straight": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "straight"], "weight": 3.0},
	"kenney_city_roads__road-straight-half": {"footprint": Vector2(1.0, 0.5), "height": 0.02, "tags": ["road", "straight"], "weight": 1.0},
	"kenney_city_roads__road-crossroad": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "junction"], "weight": 1.0},
	"kenney_city_roads__road-intersection": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "junction"], "weight": 1.0},
	"kenney_city_roads__road-square": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "junction"], "weight": 1.0},
	"kenney_city_roads__road-bend": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "corner"], "weight": 1.0},
	"kenney_city_roads__road-curve": {"footprint": Vector2(1.0, 1.0), "height": 0.02, "tags": ["road", "corner"], "weight": 1.0},
	"kenney_city_roads__tile-high": {"footprint": Vector2(1.0, 1.0), "height": 0.25, "tags": ["road", "straight"], "weight": 1.0},
	"kenney_city_roads__tile-low": {"footprint": Vector2(1.0, 1.0), "height": 0.1, "tags": ["road", "straight"], "weight": 1.0},
	"kenney_city_roads__light-square": {"footprint": Vector2(0.05, 0.24), "height": 0.6, "tags": ["post"], "weight": 2.0},
	"kenney_city_roads__light-curved": {"footprint": Vector2(0.05, 0.23), "height": 0.67, "tags": ["post"], "weight": 1.0},
	"kenney_city_roads__sign-highway": {"footprint": Vector2(0.13, 1.0), "height": 0.71, "tags": ["sign"], "weight": 1.0},
}

func _ready() -> void:
	_build_env()
	var placed := _build_scene()
	print("[brick_street_real_kit_proof] instantiated %d real kenney_city_roads pieces (kit CC0 1.0 Universal, https://kenney.nl/assets/city-kit-roads)" % placed)

func _build_env() -> void:
	var cam := Camera3D.new()
	var cpos := Vector3(5.0, 4.2, 8.5)
	cam.transform = Transform3D(Basis.looking_at(Vector3(5.0, 0.2, 1.2) - cpos, Vector3.UP), cpos)
	cam.fov = 55.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = Vector3(5.0, 3.0, 5.0)
	fill.light_energy = 2.0
	fill.omni_range = 15.0
	add_child(fill)
	var env_node := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.62, 0.72, 0.82)  # daylight sky, not the underground proofs' dark bg
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.75, 0.78, 0.85)
	env.ambient_light_energy = 0.9
	env_node.environment = env
	add_child(env_node)

	# ground slab under the street/lot so the kit reads as sitting ON a surface, not floating
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(14.0, 0.1, 6.0)
	ground.mesh = ground_mesh
	ground.position = Vector3(5.0, -0.05, 1.5)
	var ground_mat := StandardMaterial3D.new()
	ground_mat.albedo_color = Color(0.36, 0.42, 0.3)  # grass verge either side of the road module
	ground.material_override = ground_mat
	add_child(ground)

func _build_scene() -> int:
	if not FileAccess.file_exists(MANIFEST_PATH):
		push_error("brick_street_real_kit_proof: manifest not found at %s -- run `asset_ingest_gltf.py ingest-kit --kit-id kenney_city_roads` first" % MANIFEST_PATH)
		return 0

	var pieces := KitGridPlacer.load_kit_pieces_from_manifest(KIT_ID, MANIFEST_PATH, Vector2.ONE, 1.0, OVERRIDES)
	if pieces.is_empty():
		push_error("brick_street_real_kit_proof: 0 pieces loaded from manifest kit '%s'" % KIT_ID)
		return 0

	# the same StreetGridScaffold-SHAPED synthetic grid the Python-side real-kit test uses (module
	# docstring: the placement seam StreetGridScaffold.build() would hand this once merged).
	var street_rect := Rect2(Vector2(0.0, 0.0), Vector2(8.0, 3.0))
	var lot_rect := Rect2(Vector2(9.0, 0.5), Vector2(1.5, 1.5))
	var lot_cells := KitGridPlacer.cells_from_footprints([{"rect": lot_rect, "id": 0}])
	var street_cells := KitGridPlacer.cells_from_street_polygon([street_rect], 1)

	var road_tiles := KitGridPlacer.place(street_cells, pieces, {
		"seed": 42, "fill_mode": "tile_fill", "margin": 0.0, "spacing": 0.0, "required_tags": ["road"],
	})
	var lampposts := KitGridPlacer.place(street_cells, pieces, {
		"seed": 42, "fill_mode": "edge_scatter", "margin": 0.3, "spacing": 2.0, "required_tags": ["post"],
	})
	var sign := KitGridPlacer.place(lot_cells, pieces, {
		"seed": 42, "fill_mode": "single_centered", "required_tags": ["sign"],
	})

	var placed := 0
	for placement in road_tiles:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1
	for placement in lampposts:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1
	for placement in sign:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1

	print("[brick_street_real_kit_proof] road_tiles=%d lampposts=%d sign=%d" % [road_tiles.size(), lampposts.size(), sign.size()])
	return placed

func _process(_delta: float) -> void:
	if not ("--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()):
		return
	_shot_frames += 1
	if _shot_frames == 20:
		await _capture(SHOT_OUT)
		print("[brick_street_real_kit_proof] captured -> ", SHOT_OUT)
		get_tree().quit(0)

func _capture(path: String) -> void:
	await RenderingServer.frame_post_draw
	DirAccess.make_dir_recursive_absolute("res://live")
	get_viewport().get_texture().get_image().save_png(path)
