class_name LiveWall
extends Node3D
## LIVE ITERATION FROM WITHIN THE ENGINE — the wall of texture tiles inside the Godot Aperture
## that proves the full in-engine loop with NO restart:
##
##   in-engine control (keys) → edits the arrangement JSON ON DISK → the standard LiveHost
##   content-hash watcher picks the change up → GraphRuntime re-wires from data → the wall
##   re-synthesizes its tile textures → the scene visibly updates.
##
## The write deliberately goes THROUGH THE FILE (never a direct in-memory poke): the file is the
## system-neutral channel, so the same edit made by Claude Code, the web GUI, or a python tool
## produces the identical live update. The wall is an ARRANGEMENT of Const nodes whose values are
## texture-genome descriptors ({texture_ops:[...]}) — pure data end to end.
##
## It ALSO carries the in-engine EVOLVER TICK (key T on the parent surface): one EvolverTick step
## over a MOCK texture-genome population persisted under the same state dir. Candidate tiles render
## in a second row; deciding a candidate (evolve/save/cull) appends to the tick's mock feedback
## file — the SAME file schema PrimApertureSurface reads back — and once every candidate is
## decided the next tick BREEDS generation+1 and the row re-renders in place.

const TILE_SIZE := 1.4
const TILE_GAP := 0.25
const TEX_W := 128
const TEX_H := 128

var state_dir := "res://state/aperture3d"        # gitignored live-state home
var runtime: GraphRuntime = null
var live_host: LiveHost = null

var _wall_tiles: Array = []       # MeshInstance3D per wall tile (index-aligned with tile ids)
var _cand_tiles: Array = []       # candidate row nodes
var _tick_report: Dictionary = {}

func arrangement_path() -> String:
	return state_dir + "/wall_arrangement.json"

func evolver_dir() -> String:
	return state_dir + "/evolver"

func mock_feedback_path() -> String:
	return evolver_dir() + "/feedback.json"

# ---------------------------------------------------------------------------------------------------
# setup — seed the arrangement (if absent), mount runtime + LiveHost, first render
# ---------------------------------------------------------------------------------------------------

func setup(dir: String = "res://state/aperture3d", n_tiles: int = 4, seed_v: int = 20260702) -> void:
	state_dir = dir
	var abs := _abs(state_dir)
	DirAccess.make_dir_recursive_absolute(abs)
	if not FileAccess.file_exists(arrangement_path()):
		seed_arrangement(arrangement_path(), n_tiles, seed_v)
	runtime = GraphRuntime.new()
	add_child(runtime)
	live_host = LiveHost.new()
	live_host.runtime = runtime
	live_host.path = arrangement_path()
	live_host.reloaded.connect(_rebuild_tiles)
	add_child(live_host)
	live_host.poll_once()  # initial load + first _rebuild_tiles

# ---------------------------------------------------------------------------------------------------
# the wall — one textured quad per Const tile node, re-synthesized on every hotload
# ---------------------------------------------------------------------------------------------------

func _rebuild_tiles() -> void:
	var ids := tile_ids(runtime)
	# grow/shrink the tile pool to match the arrangement
	while _wall_tiles.size() < ids.size():
		_wall_tiles.append(_make_tile(_wall_tiles.size(), 1.6, "wall"))
	while _wall_tiles.size() > ids.size():
		var extra = _wall_tiles.pop_back()
		extra.queue_free()
	for i in ids.size():
		var prim: Primitive = runtime.nodes[ids[i]]
		var desc: Dictionary = prim.params.get("value", {})
		_apply_texture(_wall_tiles[i], desc)
		var lbl: Label3D = _wall_tiles[i].get_node_or_null("Caption")
		if lbl != null:
			lbl.text = "%s  rev %d\n%s" % [ids[i], live_host.rev, _gene_caption(desc)]

## The tile node ids of the loaded arrangement, in stable sorted order.
static func tile_ids(rt: GraphRuntime) -> Array:
	var ids: Array = []
	for id in rt.nodes.keys():
		if String(id).begins_with("tile"):
			ids.append(String(id))
	ids.sort()
	return ids

func _make_tile(index: int, y: float, kind: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(TILE_SIZE, TILE_SIZE)
	mi.mesh = quad
	mi.position = Vector3(index * (TILE_SIZE + TILE_GAP), y, 0.0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mi.material_override = mat
	var lbl := Label3D.new()
	lbl.name = "Caption"
	lbl.pixel_size = 0.004
	lbl.position = Vector3(0, -(TILE_SIZE * 0.5 + 0.18), 0.0)
	lbl.modulate = Color(0.92, 0.92, 0.88)
	mi.add_child(lbl)
	# pickable body so the parent surface can target tiles with the crosshair ray
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(TILE_SIZE, TILE_SIZE, 0.1)
	shape.shape = box
	area.add_child(shape)
	area.set_meta("wall_kind", kind)
	area.set_meta("wall_index", index)
	mi.add_child(area)
	add_child(mi)
	return mi

func _apply_texture(mi: MeshInstance3D, desc: Dictionary) -> void:
	var img := TextureSynthCpu.synthesize(desc, TEX_W, TEX_H)
	var mat := mi.material_override as StandardMaterial3D
	mat.albedo_texture = ImageTexture.create_from_image(img)

func _gene_caption(desc: Dictionary) -> String:
	var ops: Array = desc.get("texture_ops", [])
	var names: Array = []
	for op in ops:
		if typeof(op) == TYPE_DICTIONARY:
			names.append(String(op.get("type", "?")))
	return " + ".join(names)

# ---------------------------------------------------------------------------------------------------
# pure data helpers — arrangement seeding + the on-disk gene edit (the hotload channel)
# ---------------------------------------------------------------------------------------------------

## Write a fresh wall arrangement: n Const tile nodes, each carrying a random (seeded) texture
## genome descriptor. Deterministic given seed_v.
static func seed_arrangement(path: String, n: int, seed_v: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	var nodes: Array = []
	for i in n:
		var g := TextureGenome.random(3, rng)
		nodes.append({ "id": "tile%d" % i, "type": "Const", "params": { "value": g.to_stack() } })
	var data := {
		"format": "resonance.arrangement/v1",
		"name": "aperture3d_live_wall",
		"rev": 1,
		"nodes": nodes,
		"wires": [],
	}
	_write_json(path, data)

## The IN-ENGINE CONTROL's write path: read the arrangement file, scale one numeric gene of the
## given tile's first op by `factor` (schema-aware: the gene is looked up in TextureSynthCpu.
## OP_TYPES, scaled, then CLAMPED to its declared range and re-rounded when int-typed — the edit
## stays closed over the synthesizer's schema exactly like the genome operators), bump rev, write
## the file back. The running LiveHost sees the content change and hotloads — this function
## itself never touches the runtime. Returns { ok, gene, from, to, rev }.
static func nudge_gene(path: String, tile_index: int, factor: float) -> Dictionary:
	var text := FileAccess.get_file_as_string(path)
	if text == "":
		return { "ok": false, "error": "arrangement missing" }
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		return { "ok": false, "error": "arrangement malformed" }
	var target_id := "tile%d" % tile_index
	for n in data.get("nodes", []):
		if String(n.get("id")) != target_id:
			continue
		var ops: Array = (n.get("params", {}) as Dictionary).get("value", {}).get("texture_ops", [])
		if ops.is_empty():
			return { "ok": false, "error": "tile has no ops" }
		var op0: Dictionary = ops[0]
		var op_type := String(op0.get("type", ""))
		var op_params: Dictionary = op0.get("params", {})
		var pick := _live_gene(op_type, op_params)
		if pick.is_empty():
			return { "ok": false, "error": "no numeric gene" }
		var gene := String(pick["gene"])
		var spec: Dictionary = pick["spec"]
		var from_v := float(op_params[gene])
		var to_v := clampf(from_v * factor, float(spec.get("min", -INF)), float(spec.get("max", INF)))
		if String(spec.get("type", "float")) == "int":
			to_v = float(int(round(to_v)))
		if to_v == from_v:
			# clamped against the range edge — step INTO the range instead so the edit is visible
			to_v = clampf(from_v * (2.0 - factor), float(spec.get("min", -INF)), float(spec.get("max", INF)))
		op_params[gene] = to_v
		data["rev"] = int(data.get("rev", 0)) + 1
		_write_json(path, data)
		return { "ok": true, "gene": gene, "from": from_v, "to": to_v, "rev": data["rev"] }
	return { "ok": false, "error": "tile not found" }

## Pick the live knob for an op: the first FLOAT-typed schema gene (sorted-key order) present in
## the op's params; falls back to the first int-typed one. Deterministic, schema-driven.
static func _live_gene(op_type: String, op_params: Dictionary) -> Dictionary:
	var schema: Dictionary = (TextureSynthCpu.OP_TYPES.get(op_type, {}) as Dictionary).get("params", {})
	var keys := op_params.keys()
	keys.sort()
	for want_type in ["float", "int"]:
		for k in keys:
			var spec: Dictionary = schema.get(String(k), {})
			if String(spec.get("type", "")) == want_type:
				return { "gene": String(k), "spec": spec }
	return {}

# ---------------------------------------------------------------------------------------------------
# the in-engine evolver tick — one mock texture-genome generation step, re-rendered in place
# ---------------------------------------------------------------------------------------------------

## Run ONE EvolverTick over the wall's mock texture population (never the live Aperture) and
## re-render the candidate row from the persisted state. Returns the tick report.
func evolver_tick(seed_v: int = 424242) -> Dictionary:
	_tick_report = run_tick(evolver_dir(), mock_feedback_path(), seed_v)
	_rebuild_candidates()
	return _tick_report

## Pure driver (shared with the headless test): one mock EvolverTick step under `dir`.
static func run_tick(dir: String, feedback_path: String, seed_v: int) -> Dictionary:
	return EvolverTick.run_once({
		"state_dir": dir,
		"mode": "mock",
		"seed": seed_v,
		"meta_genome": { "population_size": 4, "n_inject": 1, "seed_layers": 3,
			"genome_kind": "texture",
			"actions": [ { "id": "evolve", "label": "Evolve" }, { "id": "save", "label": "Save" } ] },
		"thumb_dir": dir + "/thumbs",
		"width": 64, "height": 64,
		"mock_feedback_path": feedback_path if FileAccess.file_exists(feedback_path) else "",
	})

## Record an in-engine decision on a candidate card into the tick's MOCK feedback file — the
## same flat {card_id: action} map PrimApertureSurface._mock_feedback reads back. Merge-write
## (latest wins per card) so pressing a different verb overrides.
static func record_mock_decision(feedback_path: String, card_id: String, action: String) -> void:
	var map := {}
	if FileAccess.file_exists(feedback_path):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(feedback_path))
		if typeof(parsed) == TYPE_DICTIONARY:
			map = parsed
	map[card_id] = action
	_write_json(feedback_path, map)

func decide_candidate(card_id: String, action: String) -> void:
	record_mock_decision(mock_feedback_path(), card_id, action)
	# reflect the decision on the tile caption immediately
	for t in _cand_tiles:
		if String(t.get_meta("card_id", "")) == card_id:
			var lbl: Label3D = t.get_node_or_null("Caption")
			if lbl != null and not String(lbl.text).contains("decided"):
				lbl.text += "\ndecided: %s" % action

func _rebuild_candidates() -> void:
	for t in _cand_tiles:
		t.queue_free()
	_cand_tiles.clear()
	var state := EvolverState.load_state(evolver_dir())
	var population: Array = state.get("population", [])
	var cards: Array = state.get("cards", [])
	var generation := int(state.get("generation", 0))
	var decided := _mock_decisions()
	for i in population.size():
		var genome: Dictionary = population[i]
		var mi := _make_tile(i, 0.0, "candidate")
		var desc: Dictionary = (genome.get("stack", {}) as Dictionary)
		_apply_texture(mi, desc)
		var card_id := ""
		if i < cards.size() and typeof(cards[i]) == TYPE_DICTIONARY:
			card_id = String((cards[i] as Dictionary).get("card_id", ""))
		mi.set_meta("card_id", card_id)
		var area: Area3D = null
		for c in mi.get_children():
			if c is Area3D:
				area = c
		if area != null:
			area.set_meta("card_id", card_id)
		var lbl: Label3D = mi.get_node_or_null("Caption")
		if lbl != null:
			lbl.text = "gen %d · cand %d" % [generation, i]
			if decided.has(card_id):
				lbl.text += "\ndecided: %s" % decided[card_id]
		_cand_tiles.append(mi)

func _mock_decisions() -> Dictionary:
	var p := mock_feedback_path()
	if not FileAccess.file_exists(p):
		return {}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(p))
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}

func generation() -> int:
	return int(EvolverState.load_state(evolver_dir()).get("generation", 0))

# ---------------------------------------------------------------------------------------------------
# util
# ---------------------------------------------------------------------------------------------------

static func _abs(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path

static func _write_json(path: String, data) -> void:
	var abs := _abs(path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data, "\t"))
		f.close()
