extends Node3D
## THE EVOLUTION ROOM — Liam's dedicated evolution page rendered IN-ENGINE. The web page
## (Resonance-Website /aperture/evolution, branch feat/aperture-evolution-pages) and this room
## are TWO VIEWS OF THE SAME SUBSTRATE (EvolverSubstrate — the exact files + record schemas the
## web evolution API reads/writes). Spec trace (Liam verbatim 2026-07-02):
##   item 2 — ALL evolution on a dedicated page, generation-grouped: every evolver_candidate
##            card appears in a COLUMN PER GENERATION (ascending, unknown last), decided cards
##            annotated (the history stays visible, like the web page).
##   item 3 — selecting a candidate opens ITS OWN detail view: large live-rendered preview,
##            re-rolled mutation variants rendered live in-engine, and SAVE-AS-BRANCH-OFF-
##            GENERATION (append-only branches.jsonl, byte-compatible with the web endpoint).
##
## READ  — GET /api/aperture/evolver (the same endpoint the web page calls) when :8770 is up;
##         file fallback otherwise: inbox.jsonl + feedback.jsonl + the shared evolver state dir.
## WRITE — X cull / E evolve / V save go through ApertureActions (the same feedback channel the
##         web buttons post); save-as-branch appends the exact web branch record to
##         branches.jsonl (the web page lists what the engine saved, and vice versa).
##
## Controls: WASD+mouse fly (click captures, ESC releases) · aim a candidate: X cull, E evolve,
## V save, ENTER open detail · in detail: N re-roll variants, aim + G save-as-branch,
## BACKSPACE back · R refresh · TAB back to the aperture board.
##
## Open:      <Godot> --path godot res://aperture/evolution_3d.tscn
## Proof PNG: ... res://aperture/evolution_3d.tscn -- --shot   → godot/docs/evolution_3d.png
## Offline:   ... -- --offline                                 (skip the HTTP fetch)

const PARAMS_PATH := "res://state/aperture3d/aperture3d_params.json"
const SHOT_PATH := "res://docs/evolution_3d.png"
const N_VARIANTS := 4
const GRID_TEX := 96
const DETAIL_TEX := 256

var cfg := {
	"base_url": "http://127.0.0.1:8770",
	"inbox_path": "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl",
	"feedback_path": "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl",
	"bookmarks_path": "G:/Wavelet/Alethea-cc/state/aperture/bookmarks.jsonl",
	"state_dir": EvolverSubstrate.DEFAULT_STATE_DIR,
}

var groups: Array = []            # [{generation, cards}] — the grouped index (web-identical)
var branches: Array = []          # all branch records
var actions_channel := "http"     # whichever channel the fetch used; actions follow it

var _cam: Camera3D = null
var _hud: Label = null
var _status: Label = null
var _grid_root: Node3D = null
var _detail_root: Node3D = null
var _detail_card := {}
var _variants: Array = []         # EvolverGenome dicts of the current re-roll
var _variant_seed := 0
var _aimed := {}
var _yaw := 0.0
var _pitch := 0.0
var _did_shot := false
var _headless := DisplayServer.get_name() == "headless"

func _ready() -> void:
	_load_params()
	_build_env()
	_build_floor()
	_build_camera()
	_build_hud()
	_fetch_index()
	if "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args():
		await _take_shot()

# ---------------------------------------------------------------------------------------------------
# index fetch — the web page's own endpoint first, substrate files as fallback
# ---------------------------------------------------------------------------------------------------

func _fetch_index() -> void:
	if "--offline" in OS.get_cmdline_user_args() or "--offline" in OS.get_cmdline_args():
		_load_from_files("substrate file (offline)")
		return
	var req := HTTPRequest.new()
	req.timeout = 4.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200 and _apply_http_index(body.get_string_from_utf8()):
			actions_channel = "http"
			_rebuild_grid("http /api/aperture/evolver")
		else:
			_load_from_files("substrate file (server down)"))
	if req.request(String(cfg.get("base_url")) + "/api/aperture/evolver") != OK:
		req.queue_free()
		_load_from_files("substrate file (server down)")

## Parse the /api/aperture/evolver body — the SAME payload evolution.js renders. Media URLs come
## as /api/aperture/media?path=... ; map them back to local paths (identity is the local file).
func _apply_http_index(text: String) -> bool:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not bool(data.get("ok", false)):
		return false
	groups = []
	for g in data.get("generations", []):
		if typeof(g) != TYPE_DICTIONARY:
			continue
		var cards: Array = []
		for row in g.get("cards", []):
			if typeof(row) != TYPE_DICTIONARY:
				continue
			var raw: Dictionary = row
			_media_to_local(raw)
			var card := ApertureInbox.normalize_card(raw)
			# carry the server-side joins over onto the normalized card
			for k in ["decided", "decision", "genome_id", "genome", "caption"]:
				card[k] = raw.get(k)
			if raw.get("generation") != null:
				card["generation"] = int(raw.get("generation"))
			cards.append(card)
		groups.append({ "generation": String(g.get("generation", "?")), "cards": cards })
	branches = []
	for b in data.get("branches", []):
		if typeof(b) == TYPE_DICTIONARY:
			var br: Dictionary = b
			if br.get("image") != null:
				br["image"] = EvolverSubstrate.media_url_to_local(String(br.get("image")))
			branches.append(br)
	return true

func _load_from_files(via: String) -> void:
	actions_channel = "file"
	var rows := EvolverSubstrate.evolver_rows(
		String(cfg.get("inbox_path")), String(cfg.get("feedback_path")), String(cfg.get("state_dir")))
	groups = EvolverSubstrate.group_by_generation(rows)
	branches = EvolverSubstrate.read_branches(String(cfg.get("state_dir")))
	_rebuild_grid(via)

func _writer() -> ApertureActions:
	return ApertureActions.new({
		"mode": actions_channel,
		"base_url": cfg.get("base_url"),
		"feedback_path": cfg.get("feedback_path"),
		"bookmarks_path": cfg.get("bookmarks_path"),
	})

# ---------------------------------------------------------------------------------------------------
# grid view — one column per generation (spec item 2), branches column last
# ---------------------------------------------------------------------------------------------------

const TILE := 1.8
const CELL_W := 2.1
const CELL_H := 2.5
const COL_GAP := 1.6
const PER_ROW := 3

func _rebuild_grid(via: String) -> void:
	if _grid_root != null:
		_grid_root.queue_free()
	_grid_root = Node3D.new()
	_grid_root.name = "Grid"
	add_child(_grid_root)
	var x0 := 0.0
	var n_cards := 0
	for g in groups:
		var cards: Array = (g as Dictionary).get("cards", [])
		n_cards += cards.size()
		var block_w := minf(cards.size(), PER_ROW) * CELL_W
		_column_header(x0 + block_w * 0.5 - CELL_W * 0.5, "generation %s" % String((g as Dictionary).get("generation")))
		for i in cards.size():
			var card: Dictionary = cards[i]
			var tile := _make_tile(TILE, _card_image(card, GRID_TEX), _card_lines(card),
				{ "card_id": String(card.get("id")) })
			tile.position = Vector3(x0 + (i % PER_ROW) * CELL_W, 1.6 + float(i / PER_ROW) * CELL_H, -6.0)
			_grid_root.add_child(tile)
		x0 += block_w + COL_GAP
	if branches.size() > 0:
		var bw := minf(branches.size(), PER_ROW) * CELL_W
		_column_header(x0 + bw * 0.5 - CELL_W * 0.5, "branches")
		for i in branches.size():
			var b: Dictionary = branches[i]
			var tile := _make_tile(TILE * 0.8, _branch_image(b, GRID_TEX),
				["%s  off gen %d" % [String(b.get("branch_id", "")), int(b.get("off_generation", 0))],
					EvolverSubstrate.genome_caption(b.get("genome"))],
				{ "branch_id": String(b.get("branch_id", "")) })
			tile.position = Vector3(x0 + (i % PER_ROW) * CELL_W, 1.6 + float(i / PER_ROW) * CELL_H, -6.0)
			_grid_root.add_child(tile)
	_set_status("%d candidates in %d generations · %d branches · source: %s · actions: %s" %
		[n_cards, groups.size(), branches.size(), via, actions_channel])

func _column_header(x: float, text: String) -> void:
	var l := Label3D.new()
	l.text = text
	l.font_size = 56
	l.pixel_size = 0.008
	l.modulate = Color(0.85, 0.9, 1.0)
	l.position = Vector3(x, 0.35, -6.0)
	_grid_root.add_child(l)

func _card_lines(card: Dictionary) -> Array:
	var lines := [String(card.get("title", ""))]
	var cap := String(card.get("caption", "")) if card.get("caption") != null else ""
	if cap != "":
		lines.append(cap)
	if bool(card.get("decided", false)):
		lines.append("decided: %s" % String(card.get("decision", "")))
	return lines

## The card's face: live-synthesized from its genome when it is a texture genome (the engine IS
## the renderer), else its pushed PNG.
func _card_image(card: Dictionary, size: int) -> Image:
	var genome = card.get("genome")
	if typeof(genome) == TYPE_DICTIONARY:
		var stack = (genome as Dictionary).get("stack", {})
		if typeof(stack) == TYPE_DICTIONARY and (stack as Dictionary).has("texture_ops"):
			return TextureSynthCpu.synthesize(stack, size, size)
	for im in card.get("images", []):
		if ApertureInbox.is_local(String(im)) and FileAccess.file_exists(String(im)):
			var img := Image.new()
			if img.load(String(im)) == OK:
				return img
	return _placeholder(size)

func _branch_image(b: Dictionary, size: int) -> Image:
	var genome = b.get("genome")
	if typeof(genome) == TYPE_DICTIONARY:
		var stack = (genome as Dictionary).get("stack", {})
		if typeof(stack) == TYPE_DICTIONARY and (stack as Dictionary).has("texture_ops"):
			return TextureSynthCpu.synthesize(stack, size, size)
	var p = b.get("image")
	if p != null and ApertureInbox.is_local(String(p)) and FileAccess.file_exists(String(p)):
		var img := Image.new()
		if img.load(String(p)) == OK:
			return img
	return _placeholder(size)

func _placeholder(size: int) -> Image:
	var img := Image.create(size, size, false, Image.FORMAT_RGB8)
	img.fill(Color(0.2, 0.2, 0.24))
	return img

## One pickable textured tile + caption lines. `metas` land on the Area3D for the aim ray.
func _make_tile(size: float, img: Image, lines: Array, metas: Dictionary) -> Node3D:
	var root := Node3D.new()
	var mi := MeshInstance3D.new()
	var quad := QuadMesh.new()
	quad.size = Vector2(size, size)
	mi.mesh = quad
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_texture = ImageTexture.create_from_image(img)
	mi.material_override = mat
	root.add_child(mi)
	var lbl := Label3D.new()
	lbl.name = "Caption"
	lbl.text = "\n".join(PackedStringArray(lines))
	lbl.pixel_size = 0.0032
	lbl.width = 560.0
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lbl.modulate = Color(0.9, 0.92, 0.88)
	lbl.position = Vector3(0, -(size * 0.5 + 0.24), 0)
	root.add_child(lbl)
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(size, size, 0.15)
	shape.shape = box
	area.add_child(shape)
	for k in metas.keys():
		area.set_meta(k, metas[k])
	root.add_child(area)
	return root

# ---------------------------------------------------------------------------------------------------
# detail view — one artifact's own page (spec item 3): live preview + variants + save-as-branch
# ---------------------------------------------------------------------------------------------------

func _find_card(id: String) -> Dictionary:
	for g in groups:
		for c in (g as Dictionary).get("cards", []):
			if String((c as Dictionary).get("id")) == id:
				return c
	return {}

func _open_detail(card: Dictionary) -> void:
	_detail_card = card
	_grid_root.visible = false
	_variant_seed = int(Time.get_ticks_usec() % 1000000)
	_build_detail()

func _close_detail() -> void:
	_detail_card = {}
	if _detail_root != null:
		_detail_root.queue_free()
		_detail_root = null
	_grid_root.visible = true

func _detail_genome() -> Dictionary:
	var g = _detail_card.get("genome")
	return g if typeof(g) == TYPE_DICTIONARY else {}

func _build_detail() -> void:
	if _detail_root != null:
		_detail_root.queue_free()
	_detail_root = Node3D.new()
	_detail_root.name = "Detail"
	add_child(_detail_root)
	var card := _detail_card
	# large live-rendered base
	var base := _make_tile(2.8, _card_image(card, DETAIL_TEX),
		[String(card.get("title", "")), String(card.get("caption", "")) if card.get("caption") != null else "",
			"gen %d · %s" % [int(card.get("generation", -1)), String(card.get("id", ""))]],
		{ "detail_base": true, "card_id": String(card.get("id")) })
	base.position = Vector3(-3.4, 2.3, -5.0)
	_detail_root.add_child(base)
	# variants: mutated children of the base genome, rendered LIVE in-engine (no restart, no
	# subprocess — the same mutation the render CLI's --variants applies: EvolverGenome.inject_mutated)
	_variants = []
	var genome := _detail_genome()
	if typeof(genome.get("stack")) == TYPE_DICTIONARY and (genome.get("stack") as Dictionary).has("texture_ops"):
		var eg := EvolverGenome.from_dict(genome)
		var rng := RandomNumberGenerator.new()
		rng.seed = _variant_seed
		for i in N_VARIANTS:
			var child := EvolverGenome.inject_mutated(eg, eg.generation, rng)
			var cd := child.to_dict()
			_variants.append(cd)
			var vt := _make_tile(1.6, TextureSynthCpu.synthesize(cd.get("stack", {}), DETAIL_TEX, DETAIL_TEX),
				["variant %d" % i, EvolverSubstrate.genome_caption(cd)],
				{ "variant_index": i })
			vt.position = Vector3(-0.4 + i * 1.95, 3.1, -5.0)
			_detail_root.add_child(vt)
	# branches already saved off this card
	var my_branches := EvolverSubstrate.branches_for(String(cfg.get("state_dir")), String(card.get("id")))
	for i in my_branches.size():
		var b: Dictionary = my_branches[i]
		var bt := _make_tile(1.1, _branch_image(b, GRID_TEX),
			["%s off gen %d" % [String(b.get("branch_id")), int(b.get("off_generation", 0))]],
			{ "branch_id": String(b.get("branch_id")) })
		bt.position = Vector3(-0.4 + i * 1.5, 0.9, -5.0)
		_detail_root.add_child(bt)
	var head := Label3D.new()
	head.text = "N re-roll variants · aim + G = save as branch off gen %d · BACKSPACE back" % int(card.get("generation", 0))
	head.pixel_size = 0.0045
	head.modulate = Color(0.8, 0.95, 0.8)
	head.position = Vector3(-0.5, 4.6, -5.0)
	_detail_root.add_child(head)

## G on an aimed variant (or the base): render its PNG next to the map, append the branch record
## (the exact web schema) — the web evolution page lists it on next load.
func _save_branch_aimed() -> void:
	if _detail_card.is_empty():
		return
	var genome := {}
	if _aimed.has("variant_index"):
		var vi := int(_aimed.get("variant_index"))
		if vi >= 0 and vi < _variants.size():
			genome = _variants[vi]
	elif _aimed.has("detail_base"):
		genome = _detail_genome()
	if genome.is_empty():
		_set_status("aim a variant (or the base) to save it as a branch")
		return
	var state_dir := String(cfg.get("state_dir"))
	var img_path := ""
	var stack = genome.get("stack", {})
	if typeof(stack) == TYPE_DICTIONARY and (stack as Dictionary).has("texture_ops"):
		var img := TextureSynthCpu.synthesize(stack, DETAIL_TEX, DETAIL_TEX)
		var dir := EvolverSubstrate._abs(state_dir).path_join("branches")
		DirAccess.make_dir_recursive_absolute(dir)
		img_path = dir.path_join("branch_%d.png" % int(Time.get_unix_time_from_system() * 1000000.0))
		img.save_png(img_path)
	var res := EvolverSubstrate.append_branch(state_dir, String(_detail_card.get("id")), genome,
		int(_detail_card.get("generation", -1)), img_path)
	if bool(res.get("ok", false)):
		_set_status("branch %s saved off generation %d" % [String(res.get("branch_id")), int(res.get("off_generation"))])
		branches = EvolverSubstrate.read_branches(state_dir)
		_build_detail()
	else:
		_set_status("branch save FAILED: %s" % String(res.get("error", "?")))

# ---------------------------------------------------------------------------------------------------
# interactions
# ---------------------------------------------------------------------------------------------------

func _act_on_aimed(verb: String) -> void:
	var id := String(_aimed.get("card_id", ""))
	if id == "" and not _detail_card.is_empty():
		id = String(_detail_card.get("id"))
	if id == "":
		return
	var card := _find_card(id)
	if card.is_empty():
		return
	var action := verb
	if verb == "skip":
		action = "cull"  # the web ✕ posts cull on an evolver card
	var res := _writer().act(card, action)
	if not bool(res.get("ok", false)):
		_set_status("write FAILED (%s %s): %s" % [action, id, String(res.get("error", "?"))])
		return
	card["decided"] = true
	card["decision"] = action
	_set_status("%s → %s  (via %s channel)" % [id, action, actions_channel])
	if _detail_card.is_empty():
		_rebuild_grid("local")  # decided cards STAY, annotated — evolution-page semantics

func _unhandled_input(event: InputEvent) -> void:
	if _did_shot:
		return
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if Input.mouse_mode != Input.MOUSE_MODE_CAPTURED:
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_yaw -= event.relative.x * 0.0026
		_pitch = clampf(_pitch - event.relative.y * 0.0026, -1.4, 1.4)
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_ESCAPE:
				Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			KEY_X:
				_act_on_aimed("skip")
			KEY_E:
				_act_on_aimed("evolve")
			KEY_V:
				_act_on_aimed("save")
			KEY_ENTER, KEY_KP_ENTER:
				var id := String(_aimed.get("card_id", ""))
				if _detail_card.is_empty() and id != "":
					var card := _find_card(id)
					if not card.is_empty():
						_open_detail(card)
			KEY_BACKSPACE:
				if not _detail_card.is_empty():
					_close_detail()
			KEY_N:
				if not _detail_card.is_empty():
					_variant_seed = int(Time.get_ticks_usec() % 1000000)
					_build_detail()
			KEY_G:
				_save_branch_aimed()
			KEY_R:
				if _detail_card.is_empty():
					_fetch_index()
			KEY_TAB:
				get_tree().change_scene_to_file("res://aperture/aperture_3d.tscn")

# ---------------------------------------------------------------------------------------------------
# fly camera + aim + environment (the aperture_3d rig, compact)
# ---------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _cam == null:
		return
	_cam.rotation = Vector3(_pitch, _yaw, 0)
	if Input.mouse_mode == Input.MOUSE_MODE_CAPTURED and not _did_shot:
		var fwd := -_cam.global_transform.basis.z
		var right := _cam.global_transform.basis.x
		var dir := Vector3.ZERO
		if Input.is_key_pressed(KEY_W): dir += fwd
		if Input.is_key_pressed(KEY_S): dir -= fwd
		if Input.is_key_pressed(KEY_D): dir += right
		if Input.is_key_pressed(KEY_A): dir -= right
		if Input.is_key_pressed(KEY_SPACE): dir += Vector3.UP
		if Input.is_key_pressed(KEY_SHIFT): dir += Vector3.DOWN
		if dir.length_squared() > 0.001:
			_cam.position += dir.normalized() * (8.0 if Input.is_key_pressed(KEY_CTRL) else 4.0) * delta
	_update_aim()

func _update_aim() -> void:
	_aimed = {}
	if _headless or _cam == null:
		return
	var vp := get_viewport()
	var center := vp.get_visible_rect().size * 0.5
	var from := _cam.project_ray_origin(center)
	var to := from + _cam.project_ray_normal(center) * 60.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = true
	query.collide_with_bodies = false
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.has("collider"):
		var col: Object = hit["collider"]
		for k in ["card_id", "variant_index", "detail_base", "branch_id"]:
			if col.has_meta(k):
				_aimed[k] = col.get_meta(k)
	if _hud != null:
		var aim_txt := ""
		if _aimed.has("card_id") and not _aimed.has("detail_base"):
			aim_txt = "\naimed: %s" % String(_aimed.get("card_id"))
		elif _aimed.has("variant_index"):
			aim_txt = "\naimed: variant %d" % int(_aimed.get("variant_index"))
		elif _aimed.has("detail_base"):
			aim_txt = "\naimed: base"
		elif _aimed.has("branch_id"):
			aim_txt = "\naimed: %s" % String(_aimed.get("branch_id"))
		_hud.text = _controls_text() + aim_txt

func _load_params() -> void:
	if not FileAccess.file_exists(PARAMS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	for block in ["inbox", "evolver"]:
		var sub: Dictionary = parsed.get(block, {})
		for k in sub.keys():
			if cfg.has(k):
				cfg[k] = sub[k]
	_sky_desc = parsed.get("sky", PainterlySky.default_descriptor())

var _sky_desc := {}

func _build_env() -> void:
	var desc: Dictionary = _sky_desc if not _sky_desc.is_empty() else PainterlySky.default_descriptor()
	var built := PainterlySky.build(desc)
	var env_node := WorldEnvironment.new()
	env_node.environment = built["environment"]
	add_child(env_node)
	add_child(built["sun"])

func _build_floor() -> void:
	var ground := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = 40.0
	disk.bottom_radius = 40.0
	disk.height = 0.1
	ground.mesh = disk
	ground.position = Vector3(12, -0.05, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.22, 0.24, 0.26)
	mat.roughness = 0.95
	ground.material_override = mat
	add_child(ground)

func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.position = Vector3(4.0, 2.4, 4.0)
	add_child(_cam)
	_cam.make_current()

func _controls_text() -> String:
	return ("EVOLUTION ROOM — generation columns, same substrate as the web evolution page\n" +
		"WASD+mouse fly · X cull · E evolve · V save · ENTER open artifact · R refresh · TAB board\n" +
		"detail: N re-roll variants · aim + G save-as-branch · BACKSPACE back")

func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	_hud = Label.new()
	_hud.text = _controls_text()
	_hud.position = Vector2(12, 10)
	_hud.add_theme_font_size_override("font_size", 13)
	layer.add_child(_hud)
	_status = Label.new()
	_status.position = Vector2(12, 76)
	_status.add_theme_font_size_override("font_size", 13)
	_status.modulate = Color(0.7, 0.95, 0.7)
	layer.add_child(_status)
	var cross := Label.new()
	cross.text = "+"
	cross.set_anchors_preset(Control.PRESET_CENTER)
	cross.add_theme_font_size_override("font_size", 22)
	layer.add_child(cross)

func _set_status(msg: String) -> void:
	if _status != null:
		_status.text = msg
	print("[evolution_3d] ", msg)

func _take_shot() -> void:
	_did_shot = true
	if _headless:
		print("[evolution_3d] --shot needs a display (run without --headless). Exit 2.")
		get_tree().quit(2)
		return
	await get_tree().create_timer(2.5).timeout
	_yaw = deg_to_rad(6.0)
	_pitch = -0.02
	_cam.position = Vector3(9.0, 3.4, 6.5)
	for _i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(SHOT_PATH)
	print("[evolution_3d] proof written: %s (%d groups)" % [SHOT_PATH, groups.size()])
	get_tree().quit(0)
