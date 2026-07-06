extends Node
## GRAPH-PANEL MOUNT — the diegetic in-world node-editor overlay (Dreams-arc Slice 1). It mounts the
## ALREADY-BUILT GraphPanel (editor/graph_panel.gd) on a same-window CanvasLayer overlay opened when you
## point a wiring tool at a world object and bind it. This file is a THIN MOUNT: it does not touch
## GraphPanel's internals — it only parents the widget, points its commit_path at the bound object's
## arrangement file, and loads that arrangement in. Every edit re-serialises + writes that file, which the
## running LiveHost hot-loads as a DIFF (runtime/graph_runtime.gd:load_arrangement) — no scene rebuild.
##
## Modelled on the proven same-window overlay in computer_terminal.gd (_build_overlay): a CanvasLayer at a
## high layer, a real full-rect root Control sized to the window (a CanvasLayer has NO rect, so anchors
## resolve against nothing unless a sized Control hosts them — the exact button-overlap bug that shipped
## the ✕ broken 3×), a dim backdrop, and an "ESC to close" ribbon. The GraphPanel fills the root Control.
##
## The #049 HOOK: open_panel(host, arrangement_path, force) mounts the EXACT SAME overlay tree headless
## when force=true (same shape as ComputerTerminal.open_board(host, force)), so a headless regression test
## drives the REAL mounted path — the panel actually in the running room — NOT a standalone GraphPanel
## (a standalone-panel test is a false pass, the #049 trap). Normal runtime callers pass force=false, so
## live behaviour is unchanged: the panel only mounts on a real display.
##
## No class_name (matching computer_terminal.gd, mistake #046): callers preload() this file by path.

const OVERLAY_NAME := "__graph_panel_overlay"
const GraphPanelScript := preload("res://editor/graph_panel.gd")


## Open (or reuse) the node panel for the arrangement at `arrangement_path`, mounted as a CanvasLayer
## overlay child of `host`. Returns the CanvasLayer, or null when headless-and-not-forced / the path is
## unusable. `force` bypasses the headless gate so the #049 test builds the identical real tree.
static func open_panel(host: Node, arrangement_path: String, force := false) -> CanvasLayer:
	if DisplayServer.get_name() == "headless" and not force:
		return null
	if host == null or not is_instance_valid(host):
		return null
	# reuse an already-open panel (idempotent) — re-point it at the requested arrangement.
	var existing := host.get_node_or_null(OVERLAY_NAME)
	if existing is CanvasLayer:
		existing.visible = true
		var gp0 := _panel_of(existing)
		if gp0 != null:
			_bind_arrangement(gp0, arrangement_path)
		return existing
	var panel: GraphPanel = GraphPanelScript.new()
	panel.name = "GraphPanel"
	return _build_overlay(host, panel, arrangement_path)


## Display-independent overlay builder — the ONE place the panel-overlay tree is assembled, so the live
## bind path and the headless #049 test build the same tree. Mirrors computer_terminal._build_overlay:
## a real full-rect root Control (sized to the window) hosts the backdrop + the GraphPanel + the ribbon.
static func _build_overlay(host: Node, panel: GraphPanel, arrangement_path: String) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = OVERLAY_NAME
	layer.layer = 64
	# The sizing anchor: a Control that DOES have a real rect (unlike its CanvasLayer parent). Every child
	# anchors against THIS, so full-rect anchors actually stretch (the fix for the CanvasLayer-parent bug).
	var root := Control.new()
	root.name = "OverlayRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE   # pass-through frame; children own their own hits
	layer.add_child(root)
	# Dim backdrop so the 3D room reads as "behind the editor". IGNORE so it never eats a panel click.
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.72)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bg)
	# The GraphPanel fills the root Control (real rect => the GraphEdit lays out its nodes at real size).
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(panel)
	# "ESC to close" ribbon (discoverable exit, IGNORE so it never covers a panel widget).
	var ribbon := Label.new()
	ribbon.text = "  NODE PANEL  —  drag to rewire  ·  ESC to close (edits are live)  "
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
	# Point the panel at the bound object's arrangement + load it AFTER it is in the tree (GraphPanel._ready
	# wires its connection signals there). Then size the root so anchors resolve against a real rect.
	_bind_arrangement(panel, arrangement_path)
	_size_root_to_viewport(root)
	var vp := root.get_viewport()
	if vp != null:
		# Keep the overlay root sized to the window as it resizes. Guard against a duplicate connect
		# (reopening the panel while a prior overlay is still queued-free would otherwise re-add this).
		var cb := _size_root_to_viewport.bind(root)
		if not vp.size_changed.is_connected(cb):
			vp.size_changed.connect(cb)
	return layer


## Point a GraphPanel at an arrangement file and load its current contents. commit_path is the SAME file
## the running LiveHost watches, so every edit the panel makes re-serialises to disk and hot-loads as a
## diff. If the file does not exist yet, the panel opens empty and its first commit creates it.
static func _bind_arrangement(panel: GraphPanel, arrangement_path: String) -> void:
	if panel == null or not is_instance_valid(panel):
		return
	panel.commit_path = arrangement_path
	if arrangement_path != "" and FileAccess.file_exists(arrangement_path):
		var text := FileAccess.get_file_as_string(arrangement_path)
		var data = JSON.parse_string(text)
		if typeof(data) == TYPE_DICTIONARY:
			panel.load_arrangement(data)


## Size the overlay root Control to the current WINDOW rect. A CanvasLayer child Control is not
## auto-laid-out, so its size must be set explicitly (without this the panel stays 64x64 — the same
## collapse that broke the board). Sizes to the root Window (what a CanvasLayer draws to), with fallbacks.
static func _size_root_to_viewport(root: Control) -> void:
	var vsize := Vector2.ZERO
	var tree := root.get_tree()
	if tree != null and tree.root != null:
		vsize = Vector2(tree.root.get_visible_rect().size)
	if vsize.x <= 0 or vsize.y <= 0:
		var vp := root.get_viewport()
		if vp != null:
			vsize = vp.get_visible_rect().size
	if vsize.x <= 0 or vsize.y <= 0:
		vsize = Vector2(1280, 720)
	root.position = Vector2.ZERO
	root.size = vsize


## Close the panel overlay (ESC). Returns true if one was present.
static func close_panel(host: Node) -> bool:
	if host == null or not is_instance_valid(host):
		return false
	var existing := host.get_node_or_null(OVERLAY_NAME)
	if existing != null:
		existing.queue_free()
		return true
	return false


static func panel_is_open(host: Node) -> bool:
	return host != null and is_instance_valid(host) and host.get_node_or_null(OVERLAY_NAME) != null


## The live GraphPanel inside an open overlay (or null). Lets a caller / test read the mounted widget.
static func panel_of(host: Node) -> GraphPanel:
	if not panel_is_open(host):
		return null
	return _panel_of(host.get_node_or_null(OVERLAY_NAME))


static func _panel_of(overlay: Node) -> GraphPanel:
	if overlay == null:
		return null
	var root := overlay.get_node_or_null("OverlayRoot")
	if root == null:
		return null
	for c in root.get_children():
		if c is GraphPanel:
			return c
	return null
