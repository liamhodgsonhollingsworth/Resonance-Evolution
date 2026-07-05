extends Node3D
## 3D COMPUTER / TERMINAL — the in-room object that opens the 2D aperture board (Liam spec
## 2026-07-05 item 4: "a 3D computer asset that I can interact with by right clicking when holding
## nothing and opening it opens the 2D page (which I leave using escape)"). This REPLACES the
## in-world 2D menu pages / art links the old 3D aperture had — the room has NO menu tiles, just
## this one physical computer you interact with to reach the board.
##
## The board itself is the EXISTING aperture_board_2d.tscn (peer-owned) INSTANCED into a top
## CanvasLayer overlay — same window, same process (spec item 5: "the transition between the 2D
## page and the 3D scenes should ... happen in the same window"). This scene does NOT modify the
## board; it embeds it. ESC unmounts the overlay and returns to the room.
##
## The room drives interaction: it aims a ray, and on RIGHT-CLICK WITH AN EMPTY HAND calls
## request_open() when the crosshair is on this terminal. The terminal is a plain visual + an
## `interactable` meta tag the room's ray reads — no per-object input handling, so it composes with
## the room's single input pump.
##
## No class_name (mistake #046): the room preload()s this file by path.

signal open_requested()

const BOARD_SCENE := "res://aperture/aperture_board_2d.tscn"

var screen_glow := Color(0.45, 0.72, 0.95)


func _ready() -> void:
	_build()


## Called by the room when the crosshair is on this terminal and the player right-clicks empty-handed.
func request_open() -> void:
	open_requested.emit()


## Build (or reuse) the 2D-board overlay as a CanvasLayer child of `host`. Returns the CanvasLayer,
## or null when headless / the board scene is missing. The board is the UNMODIFIED peer scene; ESC
## handling lives in the room (it calls close_board). Static so the room owns the overlay lifetime.
static func open_board(host: Node) -> CanvasLayer:
	if DisplayServer.get_name() == "headless":
		return null
	if not ResourceLoader.exists(BOARD_SCENE):
		push_warning("computer_terminal: board scene missing at %s" % BOARD_SCENE)
		return null
	# reuse an already-open overlay (idempotent)
	var existing := host.get_node_or_null("__board_overlay")
	if existing is CanvasLayer:
		existing.visible = true
		return existing
	var ps: PackedScene = load(BOARD_SCENE)
	if ps == null:
		return null
	var layer := CanvasLayer.new()
	layer.name = "__board_overlay"
	layer.layer = 64
	# A dim backdrop so the 3D room reads as "behind the screen".
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.82)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(bg)
	var board := ps.instantiate()
	if board is Control:
		(board as Control).set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(board)
	# A thin "ESC to leave" ribbon so the exit is discoverable (spec: "which I leave using escape").
	var ribbon := Label.new()
	ribbon.text = "  2D APERTURE  —  ESC to return to the room  "
	ribbon.add_theme_font_size_override("font_size", 13)
	ribbon.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0.05, 0.07, 0.11, 0.9)
	rs.set_corner_radius_all(6)
	rs.content_margin_left = 8; rs.content_margin_right = 8
	rs.content_margin_top = 4; rs.content_margin_bottom = 4
	ribbon.add_theme_stylebox_override("normal", rs)
	ribbon.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 8)
	layer.add_child(ribbon)
	host.add_child(layer)
	return layer


## Remove the board overlay from `host` (ESC in the room). Returns true if one was present.
static func close_board(host: Node) -> bool:
	var existing := host.get_node_or_null("__board_overlay")
	if existing != null:
		existing.queue_free()
		return true
	return false


static func board_is_open(host: Node) -> bool:
	return host.get_node_or_null("__board_overlay") != null


func _build() -> void:
	# Desk.
	var desk := MeshInstance3D.new()
	var dm := BoxMesh.new()
	dm.size = Vector3(1.6, 0.1, 0.8)
	desk.mesh = dm
	desk.position = Vector3(0.0, 0.75, 0.0)
	var desk_mat := StandardMaterial3D.new()
	desk_mat.albedo_color = Color(0.28, 0.22, 0.18)
	desk_mat.roughness = 0.8
	desk.material_override = desk_mat
	add_child(desk)
	# Two desk legs.
	var leg_mat := StandardMaterial3D.new()
	leg_mat.albedo_color = Color(0.14, 0.14, 0.16)
	for x in [-0.7, 0.7]:
		var leg := MeshInstance3D.new()
		var lm := BoxMesh.new()
		lm.size = Vector3(0.1, 0.75, 0.1)
		leg.mesh = lm
		leg.position = Vector3(x, 0.375, 0.0)
		leg.material_override = leg_mat
		add_child(leg)
	# Monitor stand.
	var stand := MeshInstance3D.new()
	var sm := CylinderMesh.new()
	sm.top_radius = 0.06; sm.bottom_radius = 0.1; sm.height = 0.35
	stand.mesh = sm
	stand.position = Vector3(0.0, 0.97, 0.0)
	stand.material_override = leg_mat
	add_child(stand)
	# Monitor bezel.
	var bezel := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(1.15, 0.72, 0.06)
	bezel.mesh = bm
	bezel.position = Vector3(0.0, 1.5, -0.02)
	var bezel_mat := StandardMaterial3D.new()
	bezel_mat.albedo_color = Color(0.08, 0.08, 0.1)
	bezel.material_override = bezel_mat
	add_child(bezel)
	# The glowing screen — the "interactable" surface (a lit quad).
	var screen := MeshInstance3D.new()
	screen.name = "Screen"
	var qm := QuadMesh.new()
	qm.size = Vector2(1.02, 0.6)
	screen.mesh = qm
	screen.position = Vector3(0.0, 1.5, 0.015)
	var scr_mat := StandardMaterial3D.new()
	scr_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	scr_mat.albedo_color = screen_glow
	scr_mat.emission_enabled = true
	scr_mat.emission = screen_glow
	scr_mat.emission_energy_multiplier = 0.6
	screen.material_override = scr_mat
	add_child(screen)
	# On-screen hint text.
	var scr_label := Label3D.new()
	scr_label.text = "APERTURE\n▶ right-click (empty hand)"
	scr_label.font_size = 26
	scr_label.pixel_size = 0.0026
	scr_label.modulate = Color(0.03, 0.05, 0.08)
	scr_label.position = Vector3(0.0, 1.5, 0.02)
	add_child(scr_label)
	# Screen glow light.
	var glow := OmniLight3D.new()
	glow.position = Vector3(0.0, 1.5, 0.5)
	glow.omni_range = 3.0
	glow.light_energy = 1.1
	glow.light_color = screen_glow
	add_child(glow)
	# The pickable body: an Area3D tagged so the room's crosshair ray identifies THIS as the terminal.
	var area := Area3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(1.6, 2.0, 1.0)
	shape.shape = box
	shape.position = Vector3(0.0, 1.0, 0.0)
	area.add_child(shape)
	area.set_meta("interactable", "computer")
	add_child(area)
