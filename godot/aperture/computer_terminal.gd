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
##
## `force` bypasses the headless gate so a HEADLESS REGRESSION TEST can build the EXACT SAME overlay
## tree the live path builds (the real bug lives in this tree, never in the standalone board — a
## standalone-board test is a false pass). Normal runtime callers pass force=false, so live behavior
## is unchanged: still null under headless, board only mounts on a real display.
static func open_board(host: Node, force := false) -> CanvasLayer:
	if DisplayServer.get_name() == "headless" and not force:
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
	var board := ps.instantiate()
	return _build_overlay(host, board)


## Display-independent overlay builder — the ONE place the overlay tree is assembled, so the live
## right-click path and the headless regression test build byte-for-byte the same tree. Takes an
## already-instantiated board Control (or any Node); returns the mounted CanvasLayer.
##
## ROOT CAUSE of the "can't press the X / placement is off" bug (Liam, 4th report, 2026-07-06):
## the board and backdrop were added DIRECTLY to the CanvasLayer with full-rect anchors. A
## CanvasLayer is NOT a Control and has NO rect, so anchors resolve against nothing — the board
## stayed at its default 64x64 instead of filling the viewport. At 64px wide the masonry collapsed
## to ONE ~39px column and the corner-anchored X/note/star buttons piled ON TOP OF EACH OTHER
## (right-anchored X and left-anchored star both landed at x~16-47, note pushed to negative x). So a
## click where the X is drawn actually hit the star sitting over it — the X "does nothing". This is
## why the standalone-board test always passed: there the board's parent IS a Control host that
## stretches it, so it never reproduced the CanvasLayer-parent sizing failure.
##
## FIX: put a real full-rect ROOT CONTROL under the CanvasLayer, size it explicitly to the current
## viewport (CanvasLayers do not push a size, so we set it) AND keep it synced on window resize.
## bg + board + ribbon are anchored INSIDE that root Control, whose rect is real — so full-rect
## anchors finally stretch the board to the whole screen, the masonry gets its 4 columns at real
## card width, and the buttons land in their correct, non-overlapping corners.
static func _build_overlay(host: Node, board: Node) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = "__board_overlay"
	layer.layer = 64
	# The sizing anchor: a Control that DOES have a real rect (unlike its CanvasLayer parent). We size
	# it to the viewport and re-sync on resize; every child anchors against THIS.
	var root := Control.new()
	root.name = "OverlayRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # a pass-through frame; children own their own hits
	layer.add_child(root)
	# A dim backdrop so the 3D room reads as "behind the screen". IGNORE, not the ColorRect default
	# STOP: the backdrop is purely cosmetic and must NEVER eat a click meant for the board on top of
	# it (a STOP full-rect sibling under the board is exactly the kind of click-eater that made the
	# X un-pressable). IGNORE keeps the backdrop click-transparent.
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.82)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	if board is Control:
		# Full-rect WITH offsets (set_anchors_AND_offsets_preset) inside the now-real-sized root, so the
		# board fills the whole viewport and the tile grid gets its real column width (no piled-up buttons).
		(board as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(board)
	# A thin "ESC to leave" ribbon so the exit is discoverable (spec: "which I leave using escape").
	# IGNORE so this top-left ribbon never sits over (and eat clicks for) a card button beneath it.
	var ribbon := Label.new()
	ribbon.text = "  2D APERTURE  —  ESC to return to the room  "
	ribbon.add_theme_font_size_override("font_size", 13)
	ribbon.add_theme_color_override("font_color", Color(0.85, 0.9, 0.95))
	ribbon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var rs := StyleBoxFlat.new()
	rs.bg_color = Color(0.05, 0.07, 0.11, 0.9)
	rs.set_corner_radius_all(6)
	rs.content_margin_left = 8; rs.content_margin_right = 8
	rs.content_margin_top = 4; rs.content_margin_bottom = 4
	ribbon.add_theme_stylebox_override("normal", rs)
	ribbon.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT, Control.PRESET_MODE_MINSIZE, 8)
	root.add_child(ribbon)
	host.add_child(layer)
	# Size the root NOW that it is in the tree (its viewport exists), so anchors resolve against a real
	# rect. Then keep it glued to the window on resize. Order matters: sizing before the tree add would
	# read a null viewport and leave the 64x64 default (the very bug this fixes).
	_size_root_to_viewport(root)
	# Keep the overlay glued to the window on resize. This overlay is freshly built on every open
	# (close_board frees it), so a plain connect never double-subscribes.
	var vp := root.get_viewport()
	if vp != null:
		vp.size_changed.connect(_size_root_to_viewport.bind(root))
	return layer


## Size the overlay root Control to the current WINDOW rect. A CanvasLayer child Control is not
## auto-laid-out (no Control/Container parent), so its size must be set explicitly; without this the
## board stays 64x64 and the masonry collapses (the button-overlap bug). A CanvasLayer draws to the
## root Window, so we size to the root Window's visible rect — NOT root.get_viewport(), which for a
## CanvasLayer-parented Control can report a stale/tiny rect (observed 64x64 in headless). Falls back
## to a sane default if the tree/window is not yet available; the resize signal then corrects it.
static func _size_root_to_viewport(root: Control) -> void:
	var vsize := Vector2.ZERO
	var tree := root.get_tree()
	if tree != null and tree.root != null:
		vsize = Vector2(tree.root.get_visible_rect().size)   # the root Window (what a CanvasLayer draws to)
	if vsize.x <= 0 or vsize.y <= 0:
		var vp := root.get_viewport()
		if vp != null:
			vsize = vp.get_visible_rect().size
	if vsize.x <= 0 or vsize.y <= 0:
		vsize = Vector2(1280, 720)
	root.position = Vector2.ZERO
	root.size = vsize


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
