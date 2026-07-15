extends Node3D
## brick_street_real_kit_proof -- windowed/headless progress-render driver for DQ-89607a82: the
## FIRST render of a REAL CC0 street kit ("City Kit (Roads)" by Kenney, CC0 1.0 Universal,
## https://kenney.nl/assets/city-kit-roads, vendored via
## `Alethea-cc/tools/asset_ingest_gltf.py ingest-kit --kit-id kenney_city_roads`) driven through the
## merged general kit-grid-placement pipeline: `KitGridPlacer.load_kit_pieces_from_manifest()` (this
## script's own real-asset LOAD verification -- every mesh below is `ResourceLoader.load()`ed off the
## real vendored GLB bytes, not a placeholder) -> `KitGridPlacer.place()` -> `KitGridPlacer.instantiate()`.
##
## GRID (DQ-cff253c7, real-grid swap-in): now driven by the REAL `StreetGridScaffold.build()`
## (DQ-1bcb379f, merged #202) instead of the earlier synthetic StreetGridScaffold-SHAPED
## two-cell placeholder -- exactly the one-line call-site change the module docstrings already
## documented (`cells_from_footprints`/`cells_from_street_polygon` consume the scaffold's
## `building_footprints`/`street_polygon` verbatim, zero conversion). One real chunk's worth of
## BSP-packed lots/streets feeds the SAME three fill modes below, unchanged.
##
## NOT attempted here (documented follow-up, no-auto-generalization rule): connectivity-aware
## road-tile fill (matching adjacent tile orientations across a real multi-lot street network) --
## `KitGridPlacer`/`kit_grid_placement.py` are tag-weighted-random by design, not connectivity-aware;
## queued as DQ-c05c0b4f.
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

# The real StreetGridScaffold chunk this proof renders (DQ-cff253c7). Small enough that ~1m road
# modules tile it legibly at this camera distance, big enough to show real BSP-packed multi-lot
# structure (not just the old 2-cell synthetic placeholder).
const WORLD_SEED := 2026
const CHUNK_COORD := Vector2i(0, 0)
const CHUNK_SIZE := 16.0
const LOT_SIZE_MIN := 3.0
const LOT_SIZE_MAX := 6.0
const STREET_WIDTH := 1.5
const PACKING_SEED := 7

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
	# Oblique aerial over the whole real chunk (CHUNK_SIZE x CHUNK_SIZE, origin at chunk (0,0)'s
	# min corner) -- legible enough to show the BSP-packed lot/street structure the real grid
	# produces, the same "show the scaffold's real data output" framing as the Wave-A1 proof.
	var center := Vector3(CHUNK_SIZE * 0.5, 0.0, CHUNK_SIZE * 0.5)
	var cam := Camera3D.new()
	var cpos := center + Vector3(CHUNK_SIZE * 0.55, CHUNK_SIZE * 0.85, CHUNK_SIZE * 0.55)
	cam.transform = Transform3D(Basis.looking_at(center - cpos, Vector3.UP), cpos)
	cam.fov = 50.0
	add_child(cam)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-55, -35, 0)
	light.light_energy = 1.2
	light.shadow_enabled = true
	add_child(light)
	var fill := OmniLight3D.new()
	fill.position = center + Vector3(0.0, CHUNK_SIZE * 0.4, 0.0)
	fill.light_energy = 2.0
	fill.omni_range = CHUNK_SIZE * 1.2
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

	# ground slab under the whole chunk so the kit reads as sitting ON a surface, not floating
	var ground := MeshInstance3D.new()
	var ground_mesh := BoxMesh.new()
	ground_mesh.size = Vector3(CHUNK_SIZE, 0.1, CHUNK_SIZE)
	ground.mesh = ground_mesh
	ground.position = Vector3(center.x, -0.05, center.z)
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

	# DQ-cff253c7 real-grid swap-in: one real StreetGridScaffold chunk (DQ-1bcb379f, merged #202)
	# instead of the old 2-cell synthetic placeholder. Zero conversion -- building_footprints/
	# street_polygon feed straight into the SAME cells_from_footprints/cells_from_street_polygon
	# seam the placeholder already exercised.
	var scaffold := StreetGridScaffold.build(WORLD_SEED, CHUNK_COORD, CHUNK_SIZE,
		LOT_SIZE_MIN, LOT_SIZE_MAX, STREET_WIDTH, PACKING_SEED)
	var building_footprints: Array = scaffold["building_footprints"]
	var street_polygon: Array = scaffold["street_polygon"]
	var lot_cells := KitGridPlacer.cells_from_footprints(building_footprints)
	var street_cells := KitGridPlacer.cells_from_street_polygon(street_polygon, building_footprints.size())

	var road_tiles := KitGridPlacer.place(street_cells, pieces, {
		"seed": 42, "fill_mode": "tile_fill", "margin": 0.0, "spacing": 0.0, "required_tags": ["road"],
	})
	var lampposts := KitGridPlacer.place(street_cells, pieces, {
		"seed": 42, "fill_mode": "edge_scatter", "margin": 0.3, "spacing": 2.0, "required_tags": ["post"],
	})
	var signs := KitGridPlacer.place(lot_cells, pieces, {
		"seed": 42, "fill_mode": "single_centered", "required_tags": ["sign"],
	})

	var placed := 0
	for placement in road_tiles:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1
	for placement in lampposts:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1
	for placement in signs:
		add_child(KitGridPlacer.instantiate(placement))
		placed += 1

	print("[brick_street_real_kit_proof] road_tiles=%d lampposts=%d signs=%d (real StreetGridScaffold: %d lots, %d street strips)" %
		[road_tiles.size(), lampposts.size(), signs.size(), building_footprints.size(), street_polygon.size()])
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
