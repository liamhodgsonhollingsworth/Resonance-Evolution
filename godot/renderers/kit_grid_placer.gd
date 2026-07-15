class_name KitGridPlacer
extends RefCounted
## KitGridPlacer -- the general engine-neutral "modular kit -> grid placement"
## generator (DQ-9c1bbfc5, Wavelet repo notes/planning/crosscutting_systems_plan_2026_07_14.md
## sec6, PRE-APPROVED PER SPEC per Liam's own "laying general scaffolding that allows
## it to be generated ... from anything in the future" phrase). GDScript ADAPTER --
## a faithful, line-for-line port of the Python reference
## `Alethea-cc/tools/kit_grid_placement.py` (same algorithm, same param names, same
## per-cell/per-slot determinism contract), so a live in-engine caller (chunk
## streaming, a scene assembler) never has to leave GDScript or round-trip through
## JSON to use this. The two implementations are proven to agree on the STRUCTURE
## of the algorithm (mirrored function-for-function below); RNG bit-streams are
## NOT claimed identical cross-language (GDScript's `hash()` and Python's
## `hashlib.sha256` are different functions) -- what's shared is the schema and the
## deterministic-per-cell CONTRACT, matching how `godot-aperture-parity` already
## treats "line-for-line port" as sufficient parity for two different runtimes.
##
## THE PLACEMENT SEAM WITH StreetGridScaffold (Project A, `street_grid_scaffold.gd`,
## peer scope). This is the layer any grid feeds -- it does NOT generate a grid.
## `StreetGridScaffold.build(...)`'s own `building_footprints` (`{"rect": Rect2,
## "id": int}`) and `street_polygon` (`Array[Rect2]`) plug straight into `place()`
## below via `cells_from_footprints()` / `cells_from_street_polygon()` -- no
## conversion, no peer file touched. `building_footprints` -> `"lot"` cells (kit
## pieces belong here: houses via single_centered/tile_fill); `street_polygon` ->
## `"street"` cells (street-architecture props belong here: lampposts/barriers via
## edge_scatter).
##
## DISTINCT FROM `ScatterComposer` (renderers/scatter_composer.gd, Wave 1): that is
## continuous-density Poisson-disk scattering over an arbitrary field (organic,
## unbounded). This module places pieces INTO discrete rectangular grid CELLS from
## a grid generator (streets/lots/staircase treads/wall bays) -- a different,
## complementary niche; neither supersedes the other.
##
## Pure DATA in -> pure DATA out (Dictionary/Array/Rect2 only, world-space
## coordinates), no scene-tree dependency -- same portability invariant as the
## sibling renderers (StreetGridScaffold, RingScaffoldGenerator, ChunkLifecycleManager,
## DetailField, ScatterComposer). A caller turns the returned placement records into
## actual nodes via `ResourceLoader.load(res_path)` + a Transform -- this module
## never touches the scene tree itself.
##
## GROUND-PLANE / PIVOT CONVENTIONS (matches the Python core exactly):
##   * World space is Y-up; the ground plane is XZ. A cell Dictionary mirrors a
##     `Rect2` (`rect.position.x`/`rect.position.y`/`rect.size.x`/`rect.size.y`,
##     where `.y` means world Z -- exactly `StreetGridScaffold.lot_box_center`'s own
##     convention).
##   * Every kit piece is assumed BASE-PIVOTED (local origin at ground contact,
##     matching Kenney/Quaternius/KayKit CC0 kit convention) -- every placement's Y
##     is always 0.0.
##   * Rotation is Y-axis (vertical) only.
##
## free_params (mirrors StreetGridScaffold's own docstring convention):
##   seed                {type:int,   min:0,   max:2^31, default:1}
##   fill_mode            {type:enum,  options:[single_centered,tile_fill,edge_scatter], default:single_centered}
##   margin               {type:float, min:0,   max:10,   default:0.25}
##   spacing              {type:float, min:0,   max:10,   default:0.5}
##   rotation_snap_deg    {type:float, min:0,   max:180,  default:90}
##   jitter_pos           {type:float, min:0,   max:5,    default:0}
##   jitter_rot_deg       {type:float, min:0,   max:45,   default:0}
##   scale_to_fit         {type:bool,  default:true}
##   max_pieces_per_cell  {type:int,   min:1,   max:500,  default:64}
##   fill_ratio           {type:float, min:0,   max:1,    default:1.0}

const FILL_MODES := ["single_centered", "tile_fill", "edge_scatter"]

const DEFAULT_SEED := 1
const DEFAULT_FILL_MODE := "single_centered"
const DEFAULT_MARGIN := 0.25
const DEFAULT_SPACING := 0.5
const DEFAULT_ROTATION_SNAP_DEG := 90.0
const DEFAULT_JITTER_POS := 0.0
const DEFAULT_JITTER_ROT_DEG := 0.0
const DEFAULT_SCALE_TO_FIT := true
const DEFAULT_MAX_PIECES_PER_CELL := 64
const DEFAULT_FILL_RATIO := 1.0


## Place `pieces` (Array of piece Dictionaries: {asset_id, res_path, footprint:Vector2,
## height, tags:Array[String], weight}) onto `cells` (Array of cell Dictionaries:
## {id:int, rect:Rect2, kind:String, tags:Array[String]}) using `params` (any subset
## of the free_params above; missing keys fall back to the DEFAULT_* constants).
## Returns an Array of placement Dictionaries:
##   {cell_id:int, asset_id:String, res_path:String, position:Vector3,
##    rotation_deg:float, scale:float, style_handle:Variant}
static func place(cells: Array, pieces: Array, params: Dictionary = {}) -> Array:
	var fill_mode: String = params.get("fill_mode", DEFAULT_FILL_MODE)
	if not FILL_MODES.has(fill_mode):
		push_error("KitGridPlacer.place: unknown fill_mode %s (expected one of %s)" % [fill_mode, FILL_MODES])
		return []

	var eligible := _eligible_pieces(pieces, params.get("required_tags", []), params.get("excluded_tags", []))
	if eligible.is_empty():
		return []

	var out: Array = []
	for cell in cells:
		match fill_mode:
			"single_centered":
				out.append_array(_place_single_centered(cell, eligible, params))
			"tile_fill":
				out.append_array(_place_tile_fill(cell, eligible, params))
			"edge_scatter":
				out.append_array(_place_edge_scatter(cell, eligible, params))
	return out


## Adapter: StreetGridScaffold's `building_footprints` ({"rect":Rect2,"id":int}) ->
## `"lot"` cell Dictionaries, the exact shape `place()` consumes. Zero conversion of
## the underlying Rect2 -- this is the placement seam.
static func cells_from_footprints(building_footprints: Array, kind: String = "lot") -> Array:
	var out: Array = []
	for f in building_footprints:
		out.append({"id": int(f["id"]), "rect": f["rect"] as Rect2, "kind": kind, "tags": []})
	return out


## Adapter: StreetGridScaffold's `street_polygon` (Array[Rect2]) -> `"street"` cell
## Dictionaries. `id_offset` should be past the lot id range (e.g.
## `building_footprints.size()`) so lot and street cell ids never collide.
static func cells_from_street_polygon(street_polygon: Array, id_offset: int, kind: String = "street") -> Array:
	var out: Array = []
	for i in street_polygon.size():
		out.append({"id": id_offset + i, "rect": street_polygon[i] as Rect2, "kind": kind, "tags": []})
	return out


# ── determinism + selection ──────────────────────────────────────────────────────

## A cell/slot-scoped RNG derived ONLY from (seed, cell_id, slot) -- the same
## chunk-deterministic contract StreetGridScaffold documents for its own RNG.
static func _cell_rng(seed: int, cell_id: int, slot: int = 0) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash([int(seed), int(cell_id), int(slot)])
	return rng


static func _eligible_pieces(pieces: Array, required_tags: Array, excluded_tags: Array) -> Array:
	if required_tags.is_empty() and excluded_tags.is_empty():
		return pieces
	var out: Array = []
	for p in pieces:
		var tags: Array = p.get("tags", [])
		var has_all_required := true
		for t in required_tags:
			if not tags.has(t):
				has_all_required = false
				break
		if not has_all_required:
			continue
		var has_excluded := false
		for t in excluded_tags:
			if tags.has(t):
				has_excluded = true
				break
		if has_excluded:
			continue
		out.append(p)
	return out


static func _weighted_choice(rng: RandomNumberGenerator, pieces: Array) -> Dictionary:
	var total := 0.0
	for p in pieces:
		total += maxf(0.0, float(p.get("weight", 1.0)))
	if total <= 0.0:
		return pieces[rng.randi() % pieces.size()]
	var r := rng.randf() * total
	var acc := 0.0
	for p in pieces:
		acc += maxf(0.0, float(p.get("weight", 1.0)))
		if r <= acc:
			return p
	return pieces[pieces.size() - 1]


static func _snap_angle(angle_deg: float, snap_deg: float) -> float:
	if snap_deg <= 0.0:
		return fposmod(angle_deg, 360.0)
	return fposmod(roundf(angle_deg / snap_deg) * snap_deg, 360.0)


static func _fit_scale(avail_w: float, avail_h: float, footprint: Vector2) -> float:
	if footprint.x <= 0.0 or footprint.y <= 0.0:
		return 1.0
	return maxf(0.001, minf(1.0, minf(avail_w / footprint.x, avail_h / footprint.y)))


static func _placement(cell_id: int, piece: Dictionary, x: float, z: float, rot: float, scale: float) -> Dictionary:
	return {
		"cell_id": cell_id,
		"asset_id": piece.get("asset_id", ""),
		"res_path": piece.get("res_path", ""),
		"position": Vector3(x, 0.0, z),
		"rotation_deg": rot,
		"scale": scale,
		"style_handle": piece.get("style_handle", null),
	}


# ── single_centered ──────────────────────────────────────────────────────────────

static func _place_single_centered(cell: Dictionary, pieces: Array, params: Dictionary) -> Array:
	var seed: int = params.get("seed", DEFAULT_SEED)
	var margin: float = params.get("margin", DEFAULT_MARGIN)
	var rotation_snap_deg: float = params.get("rotation_snap_deg", DEFAULT_ROTATION_SNAP_DEG)
	var jitter_pos: float = params.get("jitter_pos", DEFAULT_JITTER_POS)
	var jitter_rot_deg: float = params.get("jitter_rot_deg", DEFAULT_JITTER_ROT_DEG)
	var scale_to_fit: bool = params.get("scale_to_fit", DEFAULT_SCALE_TO_FIT)

	var cell_id: int = int(cell["id"])
	var rect: Rect2 = cell["rect"]
	var rng := _cell_rng(seed, cell_id, 0)
	var piece := _weighted_choice(rng, pieces)

	var avail_w: float = maxf(0.0, rect.size.x - 2.0 * margin)
	var avail_h: float = maxf(0.0, rect.size.y - 2.0 * margin)
	var scale: float = _fit_scale(avail_w, avail_h, piece.get("footprint", Vector2.ONE)) if scale_to_fit else 1.0

	var center := rect.get_center()
	var cx := center.x
	var cz := center.y
	if jitter_pos > 0.0:
		cx += rng.randf_range(-jitter_pos, jitter_pos)
		cz += rng.randf_range(-jitter_pos, jitter_pos)
	var rot := _snap_angle(rng.randf_range(0.0, 360.0), rotation_snap_deg)
	if jitter_rot_deg > 0.0:
		rot = fposmod(rot + rng.randf_range(-jitter_rot_deg, jitter_rot_deg), 360.0)

	return [_placement(cell_id, piece, cx, cz, rot, scale)]


# ── tile_fill ────────────────────────────────────────────────────────────────────

static func _place_tile_fill(cell: Dictionary, pieces: Array, params: Dictionary) -> Array:
	var seed: int = params.get("seed", DEFAULT_SEED)
	var margin: float = params.get("margin", DEFAULT_MARGIN)
	var spacing: float = params.get("spacing", DEFAULT_SPACING)
	var rotation_snap_deg: float = params.get("rotation_snap_deg", DEFAULT_ROTATION_SNAP_DEG)
	var jitter_pos: float = params.get("jitter_pos", DEFAULT_JITTER_POS)
	var jitter_rot_deg: float = params.get("jitter_rot_deg", DEFAULT_JITTER_ROT_DEG)
	var scale_to_fit: bool = params.get("scale_to_fit", DEFAULT_SCALE_TO_FIT)
	var max_pieces_per_cell: int = params.get("max_pieces_per_cell", DEFAULT_MAX_PIECES_PER_CELL)
	var fill_ratio: float = params.get("fill_ratio", DEFAULT_FILL_RATIO)

	var cell_id: int = int(cell["id"])
	var rect: Rect2 = cell["rect"]
	var interior_w: float = maxf(0.0, rect.size.x - 2.0 * margin)
	var interior_h: float = maxf(0.0, rect.size.y - 2.0 * margin)
	var nominal: Vector2 = pieces[0].get("footprint", Vector2.ONE)
	var step_x: float = maxf(0.05, nominal.x + spacing)
	var step_y: float = maxf(0.05, nominal.y + spacing)
	var cols: int = int(interior_w / step_x) if interior_w >= nominal.x else 0
	var rows: int = int(interior_h / step_y) if interior_h >= nominal.y else 0
	if cols <= 0 or rows <= 0:
		return []

	var used_w := cols * step_x - spacing
	var used_h := rows * step_y - spacing
	var origin_x := rect.position.x + margin + (interior_w - used_w) / 2.0
	var origin_y := rect.position.y + margin + (interior_h - used_h) / 2.0

	var out: Array = []
	var slot := 0
	for r in rows:
		for c in cols:
			if out.size() >= max_pieces_per_cell:
				return out
			var rng := _cell_rng(seed, cell_id, slot)
			slot += 1
			if fill_ratio < 1.0 and rng.randf() > fill_ratio:
				continue
			var piece := _weighted_choice(rng, pieces)
			var slot_w := step_x - spacing
			var slot_h := step_y - spacing
			var scale: float = _fit_scale(slot_w, slot_h, piece.get("footprint", Vector2.ONE)) if scale_to_fit else 1.0
			var px := origin_x + (c + 0.5) * step_x
			var pz := origin_y + (r + 0.5) * step_y
			if jitter_pos > 0.0:
				px += rng.randf_range(-jitter_pos, jitter_pos)
				pz += rng.randf_range(-jitter_pos, jitter_pos)
			var rot := _snap_angle(rng.randf_range(0.0, 360.0), rotation_snap_deg)
			if jitter_rot_deg > 0.0:
				rot = fposmod(rot + rng.randf_range(-jitter_rot_deg, jitter_rot_deg), 360.0)
			out.append(_placement(cell_id, piece, px, pz, rot, scale))
	return out


# ── edge_scatter ─────────────────────────────────────────────────────────────────

## (x, z, outward_normal_deg) samples along `rect`'s margin-inset perimeter, evenly
## spaced per side -- generalizes past "streets": fence posts around a lot,
## staircase-tread edge markers, or lampposts along a street strip are all the same
## "walk the boundary at intervals" operation.
static func _perimeter_points(rect: Rect2, margin: float, spacing: float) -> Array:
	var x0 := rect.position.x + margin
	var y0 := rect.position.y + margin
	var x1 := rect.position.x + rect.size.x - margin
	var y1 := rect.position.y + rect.size.y - margin
	var segs := [
		[Vector2(x0, y0), Vector2(x1, y0), 270.0],   # top:    outward normal faces -Z
		[Vector2(x1, y0), Vector2(x1, y1), 0.0],      # right:  outward normal faces +X
		[Vector2(x1, y1), Vector2(x0, y1), 90.0],     # bottom: outward normal faces +Z
		[Vector2(x0, y1), Vector2(x0, y0), 180.0],    # left:   outward normal faces -X
	]
	var pts: Array = []
	for seg in segs:
		var p0: Vector2 = seg[0]
		var p1: Vector2 = seg[1]
		var normal_deg: float = seg[2]
		var seg_len := p0.distance_to(p1)
		if seg_len < 1e-6:
			continue
		var n: int = maxi(1, int(seg_len / maxf(0.05, spacing)))
		for i in n:
			var t := (i + 0.5) / float(n)
			var p := p0.lerp(p1, t)
			pts.append([p.x, p.y, normal_deg])
	return pts


static func _place_edge_scatter(cell: Dictionary, pieces: Array, params: Dictionary) -> Array:
	var seed: int = params.get("seed", DEFAULT_SEED)
	var margin: float = params.get("margin", DEFAULT_MARGIN)
	var spacing: float = params.get("spacing", DEFAULT_SPACING)
	var rotation_snap_deg: float = params.get("rotation_snap_deg", DEFAULT_ROTATION_SNAP_DEG)
	var jitter_pos: float = params.get("jitter_pos", DEFAULT_JITTER_POS)
	var jitter_rot_deg: float = params.get("jitter_rot_deg", DEFAULT_JITTER_ROT_DEG)
	var scale_to_fit: bool = params.get("scale_to_fit", DEFAULT_SCALE_TO_FIT)
	var max_pieces_per_cell: int = params.get("max_pieces_per_cell", DEFAULT_MAX_PIECES_PER_CELL)
	var fill_ratio: float = params.get("fill_ratio", DEFAULT_FILL_RATIO)

	var cell_id: int = int(cell["id"])
	var rect: Rect2 = cell["rect"]
	var points := _perimeter_points(rect, margin, spacing)
	var out: Array = []
	for slot in points.size():
		if out.size() >= max_pieces_per_cell:
			break
		var pt: Array = points[slot]
		var px: float = pt[0]
		var pz: float = pt[1]
		var normal_deg: float = pt[2]
		var rng := _cell_rng(seed, cell_id, slot)
		if fill_ratio < 1.0 and rng.randf() > fill_ratio:
			continue
		var piece := _weighted_choice(rng, pieces)
		var scale: float = _fit_scale(spacing, spacing, piece.get("footprint", Vector2.ONE)) if scale_to_fit else 1.0
		var x := px
		var z := pz
		if jitter_pos > 0.0:
			x += rng.randf_range(-jitter_pos, jitter_pos)
			z += rng.randf_range(-jitter_pos, jitter_pos)
		var rot: float = _snap_angle(normal_deg, rotation_snap_deg) if rotation_snap_deg > 0.0 else normal_deg
		if jitter_rot_deg > 0.0:
			rot = fposmod(rot + rng.randf_range(-jitter_rot_deg, jitter_rot_deg), 360.0)
		out.append(_placement(cell_id, piece, x, z, rot, scale))
	return out


# ── kit loading ──────────────────────────────────────────────────────────────────

## Load a previously-ingested kit's members (`asset_ingest_gltf.py ingest-kit`) as
## piece Dictionaries, reading the SAME `assets/ingested/manifest.json` the Python
## tooling writes -- never re-implements ingestion. Real GLB bounding boxes are NOT
## extracted here (matches the Python core's documented limitation) -- footprint/
## height/tags default unless `overrides` (`asset_id -> {"footprint":Vector2,
## "height":float,"tags":Array,"weight":float}`) supplies real measurements.
static func load_kit_pieces_from_manifest(kit_id: String, manifest_path: String = "res://assets/ingested/manifest.json",
		default_footprint: Vector2 = Vector2.ONE, default_height: float = 1.0, overrides: Dictionary = {}) -> Array:
	if not FileAccess.file_exists(manifest_path):
		push_error("KitGridPlacer.load_kit_pieces_from_manifest: manifest not found at %s" % manifest_path)
		return []
	var text := FileAccess.get_file_as_string(manifest_path)
	var manifest = JSON.parse_string(text)
	if manifest == null or not manifest.has("kits") or not manifest["kits"].has(kit_id):
		push_error("KitGridPlacer.load_kit_pieces_from_manifest: kit %s not found in %s" % [kit_id, manifest_path])
		return []
	var kit: Dictionary = manifest["kits"][kit_id]
	var out: Array = []
	for m in kit.get("members", []):
		var aid: String = m["asset_id"]
		var ov: Dictionary = overrides.get(aid, {})
		out.append({
			"asset_id": aid,
			"res_path": m["res_path"],
			"footprint": ov.get("footprint", default_footprint),
			"height": ov.get("height", default_height),
			"tags": ov.get("tags", []),
			"weight": ov.get("weight", 1.0),
			"style_handle": ov.get("style_handle", null),
		})
	return out


# ── engine output helper ─────────────────────────────────────────────────────────

## Instantiate one placement record into an actual scene node (Node3D wrapping a
## loaded PackedScene/Mesh at `res_path`), positioned/rotated/scaled per the record.
## Optional convenience -- callers that only want the DATA (to hand to
## ChunkLifecycleManager / a batching system) should use `place()`'s return value
## directly and never call this.
static func instantiate(placement: Dictionary) -> Node3D:
	var res: Resource = load(placement["res_path"])
	var node: Node3D
	if res is PackedScene:
		node = (res as PackedScene).instantiate()
	else:
		node = Node3D.new()
		var mesh_instance := MeshInstance3D.new()
		if res is Mesh:
			mesh_instance.mesh = res
		node.add_child(mesh_instance)
	node.name = String(placement.get("asset_id", "kit_piece"))
	node.position = placement["position"]
	node.rotation_degrees = Vector3(0.0, placement["rotation_deg"], 0.0)
	var s: float = placement["scale"]
	node.scale = Vector3(s, s, s)
	return node
