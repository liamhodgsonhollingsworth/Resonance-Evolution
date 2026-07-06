extends Node
## UI-ACTION RENDERER — the minimal in-world HOST for ui.*/dialogue.* receipts (Dreams-arc Slice 5).
##
## UiActions (runtime/ui_actions.gd) produces DECLARATIVE receipts (DATA): { op:"dialogue.show", speaker,
## text } / { op:"ui.menu.open", title, items }. Those are PORTABLE — no widget baked in. THIS file is the
## Godot HOST that renders one: a small same-window CanvasLayer overlay showing a plain dialogue box or a
## plain menu. A website / phone host renders the SAME receipt with its own widgets; the arrangement is
## unchanged. So this renderer is additive — mounting it changes nothing about the room until a receipt
## with a ui.*/dialogue.* op flows through, exactly like the GraphPanel mount is additive.
##
## MINIMAL-UI directive (Liam #042): plain, small, legible, clearly a demo. No styling beyond a dim panel,
## a couple of Labels, and Buttons for menu items / dismiss. No theming, no animation, no chrome.
##
## Modelled on graph_panel_mount.gd's static-mount idiom: a CanvasLayer at a high layer hosting a real
## full-rect root Control (a CanvasLayer has NO rect, so a sized Control must host the anchors — the exact
## bug that broke the board ✕ three times). Callers preload() this by path (no class_name, mistake #046).
##
## THE #049 HOOK: mount(host, force) builds the identical overlay tree headless when force=true, and
## render_receipt() is a pure DATA path (it mutates the mounted controls' text/visibility from the receipt
## dict). So the headless real-tree test drives the EXACT same renderer the running room drives — not a
## standalone widget (a standalone-widget test is the #049 false pass).

const OVERLAY_NAME := "__ui_action_overlay"

## Emitted whenever a menu item is clicked, with the item's index + label. A consumer (a later slice that
## wires the click back into an arrangement's input frame) connects this; the demo just closes the menu.
## No-op for headless tests that don't connect it.
signal menu_item_selected(index: int, label: String)


## Mount (or reuse) the UI-action overlay as a CanvasLayer child of `host`. Returns the CanvasLayer, or
## null when headless-and-not-forced. `force` bypasses the headless gate so the #049 test builds the same
## real tree. Idempotent: a second call returns the existing overlay. Starts fully hidden (additive — the
## room looks identical until a receipt is rendered).
static func mount(host: Node, force := false) -> CanvasLayer:
	if DisplayServer.get_name() == "headless" and not force:
		return null
	if host == null or not is_instance_valid(host):
		return null
	var existing := host.get_node_or_null(OVERLAY_NAME)
	if existing is CanvasLayer:
		return existing
	return _build_overlay(host)


## Build the overlay tree: a CanvasLayer -> a sized root Control -> a dialogue Panel + a menu Panel (both
## hidden). ONE place the tree is assembled so the live mount and the #049 test build the same thing.
static func _build_overlay(host: Node) -> CanvasLayer:
	var layer := CanvasLayer.new()
	layer.name = OVERLAY_NAME
	layer.layer = 48   # below the GraphPanel overlay (64), above the room HUD
	var renderer := load("res://aperture/ui_action_renderer.gd").new()
	renderer.name = "UiActionRenderer"
	layer.add_child(renderer)

	# The sizing anchor: a Control with a real rect (its CanvasLayer parent has none). IGNORE so an empty
	# UI never eats the player's clicks — only the concrete Buttons/panels below capture input.
	var root := Control.new()
	root.name = "OverlayRoot"
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(root)

	# --- dialogue box (bottom-centre, hidden until dialogue.show) --------------------------------------
	var dlg := Panel.new()
	dlg.name = "Dialogue"
	dlg.visible = false
	dlg.mouse_filter = Control.MOUSE_FILTER_STOP
	dlg.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	dlg.custom_minimum_size = Vector2(560, 120)
	dlg.position = Vector2(-280, -170)   # offset from the bottom-centre anchor
	dlg.size = Vector2(560, 120)
	var dv := VBoxContainer.new()
	dv.name = "V"
	dv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dv.add_theme_constant_override("separation", 6)
	dv.offset_left = 12; dv.offset_top = 10; dv.offset_right = -12; dv.offset_bottom = -10
	dlg.add_child(dv)
	var speaker := Label.new()
	speaker.name = "Speaker"
	speaker.add_theme_font_size_override("font_size", 15)
	speaker.add_theme_color_override("font_color", Color(0.7, 0.85, 1.0))
	dv.add_child(speaker)
	var body := Label.new()
	body.name = "Text"
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.add_theme_font_size_override("font_size", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dv.add_child(body)
	var dismiss := Button.new()
	dismiss.name = "Dismiss"
	dismiss.text = "Dismiss (E)"
	dismiss.pressed.connect(renderer._on_dismiss_pressed)
	dv.add_child(dismiss)
	root.add_child(dlg)

	# --- menu (centre, hidden until ui.menu.open) -----------------------------------------------------
	var menu := Panel.new()
	menu.name = "Menu"
	menu.visible = false
	menu.mouse_filter = Control.MOUSE_FILTER_STOP
	menu.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	menu.custom_minimum_size = Vector2(320, 220)
	menu.position = Vector2(-160, -110)
	menu.size = Vector2(320, 220)
	var mv := VBoxContainer.new()
	mv.name = "V"
	mv.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mv.add_theme_constant_override("separation", 6)
	mv.offset_left = 12; mv.offset_top = 10; mv.offset_right = -12; mv.offset_bottom = -10
	menu.add_child(mv)
	var title := Label.new()
	title.name = "Title"
	title.add_theme_font_size_override("font_size", 15)
	title.add_theme_color_override("font_color", Color(0.85, 0.95, 0.8))
	mv.add_child(title)
	var items := VBoxContainer.new()
	items.name = "Items"
	items.add_theme_constant_override("separation", 4)
	mv.add_child(items)
	root.add_child(menu)

	host.add_child(layer)
	_size_root_to_viewport(root)
	var vp := root.get_viewport()
	if vp != null:
		# Keep the root sized to the window. Guard a duplicate connect on reopen.
		var sizer := _size_root_to_viewport.bind(root)
		if not vp.size_changed.is_connected(sizer):
			vp.size_changed.connect(sizer)
	return layer


## Render ONE receipt onto the mounted overlay (the DATA path — pure, headless-drivable). Reads the
## receipt's `op` and mutates the matching controls: dialogue.show sets the speaker/text + shows the box;
## ui.menu.open sets the title + rebuilds the item buttons + shows the menu; the .hide/.close ops hide
## them. An UNRELATED op (or no overlay) is ignored — the renderer only reacts to its own family, so a
## log / device.set_led receipt flows past it untouched. Returns true if it acted on the receipt.
static func render_receipt(host: Node, receipt: Dictionary) -> bool:
	if host == null or not is_instance_valid(host) or receipt == null:
		return false
	var overlay := host.get_node_or_null(OVERLAY_NAME)
	if overlay == null:
		return false
	var root := overlay.get_node_or_null("OverlayRoot")
	if root == null:
		return false
	var renderer := overlay.get_node_or_null("UiActionRenderer")
	match str(receipt.get("op", "")):
		"dialogue.show":
			var dlg := root.get_node_or_null("Dialogue")
			if dlg == null:
				return false
			(dlg.get_node("V/Speaker") as Label).text = str(receipt.get("speaker", ""))
			(dlg.get_node("V/Text") as Label).text = str(receipt.get("text", ""))
			dlg.visible = true
			return true
		"dialogue.hide":
			var dlg := root.get_node_or_null("Dialogue")
			if dlg != null:
				dlg.visible = false
			return true
		"ui.menu.open":
			var menu := root.get_node_or_null("Menu")
			if menu == null:
				return false
			(menu.get_node("V/Title") as Label).text = str(receipt.get("title", ""))
			var items_box := menu.get_node("V/Items") as VBoxContainer
			for c in items_box.get_children():
				c.queue_free()
			var idx := 0
			for label in _as_array(receipt.get("items", [])):
				var b := Button.new()
				b.text = str(label)
				if renderer != null:
					b.pressed.connect(renderer._on_menu_item_pressed.bind(idx, str(label)))
				items_box.add_child(b)
				idx += 1
			menu.visible = true
			return true
		"ui.menu.close":
			var menu := root.get_node_or_null("Menu")
			if menu != null:
				menu.visible = false
			return true
	return false


## Is the dialogue box currently shown? (Read helper for the #049 test + a caller.)
static func dialogue_visible(host: Node) -> bool:
	var dlg := _find(host, "Dialogue")
	return dlg != null and dlg.visible


## The currently-shown dialogue text (or "" when hidden / unmounted). Lets the test assert what the
## renderer RECEIVED — proving the receipt reached the mounted UI, not just fired in the runtime.
static func dialogue_text(host: Node) -> String:
	var dlg := _find(host, "Dialogue")
	if dlg == null or not dlg.visible:
		return ""
	return (dlg.get_node("V/Text") as Label).text


## Is the menu currently shown?
static func menu_visible(host: Node) -> bool:
	var menu := _find(host, "Menu")
	return menu != null and menu.visible


## The current menu title (or "" when hidden). Test/caller read helper.
static func menu_title(host: Node) -> String:
	var menu := _find(host, "Menu")
	if menu == null or not menu.visible:
		return ""
	return (menu.get_node("V/Title") as Label).text


## The current menu item labels (empty when hidden). Test/caller read helper.
static func menu_items(host: Node) -> Array:
	var menu := _find(host, "Menu")
	if menu == null or not menu.visible:
		return []
	var out: Array = []
	for c in (menu.get_node("V/Items") as VBoxContainer).get_children():
		if c is Button:
			out.append(c.text)
	return out


static func is_mounted(host: Node) -> bool:
	return host != null and is_instance_valid(host) and host.get_node_or_null(OVERLAY_NAME) != null


# --- instance handlers (the mounted renderer node owns the signals) --------------------------------

## Dismiss the dialogue (button / E key path). Hides the box and, if a later slice wired it, could feed
## a "dialogue dismissed" input frame back. For the demo it just hides.
func _on_dismiss_pressed() -> void:
	var host := _host_of(self)
	if host != null:
		render_receipt(host, { "op": "dialogue.hide" })


## A menu item was clicked: emit the selection (a consumer wires it back into an arrangement) and close
## the menu. The demo just closes it — the point is the click reaches the renderer as data.
func _on_menu_item_pressed(index: int, label: String) -> void:
	menu_item_selected.emit(index, label)
	var host := _host_of(self)
	if host != null:
		render_receipt(host, { "op": "ui.menu.close" })


# --- helpers ---------------------------------------------------------------------------------------

## The overlay's host (the node the CanvasLayer was add_child'd to) — the CanvasLayer's parent.
static func _host_of(renderer: Node) -> Node:
	var layer := renderer.get_parent()
	if layer == null:
		return null
	return layer.get_parent()


static func _find(host: Node, name: String) -> Control:
	if host == null or not is_instance_valid(host):
		return null
	var overlay := host.get_node_or_null(OVERLAY_NAME)
	if overlay == null:
		return null
	var root := overlay.get_node_or_null("OverlayRoot")
	if root == null:
		return null
	return root.get_node_or_null(name) as Control


## Coerce a Variant into an Array (a receipt's items should already be one; a scalar wraps, null -> []).
static func _as_array(v) -> Array:
	if typeof(v) == TYPE_ARRAY:
		return v
	if v == null:
		return []
	return [v]


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
