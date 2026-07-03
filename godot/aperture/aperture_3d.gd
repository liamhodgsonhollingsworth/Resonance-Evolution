extends Node3D
## THE GODOT APERTURE (3D) — the live Aperture inbox rendered IN-ENGINE as a walkable gallery,
## with FULL action equivalence to the web board at :8770. Two surfaces, ONE substrate:
##   READ  — GET /api/aperture/inbox via HTTPRequest; when :8770 is down it falls back to reading
##           the substrate JSONL directly (source selection is DATA — see `source_cfg`).
##   WRITE — skip ✕ / bookmark ★ / evolve / save go through the SAME channel the web board uses:
##           POST /api/aperture/feedback + /api/aperture/bookmark in http mode, or append the
##           identical schema rows to feedback.jsonl / bookmarks.jsonl in file mode. Either way
##           aperture_feedback.py reads the decision back — the pushing session cannot tell which
##           surface Liam used.
##
## Each pending card is a 3D panel (image → a real textured quad; text cards render their text)
## laid out in an orbitable arc. Fly with WASD + mouse (click captures, ESC releases), aim the
## crosshair at a card and press: X = skip (✕; cull on an evolver card), B = bookmark toggle,
## E = evolve, V = save. Decided cards leave the board, exactly like the web surface.
##
## The LIVE WALL on the left is the in-engine iteration loop (LiveWall): [ / ] nudge a texture
## gene of the aimed wall tile — the key edits the arrangement JSON ON DISK, the LiveHost watcher
## hotloads it, the wall retextures live (no restart). T = one mock evolver tick (never the live
## Aperture): candidates render as a row; decide them with E/V/X and the next T breeds gen+1.
##
## Open:            <Godot> --path godot res://aperture/aperture_3d.tscn
## Proof PNG:       ... res://aperture/aperture_3d.tscn -- --shot     → godot/docs/aperture_3d.png
## Force file mode: ... -- --offline                                  (skip the HTTP fetch)

const PARAMS_PATH := "res://state/aperture3d/aperture3d_params.json"
const SHOT_PATH := "res://docs/aperture_3d.png"
const CARD_W := 2.6
const CARD_H := 2.0

## Source/channel config (DATA; overridable via PARAMS_PATH `inbox` block). mode "auto" tries
## http first and falls back to file; "http" / "file" force one channel.
var source_cfg := {
	"mode": "auto",
	"url": "http://127.0.0.1:8770/api/aperture/inbox",
	"base_url": "http://127.0.0.1:8770",
	"inbox_path": "G:/Wavelet/Alethea-cc/state/aperture/inbox/inbox.jsonl",
	"feedback_path": "G:/Wavelet/Alethea-cc/state/aperture/feedback.jsonl",
	"bookmarks_path": "G:/Wavelet/Alethea-cc/state/aperture/bookmarks.jsonl",
}

var actions_channel := "http"      # decided after the fetch: whichever channel worked
var cards: Array = []              # normalized cards currently on the board
var wall: LiveWall = null

var _cam: Camera3D = null
var _panels := {}                  # card_id -> panel root Node3D
var _bookmarked := {}              # card_id -> true (local toggle state for ★)
var _aimed_meta := {}              # metas of the Area3D under the crosshair this frame
var _hud: Label = null
var _status: Label = null
var _yaw := 0.0
var _pitch := 0.0
var _did_shot := false
var _headless := DisplayServer.get_name() == "headless"
var _sky_hash := ""

func _ready() -> void:
	_load_params()
	_build_env()
	_build_floor()
	_build_camera()
	_build_hud()
	wall = LiveWall.new()
	wall.name = "LiveWall"
	wall.position = Vector3(-9.0, 1.2, -2.0)
	wall.rotation_degrees = Vector3(0, 55, 0)
	add_child(wall)
	wall.setup()
	_fetch_inbox()
	if _shot_requested():
		await _take_shot()

# ---------------------------------------------------------------------------------------------------
# inbox fetch — http first, substrate-file fallback (source selection as DATA)
# ---------------------------------------------------------------------------------------------------

func _fetch_inbox() -> void:
	var mode := String(source_cfg.get("mode", "auto"))
	if "--offline" in OS.get_cmdline_user_args() or "--offline" in OS.get_cmdline_args():
		mode = "file"
	if mode == "file":
		_use_file_channel()
		return
	var req := HTTPRequest.new()
	req.timeout = 4.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
		req.queue_free()
		if result == HTTPRequest.RESULT_SUCCESS and code == 200:
			var parsed := ApertureInbox.parse_inbox_body(body.get_string_from_utf8())
			if not parsed.is_empty():
				actions_channel = "http"
				_set_cards(parsed, "http :8770")
				return
		if mode == "auto":
			_use_file_channel()
		else:
			_set_status("inbox fetch failed (http %d)" % code))
	if req.request(String(source_cfg.get("url"))) != OK:
		req.queue_free()
		if mode == "auto":
			_use_file_channel()

func _use_file_channel() -> void:
	actions_channel = "file"
	var parsed := ApertureInbox.read_inbox_file(
		String(source_cfg.get("inbox_path")), String(source_cfg.get("feedback_path")))
	_set_cards(parsed, "substrate file (server down)")

func _set_cards(parsed: Array, via: String) -> void:
	cards = parsed
	_build_panels()
	_set_status("%d cards · source: %s · actions: %s" % [cards.size(), via, actions_channel])

## The action writer for the CURRENT channel — http when the fetch used the server, file when it
## fell back to the substrate. One writer per action keeps the config read fresh.
func _writer() -> ApertureActions:
	return ApertureActions.new({
		"mode": actions_channel,
		"base_url": source_cfg.get("base_url"),
		"feedback_path": source_cfg.get("feedback_path"),
		"bookmarks_path": source_cfg.get("bookmarks_path"),
	})

# ---------------------------------------------------------------------------------------------------
# card panels — one 3D panel per card, arranged in an orbitable arc
# ---------------------------------------------------------------------------------------------------

func _build_panels() -> void:
	for p in _panels.values():
		p.queue_free()
	_panels.clear()
	var n := cards.size()
	if n == 0:
		return
	var radius := maxf(7.0, n * 1.05)
	var span := deg_to_rad(minf(300.0, n * 24.0))
	for i in n:
		var card: Dictionary = cards[i]
		var ang := -span * 0.5 + span * (float(i) + 0.5) / float(n)
		var panel := _make_panel(card)
		panel.position = Vector3(sin(ang) * radius, 1.9, -cos(ang) * radius)
		panel.look_at(Vector3(0, 1.9, 0), Vector3.UP)
		add_child(panel)
		_panels[String(card.get("id"))] = panel

func _make_panel(card: Dictionary) -> Node3D:
	var root := Node3D.new()
	var id := String(card.get("id"))
	# backing slab
	var back := MeshInstance3D.new()
	var back_mesh := BoxMesh.new()
	back_mesh.size = Vector3(CARD_W + 0.2, CARD_H + 0.7, 0.08)
	back.mesh = back_mesh
	var back_mat := StandardMaterial3D.new()
	back_mat.albedo_color = Color(0.13, 0.14, 0.17)
	back_mat.roughness = 0.85
	back.material_override = back_mat
	back.position = Vector3(0, 0, -0.05)
	root.add_child(back)
	# media face: a REAL textured quad for image cards; body text for text cards
	var images: Array = card.get("images", [])
	var local := ""
	for im in images:
		if ApertureInbox.is_local(String(im)) and FileAccess.file_exists(String(im)):
			local = String(im)
			break
	if local != "":
		var quad := MeshInstance3D.new()
		var qm := QuadMesh.new()
		var img := Image.new()
		if img.load(local) == OK:
			var aspect := float(img.get_width()) / maxf(1.0, float(img.get_height()))
			var qw := CARD_W
			var qh := CARD_W / maxf(0.3, aspect)
			if qh > CARD_H:
				qh = CARD_H
				qw = CARD_H * aspect
			qm.size = Vector2(qw, qh)
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_texture = ImageTexture.create_from_image(img)
			quad.material_override = mat
			quad.mesh = qm
			quad.position = Vector3(0, 0.1, 0.02)
			root.add_child(quad)
	elif String(card.get("text", "")) != "":
		var body := Label3D.new()
		body.text = String(card.get("text")).left(360)
		body.pixel_size = 0.0032
		body.width = 700.0
		body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		body.modulate = Color(0.88, 0.9, 0.86)
		body.position = Vector3(0, 0.15, 0.02)
		root.add_child(body)
	# title + subtitle/summary + kind badge
	var title := Label3D.new()
	title.text = String(card.get("title", ""))
	title.pixel_size = 0.005
	title.width = 520.0
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	title.font_size = 40
	title.position = Vector3(0, -(CARD_H * 0.5) + 0.12, 0.03)
	root.add_child(title)
	var sub := String(card.get("subtitle", ""))
	if sub == "":
		sub = String(card.get("summary", "")).left(140)
	if sub != "":
		var sl := Label3D.new()
		sl.text = sub
		sl.pixel_size = 0.0032
		sl.width = 760.0
		sl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sl.modulate = Color(0.75, 0.78, 0.8)
		sl.position = Vector3(0, -(CARD_H * 0.5) - 0.14, 0.03)
		root.add_child(sl)
	var badge := Label3D.new()
	var gen := int(card.get("generation", -1))
	badge.text = String(card.get("kind", "")) + ("  · gen %d" % gen if gen >= 0 else "")
	badge.pixel_size = 0.0028
	badge.modulate = Color(0.55, 0.7, 0.9)
	badge.position = Vector3(0, (CARD_H * 0.5) + 0.22, 0.03)
	root.add_child(badge)
	# action hint (equivalence affordances)
	var hint := Label3D.new()
	var verbs := "X skip · B bookmark"
	for a in card.get("actions", []):
		var aid := String(a.get("id"))
		if aid == "evolve":
			verbs += " · E evolve"
		elif aid == "save":
			verbs += " · V save"
	hint.text = verbs
	hint.pixel_size = 0.0026
	hint.modulate = Color(0.6, 0.62, 0.58)
	hint.position = Vector3(0, -(CARD_H * 0.5) - 0.34, 0.03)
	root.add_child(hint)
	# bookmark star (hidden until toggled)
	var star := Label3D.new()
	star.name = "Star"
	star.text = "★"
	star.font_size = 64
	star.pixel_size = 0.006
	star.modulate = Color(1.0, 0.85, 0.3)
	star.position = Vector3(-(CARD_W * 0.5) + 0.1, (CARD_H * 0.5) + 0.22, 0.03)
	star.visible = _bookmarked.has(id)
	root.add_child(star)
	# pickable body
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(CARD_W + 0.2, CARD_H + 0.7, 0.25)
	shape.shape = box
	area.add_child(shape)
	area.set_meta("card_id", id)
	root.add_child(area)
	return root

# ---------------------------------------------------------------------------------------------------
# interactions — crosshair ray + keys, writing through the SAME channel as the web board
# ---------------------------------------------------------------------------------------------------

func _card_by_id(id: String) -> Dictionary:
	for c in cards:
		if String(c.get("id")) == id:
			return c
	return {}

func _act_on_aimed(verb: String) -> void:
	var id := String(_aimed_meta.get("card_id", ""))
	if id == "":
		return
	# candidate tiles on the live wall route to the MOCK evolver feedback, not the live Aperture
	if _aimed_meta.get("wall_kind", "") == "candidate":
		if verb in ["evolve", "save", "cull"]:
			wall.decide_candidate(id, verb)
			_set_status("candidate %s → %s (mock evolver)" % [id, verb])
		return
	var card := _card_by_id(id)
	if card.is_empty():
		return
	var action := verb
	var has := func(aid: String) -> bool:
		for a in card.get("actions", []):
			if String(a.get("id")) == aid:
				return true
		return false
	match verb:
		"skip":
			# the web ✕ posts "cull" on an evolver card, "skip" on content
			action = "cull" if String(card.get("kind")) == "evolver_candidate" else "skip"
		"bookmark":
			action = "unbookmark" if _bookmarked.has(id) else "bookmark"
		"evolve", "save":
			if not has.call(verb):
				return
	var res := _writer().act(card, action)
	if not bool(res.get("ok", false)):
		_set_status("write FAILED (%s %s): %s" % [action, id, String(res.get("error", "?"))])
		return
	_set_status("%s → %s  (via %s channel)" % [id, action, actions_channel])
	if action in ["bookmark", "unbookmark"]:
		if action == "bookmark":
			_bookmarked[id] = true
		else:
			_bookmarked.erase(id)
		var panel: Node3D = _panels.get(id)
		if panel != null:
			(panel.get_node("Star") as Label3D).visible = _bookmarked.has(id)
	else:
		# any decision (skip/cull/evolve/save) removes the card — same as the web board
		var panel: Node3D = _panels.get(id)
		if panel != null:
			var tw := create_tween()
			tw.tween_property(panel, "scale", Vector3(0.02, 0.02, 0.02), 0.25)
			tw.tween_callback(panel.queue_free)
			_panels.erase(id)

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
				_act_on_aimed("skip" if _aimed_meta.get("wall_kind", "") != "candidate" else "cull")
			KEY_B:
				_act_on_aimed("bookmark")
			KEY_E:
				_act_on_aimed("evolve")
			KEY_V:
				_act_on_aimed("save")
			KEY_R:
				_fetch_inbox()
			KEY_T:
				var rep := wall.evolver_tick()
				_set_status("evolver tick: gen %d · %d candidates · advanced=%s" %
					[int(rep.get("generation", 0)), int(rep.get("n_candidates", 0)), str(rep.get("advanced"))])
			KEY_BRACKETLEFT:
				_nudge_aimed_wall_tile(1.0 / 1.25)
			KEY_BRACKETRIGHT:
				_nudge_aimed_wall_tile(1.25)

## [ / ]: edit a texture gene of the aimed wall tile (tile 0 when none aimed) BY WRITING THE
## ARRANGEMENT FILE — the LiveHost hotload is what re-renders the wall (the full live loop).
func _nudge_aimed_wall_tile(factor: float) -> void:
	var idx := 0
	if _aimed_meta.get("wall_kind", "") == "wall":
		idx = int(_aimed_meta.get("wall_index", 0))
	var res := LiveWall.nudge_gene(wall.arrangement_path(), idx, factor)
	if bool(res.get("ok", false)):
		_set_status("live edit: tile%d %s %.2f → %.2f (rev %d) — hotloading…" %
			[idx, String(res.get("gene")), float(res.get("from")), float(res.get("to")), int(res.get("rev"))])
	else:
		_set_status("live edit failed: %s" % String(res.get("error", "?")))

# ---------------------------------------------------------------------------------------------------
# fly camera + crosshair aim
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
	_poll_sky_params()

func _update_aim() -> void:
	_aimed_meta = {}
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
		for k in ["card_id", "wall_kind", "wall_index"]:
			if col.has_meta(k):
				_aimed_meta[k] = col.get_meta(k)
	if _hud != null:
		var aim_txt := ""
		if _aimed_meta.has("card_id") and String(_aimed_meta.get("card_id")) != "":
			aim_txt = "\naimed: %s" % String(_aimed_meta.get("card_id"))
		elif _aimed_meta.get("wall_kind", "") == "wall":
			aim_txt = "\naimed: wall tile %d" % int(_aimed_meta.get("wall_index", 0))
		_hud.text = _controls_text() + aim_txt

# ---------------------------------------------------------------------------------------------------
# environment / HUD / params
# ---------------------------------------------------------------------------------------------------

func _load_params() -> Dictionary:
	var cfg := {}
	if FileAccess.file_exists(PARAMS_PATH):
		var parsed = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
		if typeof(parsed) == TYPE_DICTIONARY:
			cfg = parsed
	var inbox_cfg: Dictionary = cfg.get("inbox", {})
	for k in inbox_cfg.keys():
		source_cfg[k] = inbox_cfg[k]
	return cfg

## The standing sky+clouds module (always-on, independently iterable): built from the `sky` block
## of PARAMS_PATH, re-built live whenever that block changes on disk.
func _build_env() -> void:
	for c in get_children():
		if c is WorldEnvironment or c is DirectionalLight3D:
			c.queue_free()
	var cfg := _load_params()
	var sky_desc: Dictionary = cfg.get("sky", PainterlySky.default_descriptor())
	var built := PainterlySky.build(sky_desc)
	var env_node := WorldEnvironment.new()
	env_node.environment = built["environment"]
	add_child(env_node)
	add_child(built["sun"])
	_sky_hash = JSON.stringify(sky_desc).sha256_text()

func _poll_sky_params() -> void:
	if Engine.get_process_frames() % 45 != 0 or not FileAccess.file_exists(PARAMS_PATH):
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(PARAMS_PATH))
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var h := JSON.stringify(parsed.get("sky", PainterlySky.default_descriptor())).sha256_text()
	if h != _sky_hash:
		_build_env()

func _build_floor() -> void:
	var ground := MeshInstance3D.new()
	var disk := CylinderMesh.new()
	disk.top_radius = 26.0
	disk.bottom_radius = 26.0
	disk.height = 0.1
	ground.mesh = disk
	ground.position = Vector3(0, -0.05, 0)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.24, 0.26, 0.24)
	mat.roughness = 0.95
	ground.material_override = mat
	add_child(ground)

func _build_camera() -> void:
	_cam = Camera3D.new()
	_cam.position = Vector3(0, 1.8, 3.5)
	add_child(_cam)
	_cam.make_current()

func _controls_text() -> String:
	return ("GODOT APERTURE — click to capture mouse, ESC to release\n" +
		"WASD+mouse fly · X skip · B bookmark · E evolve · V save · R refresh\n" +
		"live wall: [ / ] edit gene (hotload) · T evolver tick (mock)")

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
	print("[aperture_3d] ", msg)

# ---------------------------------------------------------------------------------------------------
# --shot proof
# ---------------------------------------------------------------------------------------------------

func _shot_requested() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

func _take_shot() -> void:
	_did_shot = true
	if _headless:
		print("[aperture_3d] --shot needs a display (run without --headless). Exit 2.")
		get_tree().quit(2)
		return
	# give the fetch + panel build a moment, then frame the board and grab
	await get_tree().create_timer(2.5).timeout
	_yaw = deg_to_rad(-14.0)
	_pitch = -0.05
	_cam.position = Vector3(2.0, 2.6, 6.5)
	for _i in 8:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	img.save_png(SHOT_PATH)
	print("[aperture_3d] proof written: %s (%d cards)" % [SHOT_PATH, cards.size()])
	get_tree().quit(0)
