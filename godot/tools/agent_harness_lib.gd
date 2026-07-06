extends RefCounted
## AGENT HARNESS LIBRARY — the reusable primitives behind agent_harness.gd. Kept as pure static
## functions so the same logic is callable from the harness driver AND from headless test suites
## (headless_agent_harness_test.gd exercises these directly). preload() by path, no class_name (#046).

# ---------------------------------------------------------------------------------------------------
# ui_dump — enumerate every interactive Control with the geometry an agent needs to VERIFY a hitbox
# ---------------------------------------------------------------------------------------------------

## Every Control that can receive a click (mouse_filter != IGNORE) OR is a Button/LineEdit/TextEdit,
## with its global rect, filter, visibility, and — critically — the node TOPMOST at its own center.
## A control whose topmost-at-center is NOT itself (or its child) is being COVERED: its clicks are
## eaten. That is the exact "X button renders but does not click" failure this dump surfaces.
static func ui_dump(root: Node) -> Dictionary:
	if root == null:
		return { "ok": false, "verb": "ui_dump", "error": "no scene" }
	var controls: Array = []
	_collect_interactive(root, root, controls)
	# For each, compute what is topmost at its center (only meaningful for visible, sized controls).
	for entry in controls:
		var node: Control = entry["_node"]
		entry.erase("_node")
		if bool(entry["visible"]) and entry["global_rect"]["w"] > 0 and entry["global_rect"]["h"] > 0:
			var center := Vector2(entry["global_rect"]["x"] + entry["global_rect"]["w"] / 2.0,
				entry["global_rect"]["y"] + entry["global_rect"]["h"] / 2.0)
			var top := topmost_control_at(root, center)
			entry["topmost_at_center"] = (String(root.get_path_to(top)) if top != null else null)
			entry["covered"] = top != null and top != node and not node.is_ancestor_of(top) and not top.is_ancestor_of(node)
		else:
			entry["topmost_at_center"] = null
			entry["covered"] = false
	return { "ok": true, "verb": "ui_dump", "count": controls.size(), "controls": controls }

static func _collect_interactive(root: Node, node: Node, out: Array) -> void:
	if node is Control:
		var c := node as Control
		var interactive := c.mouse_filter != Control.MOUSE_FILTER_IGNORE \
			or c is Button or c is LineEdit or c is TextEdit or c is BaseButton
		if interactive:
			var r := c.get_global_rect()
			out.append({
				"_node": c,
				"node_path": String(root.get_path_to(c)),
				"class": c.get_class(),
				"name": c.name,
				"text": (c.get("text") if ("text" in c) else ""),
				"global_rect": { "x": r.position.x, "y": r.position.y, "w": r.size.x, "h": r.size.y },
				"mouse_filter": _filter_name(c.mouse_filter),
				"visible": c.is_visible_in_tree(),
				"modulate_a": c.modulate.a,
				"z": c.get_index(),
			})
	for ch in node.get_children():
		_collect_interactive(root, ch, out)

static func _filter_name(f: int) -> String:
	match f:
		Control.MOUSE_FILTER_STOP: return "stop"
		Control.MOUSE_FILTER_PASS: return "pass"
		Control.MOUSE_FILTER_IGNORE: return "ignore"
	return str(f)

## Compact list of interactive controls (path + text) — attached to a "target not found" error so the
## agent immediately sees what selectors ARE available.
static func interactive_summary(root: Node) -> Array:
	var dump := ui_dump(root)
	var out: Array = []
	for c in dump.get("controls", []):
		out.append({ "node_path": c["node_path"], "class": c["class"], "text": c["text"], "visible": c["visible"] })
	return out

# ---------------------------------------------------------------------------------------------------
# hit-testing — what control is topmost at a global coord (the covering-node check)
# ---------------------------------------------------------------------------------------------------

## The visible, non-IGNORE control that a click at `pos` would actually hit — the deepest/topmost
## control whose global rect contains the point. Mirrors Godot's own front-to-back hit walk closely
## enough to catch occlusion (a STOP panel drawn above a button steals the point).
static func topmost_control_at(root: Node, pos: Vector2) -> Control:
	var hits: Array = []
	_gather_hits(root, pos, hits)
	if hits.is_empty():
		return null
	# The last one in tree order that is drawn on top wins; siblings later in the tree draw above
	# earlier ones, and children draw above parents. Tree pre-order append means the LAST appended
	# non-IGNORE hit is the front-most — matching Godot's input walk (reverse child order, deepest first).
	return hits[hits.size() - 1]

static func _gather_hits(node: Node, pos: Vector2, out: Array) -> void:
	if node is Control:
		var c := node as Control
		if c.is_visible_in_tree() and c.mouse_filter != Control.MOUSE_FILTER_IGNORE \
				and c.get_global_rect().has_point(pos):
			out.append(c)
	for ch in node.get_children():
		_gather_hits(ch, pos, out)

# ---------------------------------------------------------------------------------------------------
# selectors — resolve a `target` dict to a live node
# ---------------------------------------------------------------------------------------------------

static func select_node(root: Node, sel: Dictionary) -> Node:
	if root == null or sel.is_empty():
		return null
	if sel.has("path"):
		var n := root.get_node_or_null(NodePath(String(sel["path"])))
		return n
	if sel.has("topmost_at"):
		var a: Array = sel["topmost_at"]
		return topmost_control_at(root, Vector2(float(a[0]), float(a[1])))
	if sel.has("text"):
		return _find_by_text(root, String(sel["text"]))
	if sel.has("name"):
		return root.find_child(String(sel["name"]), true, false)
	return null

static func _find_by_text(node: Node, text: String) -> Node:
	if node is Control and ("text" in node) and String(node.get("text")) == text and (node as Control).is_visible_in_tree():
		return node
	for c in node.get_children():
		var hit := _find_by_text(c, text)
		if hit != null:
			return hit
	# second pass: allow hidden matches (hover-gated buttons are hidden until revealed)
	if node is Control and ("text" in node) and String(node.get("text")) == text:
		return node
	return null

## Walk up from a control to the owning "tile" PanelContainer (whose name starts with "Tile_"),
## so a hover-gated button can auto-reveal by hovering its tile.
static func owning_tile(node: Node) -> Control:
	var n := node
	while n != null:
		if n is Control and String((n as Control).name).begins_with("Tile_"):
			return n
		n = n.get_parent()
	return null

# ---------------------------------------------------------------------------------------------------
# input synthesis + hover (headless has no OS cursor — establish hover explicitly)
# ---------------------------------------------------------------------------------------------------

static func vp_button(vp: Viewport, pos: Vector2, pressed: bool) -> void:
	var ev := InputEventMouseButton.new()
	ev.button_index = MOUSE_BUTTON_LEFT
	ev.pressed = pressed
	ev.position = pos
	ev.global_position = pos
	vp.push_input(ev)

static func vp_click(vp: Viewport, pos: Vector2) -> void:
	vp_button(vp, pos, true)
	vp_button(vp, pos, false)

## Establish hover in headless. BaseButton fires `pressed` on release only if its internal hover flag
## is set (NOTIFICATION_MOUSE_ENTER in Godot 4.6); the `mouse_entered` SIGNAL (what the tile reveal
## handler listens to) is emitted by live cursor tracking, so emit it explicitly too.
static func hover(ctrl: Control) -> void:
	ctrl.notification(Control.NOTIFICATION_MOUSE_ENTER)
	if "NOTIFICATION_MOUSE_ENTER_SELF" in ClassDB.class_get_integer_constant_list("Control"):
		ctrl.notification(ClassDB.class_get_integer_constant("Control", "NOTIFICATION_MOUSE_ENTER_SELF"))
	ctrl.emit_signal("mouse_entered")

# ---------------------------------------------------------------------------------------------------
# effect capture / diff — ground ui_click's PASS/FAIL in a durable side effect, not just a signal
# ---------------------------------------------------------------------------------------------------

## Snapshot the observable effects a click could produce: feedback/bookmark/notes row counts (from the
## board's configured substrate) + the board's displayed-card count. The diff tells ui_click whether
## an effect actually fired.
static func capture_effect_state(root: Node, config: Dictionary) -> Dictionary:
	var state := {}
	# board-shaped scene: read its configured substrate row counts + displayed set size
	var cfg: Dictionary = config
	if "config" in root and typeof(root.get("config")) == TYPE_DICTIONARY:
		cfg = root.get("config")
	state["feedback_rows"] = _count_rows(String(cfg.get("feedback_path", "")))
	state["bookmark_rows"] = _count_rows(String(cfg.get("bookmarks_path", "")))
	state["note_rows"] = _count_rows(String(cfg.get("notes_path", "")))
	if "_displayed" in root and typeof(root.get("_displayed")) == TYPE_DICTIONARY:
		state["displayed_count"] = (root.get("_displayed") as Dictionary).size()
	return state

static func diff_effect(before: Dictionary, after: Dictionary) -> Dictionary:
	var changed := false
	var deltas := {}
	for k in after.keys():
		var b = before.get(k, null)
		var a = after.get(k, null)
		if typeof(b) == TYPE_NIL:
			continue
		if a != b:
			changed = true
			deltas[k] = { "before": b, "after": a }
	return { "changed": changed, "deltas": deltas }

static func _count_rows(path: String) -> int:
	if path == "":
		return -1
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	if not FileAccess.file_exists(abs):
		return 0
	var n := 0
	for line in FileAccess.get_file_as_string(abs).split("\n"):
		if line.strip_edges() != "":
			n += 1
	return n

# ---------------------------------------------------------------------------------------------------
# read_state — dump key runtime state as JSON
# ---------------------------------------------------------------------------------------------------

static func read_state(root: Node) -> Dictionary:
	var state := { "ok": true, "verb": "read_state", "scene": (root.name if root != null else null) }
	if root == null:
		return state
	# camera / character (3D scenes expose _cam, _yaw, _pitch, _aimed_meta)
	var cam := _find_camera(root)
	if cam != null:
		state["camera_position"] = _v3(cam.global_position)
		state["camera_forward"] = _v3(-cam.global_transform.basis.z)
	for prop in ["_yaw", "_pitch"]:
		if prop in root:
			state[prop.trim_prefix("_")] = float(root.get(prop))
	if "_aimed_meta" in root:
		var am = root.get("_aimed_meta")
		state["aimed"] = am if typeof(am) == TYPE_DICTIONARY else null
	# mouse mode
	state["mouse_mode"] = _mouse_mode_name(Input.mouse_mode)
	# board-shaped scene: mode + displayed card ids
	if "_mode_in_use" in root:
		state["board_mode"] = String(root.get("_mode_in_use"))
	if "_displayed" in root and typeof(root.get("_displayed")) == TYPE_DICTIONARY:
		state["displayed_card_ids"] = (root.get("_displayed") as Dictionary).keys()
	return state

static func _find_camera(node: Node) -> Camera3D:
	if node is Camera3D:
		return node
	for c in node.get_children():
		var hit := _find_camera(c)
		if hit != null:
			return hit
	return null

static func _mouse_mode_name(m: int) -> String:
	match m:
		Input.MOUSE_MODE_VISIBLE: return "visible"
		Input.MOUSE_MODE_CAPTURED: return "captured"
		Input.MOUSE_MODE_HIDDEN: return "hidden"
		Input.MOUSE_MODE_CONFINED: return "confined"
	return str(m)

static func _v3(v: Vector3) -> Array:
	return [snappedf(v.x, 0.001), snappedf(v.y, 0.001), snappedf(v.z, 0.001)]

# ---------------------------------------------------------------------------------------------------
# character driving — move / look / interact against a 3D scene's exposed hooks
# ---------------------------------------------------------------------------------------------------

## Drive the first-person character. Uses the scene's own exposed methods/fields where present
## (_look_toward, _cam, _yaw/_pitch, _click_primary/_click_secondary/_right_click) and degrades
## gracefully (reports which hook was missing) rather than erroring — so the SAME verb works across
## scenes that expose slightly different hooks.
static func char_action(tree: SceneTree, root: Node, action: String, cmd: Dictionary) -> Dictionary:
	var cam := _find_camera(root)
	match action:
		"look":
			var target := _resolve_point(root, cmd)
			if target == null:
				return { "ok": false, "verb": "char_look", "error": "need at:[x,y,z] or node:<path>" }
			if root.has_method("_look_toward"):
				root.call("_look_toward", target)
			elif "_yaw" in root and "_pitch" in root and cam != null:
				var to: Vector3 = (target - cam.global_position).normalized()
				root.set("_yaw", atan2(-to.x, -to.z))
				root.set("_pitch", clampf(asin(to.y), -1.5, 1.5))
				if root.has_method("_apply_camera_rotation"):
					root.call("_apply_camera_rotation")
			else:
				return { "ok": false, "verb": "char_look", "error": "scene exposes no look hook" }
			await tree.process_frame
			var newcam := _find_camera(root)
			return { "ok": true, "verb": "char_look", "looked_at": _v3(target),
				"camera_forward": (_v3(-newcam.global_transform.basis.z) if newcam != null else null),
				"aimed": (root.get("_aimed_meta") if "_aimed_meta" in root else null) }
		"move":
			if cam == null:
				return { "ok": false, "verb": "char_move", "error": "no camera to move" }
			var dest := _resolve_point(root, cmd)
			if dest == null and cmd.has("forward"):
				var fwd := -cam.global_transform.basis.z
				fwd.y = 0.0
				dest = cam.global_position + fwd.normalized() * float(cmd["forward"])
			if dest == null:
				return { "ok": false, "verb": "char_move", "error": "need to:[x,y,z] or forward:<n>" }
			# Teleport-style move (the harness verifies reachability/state, not the walk animation):
			# set the camera position directly, preserving y unless a full point was given.
			cam.global_position = dest
			await tree.process_frame
			return { "ok": true, "verb": "char_move", "camera_position": _v3(cam.global_position) }
		"interact":
			var btn := String(cmd.get("button", "right"))
			var method := ""
			if btn == "right" and root.has_method("_right_click"):
				method = "_right_click"
			elif btn == "left" and root.has_method("_click_primary"):
				method = "_click_primary"
			elif btn == "right" and root.has_method("_click_secondary"):
				method = "_click_secondary"
			if method == "":
				return { "ok": false, "verb": "char_interact", "error": "scene exposes no interact hook (button=%s)" % btn }
			root.call(method)
			await tree.process_frame
			return { "ok": true, "verb": "char_interact", "button": btn, "method": method,
				"state_after": read_state(root) }
	return { "ok": false, "verb": "char_" + action, "error": "unknown char action" }

static func _resolve_point(root: Node, cmd: Dictionary):
	if cmd.has("at"):
		var a: Array = cmd["at"]
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if cmd.has("to"):
		var a: Array = cmd["to"]
		return Vector3(float(a[0]), float(a[1]), float(a[2]))
	if cmd.has("node"):
		var n := root.get_node_or_null(NodePath(String(cmd["node"])))
		if n is Node3D:
			return (n as Node3D).global_position
	return null

# ---------------------------------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------------------------------

static func list_scenes() -> Dictionary:
	var known := [
		{ "scene": "res://aperture/aperture_board_2d.tscn", "kind": "2d_ui", "note": "the 2D aperture board" },
		{ "scene": "res://aperture/aperture_3d.tscn", "kind": "3d_room", "note": "the 3D aperture room (computer opens the board)" },
		{ "scene": "res://examples/sandbox_creative.tscn", "kind": "3d_sandbox", "note": "creative sandbox (move/look/place)" },
	]
	var out: Array = []
	for k in known:
		k["exists"] = ResourceLoader.exists(String(k["scene"]))
		out.append(k)
	return { "ok": true, "verb": "list_scenes", "scenes": out }
