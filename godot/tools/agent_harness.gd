extends SceneTree
## AGENT HARNESS — the text/JSON-driven verification gate for Godot UI + game mechanics.
##
## Liam 2026-07-05 (item 4): "testing every feature by building text equivalent tools that you can
## interact with on your end that verify that functionality is working end to end and allow you to
## manipulate increasingly complex game mechanics by using composites of tools (for example, tools
## that allow you to manipulate a character, look at a particular thing, interact, take screenshots,
## etc)". This is the KEYSTONE that fixes the recurring "renders ≠ works" failure ([[feedback-verify-
## ui-before-handing-over]]): a UI is not done until a programmatic click at an element's EXACT visual
## coord fires its handler — this harness proves that with no human and no GUI.
##
## HOW TO CALL (an agent runs this headless and reads JSON back on stdout):
##   godot --headless --path godot -s res://tools/agent_harness.gd -- \
##       --scene res://aperture/aperture_board_2d.tscn \
##       --cmds '<json>'                     # inline JSON: a single command object OR an array of them
##   ... or --cmds-file <path>               # read the JSON from a file instead (large scripts)
##   ... or --cmd ui_dump --arg key=value    # a single verb with --arg k=v pairs (simple one-shots)
## Every run prints exactly one line of JSON to stdout prefixed with "HARNESS_JSON:" (so an agent can
## grep that one line out of Godot's own log spam), and a pretty copy without the prefix for humans.
## The thin python wrapper `agent_harness.py` does the grep + parse for you (see its README).
##
## VERBS (all text-first, composable — the result of one is the input to the next):
##   ui_dump      {scene?}                     enumerate EVERY interactive Control: node_path, global_rect
##                                             {x,y,w,h}, mouse_filter, visible, modulate, z, and the node
##                                             TOPMOST at the control's center (catches a covering node
##                                             that eats clicks — the exact X-button failure class).
##   ui_click     {target}                     synthesize a real InputEventMouseButton (down+up) at the
##                                             target control's center global coord; report which node
##                                             ACTUALLY received it + assert the intended effect fired
##                                             (signal / feedback row / state change). PASS|FAIL.
##   ui_hover     {target}                     establish hover on a control (reveals hover-gated buttons).
##   screenshot   {out?}                       run a few frames, save a PNG proof, report its path.
##   char_move    {to:[x,y,z] | forward:n}     drive the first-person character toward a world position.
##   char_look    {at:[x,y,z] | node:path}     aim the character's camera at a point / node.
##   char_interact {button?:left|right}        trigger the character's interact (place/pick/open).
##   read_state   {}                           dump key runtime state as JSON (camera, aimed node,
##                                             inventory, notes, board mode/card ids, mouse mode).
##   wait         {frames?:int}                advance N frames (settle animations / deferred loads).
##   list_scenes                               list known drivable scenes (discovery helper).
##
## `target` selectors (ui_click / ui_hover / ui_look node): one of
##   {"path": "<node path under the scene root>"}      exact node
##   {"text": "✕"}                                     first Button/Label whose text == this
##   {"name": "FeedbackBox"}                           first node whose name == this
##   {"topmost_at": [x, y]}                            whatever control is topmost at that global coord
## A selector may add "reveal_hover": true to auto-hover its owning tile first (for hover-gated buttons).
##
## DESIGN NOTES
##   • preload() by PATH, never class_name (mistake #046) — runs on a fresh checkout with no .godot cache.
##   • Zero live-substrate pollution: pass --config to point the board at a temp dir; the harness never
##     writes to the live aperture files unless you explicitly point it there.
##   • Effect assertions are data-driven where possible (a skip writes a feedback row; a decision writes
##     a decision row) so ui_click's PASS/FAIL is grounded in a durable side effect, not just a signal.

const HarnessLib := preload("res://tools/agent_harness_lib.gd")

var _root_scene: Node = null
var _scene_path := ""
var _config: Dictionary = {}
var _out_shot := "res://live/harness_shot.png"
var _view_w := 1600.0
var _view_h := 1000.0

func _initialize() -> void:
	_run()

func _run() -> void:
	var args := _parse_args(OS.get_cmdline_user_args())
	var cmds := _resolve_cmds(args)
	if cmds.is_empty():
		_emit({ "ok": false, "error": "no commands (pass --cmds / --cmds-file / --cmd)" })
		quit(1)
		return
	_scene_path = String(args.get("scene", ""))
	if args.has("config"):
		var parsed = JSON.parse_string(String(args["config"]))
		if typeof(parsed) == TYPE_DICTIONARY:
			_config = parsed
	if args.has("out"):
		_out_shot = String(args["out"])
	if args.has("view"):
		var wh := String(args["view"]).split("x")
		if wh.size() == 2:
			_view_w = float(wh[0]); _view_h = float(wh[1])

	# Load the scene once; every command runs against the same live tree (composable state).
	if _scene_path != "":
		var loaded := await _load_scene(_scene_path)
		if not loaded.get("ok", false):
			_emit({ "ok": false, "error": loaded.get("error", "scene load failed"), "scene": _scene_path })
			quit(1)
			return

	var results: Array = []
	var all_ok := true
	for c in cmds:
		var res := await _dispatch(c)
		results.append(res)
		if not bool(res.get("ok", true)):
			all_ok = false
	_emit({ "ok": all_ok, "scene": _scene_path, "count": results.size(), "results": results })
	quit(0 if all_ok else 1)

# ---------------------------------------------------------------------------------------------------
# scene lifecycle
# ---------------------------------------------------------------------------------------------------

func _load_scene(path: String) -> Dictionary:
	if not ResourceLoader.exists(path):
		return { "ok": false, "error": "scene not found: " + path }
	var ps: PackedScene = load(path)
	if ps == null:
		return { "ok": false, "error": "could not load PackedScene: " + path }
	var inst := ps.instantiate()
	if inst == null:
		return { "ok": false, "error": "could not instantiate: " + path }
	# Apply harness config to a board-shaped scene (points it at a temp substrate) BEFORE _ready runs.
	if not _config.is_empty() and "config" in inst:
		var merged: Dictionary = (inst.get("config") as Dictionary).duplicate()
		for k in _config:
			merged[k] = _config[k]
		inst.set("config", merged)
	# A Control scene needs an explicitly-sized parent: the headless main window is tiny (a ScrollContainer
	# CLIPS hit-testing to its visible rect), so we host the board in a 1600x1000 Control and full-rect it
	# — the exact pattern the proven board test uses so tile geometry matches the live 4-column layout.
	if inst is Control:
		var host := Control.new()
		host.name = "HarnessHost"
		host.size = Vector2(int(_view_w), int(_view_h))
		get_root().add_child(host)
		host.add_child(inst)
		(inst as Control).set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	else:
		get_root().add_child(inst)
	_root_scene = inst
	get_root().set_meta("harness_current_scene", inst)
	await process_frame
	# If the scene root exposes an async refresh() (the aperture board does), run it so tiles exist.
	if inst.has_method("refresh"):
		await inst.call("refresh")
	await process_frame
	await process_frame
	return { "ok": true }

# ---------------------------------------------------------------------------------------------------
# dispatch
# ---------------------------------------------------------------------------------------------------

func _dispatch(cmd: Dictionary) -> Dictionary:
	var verb := String(cmd.get("verb", cmd.get("cmd", "")))
	match verb:
		"ui_dump":       return HarnessLib.ui_dump(_scene_root())
		"ui_click":      return await _ui_click(cmd)
		"ui_hover":      return _ui_hover(cmd)
		"screenshot":    return await _screenshot(cmd)
		"read_state":    return HarnessLib.read_state(_scene_root())
		"char_move":     return await _char(cmd, "move")
		"char_look":     return await _char(cmd, "look")
		"char_interact": return await _char(cmd, "interact")
		"wait":          return await _wait(cmd)
		"list_scenes":   return HarnessLib.list_scenes()
		_:               return { "ok": false, "verb": verb, "error": "unknown verb" }

func _scene_root() -> Node:
	return _root_scene

# ---- ui_click: the load-bearing verify verb ------------------------------------------------------

func _ui_click(cmd: Dictionary) -> Dictionary:
	var root := _scene_root()
	if root == null:
		return { "ok": false, "verb": "ui_click", "error": "no scene loaded" }
	var sel: Dictionary = cmd.get("target", {})
	# Optionally reveal a hover-gated control by hovering its owning tile first.
	if bool(sel.get("reveal_hover", false)):
		var owner := HarnessLib.select_node(root, sel)
		if owner != null:
			var tile := HarnessLib.owning_tile(owner)
			if tile != null:
				HarnessLib.hover(tile)
				await process_frame
	var node := HarnessLib.select_node(root, sel)
	if node == null:
		return { "ok": false, "verb": "ui_click", "error": "target not found", "target": sel,
			"available": HarnessLib.interactive_summary(root) }
	if node is Control and not (node as Control).is_visible_in_tree():
		return { "ok": false, "verb": "ui_click", "error": "target is not visible in tree",
			"node_path": String(root.get_path_to(node)) }
	# Capture a before-state so we can ASSERT an effect fired (not just that a click was routed).
	var before := HarnessLib.capture_effect_state(root, _config)
	var ctrl := node as Control
	var at: Vector2 = ctrl.get_global_rect().get_center() if ctrl != null else Vector2.ZERO
	if cmd.has("at"):
		var a: Array = cmd["at"]
		at = Vector2(float(a[0]), float(a[1]))
	# WHO is topmost at that coord? (a covering node that eats the click is the X-button failure class).
	# Capture the routing decision + node path BEFORE the click, because a handler that removes the tile
	# (skip / decide) frees the node — get_path_to on a freed node returns "" and topmost recomputes to
	# null. Recording pre-click preserves the proof that the coord hit the intended element.
	var topmost := HarnessLib.topmost_control_at(root, at)
	var target_path := String(root.get_path_to(node))
	var topmost_path := (String(root.get_path_to(topmost)) if topmost != null else "")
	var routed_pre := topmost != null and (topmost == node or node.is_ancestor_of(topmost) or topmost.is_ancestor_of(node))
	# Establish hover on the actual target control first: a Button only fires `pressed` on release when
	# its INTERNAL hover flag is set. A live mouse sets it via cursor tracking; headless has no cursor,
	# so we (a) push a mouse-MOTION event to the coord (engages the viewport's own hover walk) and
	# (b) notify the button directly. This makes the synthesized click fire the handler exactly as a
	# real click does — without it, a click lands on the rect but the button stays quiet (the exact
	# false-positive that let a "dead" X button pass a naive rect-only test).
	HarnessLib.vp_motion(get_root(), at)
	if node is Control:
		HarnessLib.hover(node as Control)
	await process_frame
	# Synthesize the real press+release at the coord and route through the viewport's hit-test.
	HarnessLib.vp_click(get_root(), at)
	await process_frame
	await process_frame
	var after := HarnessLib.capture_effect_state(root, _config)
	var effect := HarnessLib.diff_effect(before, after)
	var effect_fired := bool(effect.get("changed", false))
	# PASS when the click landed on (or within) the intended node AND an effect fired. Routing is judged
	# from the PRE-click topmost (a skip/decide handler frees the node, so a post-click recompute would
	# wrongly read null). When the caller gives no assertable side effect (a pure navigation click uses
	# an injected recorder), routed_pre alone is the gate.
	var passed := routed_pre and (effect_fired or bool(cmd.get("effect_optional", false)))
	return {
		"ok": passed,
		"verb": "ui_click",
		"clicked_at": [at.x, at.y],
		"target_node": target_path,
		"topmost_at_coord": (topmost_path if topmost_path != "" else null),
		"routed_to_target": routed_pre,
		"effect_fired": effect_fired,
		"effect": effect,
		"assert": ("PASS" if passed else "FAIL"),
	}

func _ui_hover(cmd: Dictionary) -> Dictionary:
	var root := _scene_root()
	var node := HarnessLib.select_node(root, cmd.get("target", {}))
	if node == null:
		return { "ok": false, "verb": "ui_hover", "error": "target not found" }
	HarnessLib.hover(node)
	return { "ok": true, "verb": "ui_hover", "node_path": String(root.get_path_to(node)) }

# ---- screenshot ----------------------------------------------------------------------------------

func _screenshot(cmd: Dictionary) -> Dictionary:
	var out := String(cmd.get("out", _out_shot))
	if DisplayServer.get_name() == "headless":
		# headless has no rendered framebuffer to grab — report that honestly rather than a black png.
		return { "ok": false, "verb": "screenshot",
			"error": "headless display cannot capture a framebuffer; run without --headless for a real shot",
			"requested_out": out }
	for _i in 6:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	var abs := ProjectSettings.globalize_path(out)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var err := img.save_png(abs)
	return { "ok": err == OK, "verb": "screenshot", "out": abs, "size": [img.get_width(), img.get_height()] }

# ---- character driving (3D scenes) ---------------------------------------------------------------

func _char(cmd: Dictionary, action: String) -> Dictionary:
	var root := _scene_root()
	if root == null:
		return { "ok": false, "verb": "char_" + action, "error": "no scene loaded" }
	return await HarnessLib.char_action(self, root, action, cmd)

# ---- wait ----------------------------------------------------------------------------------------

func _wait(cmd: Dictionary) -> Dictionary:
	var n := int(cmd.get("frames", 4))
	for _i in n:
		await process_frame
	return { "ok": true, "verb": "wait", "frames": n }

# ---------------------------------------------------------------------------------------------------
# arg parsing + command resolution + emit
# ---------------------------------------------------------------------------------------------------

func _parse_args(argv: PackedStringArray) -> Dictionary:
	var out := {}
	var i := 0
	var single_args := {}
	while i < argv.size():
		var a := String(argv[i])
		if a == "--arg" and i + 1 < argv.size():
			var kv := String(argv[i + 1]).split("=", true, 1)
			if kv.size() == 2:
				single_args[kv[0]] = kv[1]
			i += 2
			continue
		if a.begins_with("--") and i + 1 < argv.size() and not String(argv[i + 1]).begins_with("--"):
			out[a.substr(2)] = argv[i + 1]
			i += 2
			continue
		if a.begins_with("--"):
			out[a.substr(2)] = true
			i += 1
			continue
		i += 1
	if not single_args.is_empty():
		out["_single_args"] = single_args
	return out

## Resolve the command list from --cmds (inline JSON), --cmds-file (a path), or --cmd + --arg pairs.
func _resolve_cmds(args: Dictionary) -> Array:
	if args.has("cmds"):
		return _as_cmd_array(JSON.parse_string(String(args["cmds"])))
	if args.has("cmds-file"):
		var p := ProjectSettings.globalize_path(String(args["cmds-file"])) if String(args["cmds-file"]).begins_with("res://") else String(args["cmds-file"])
		if FileAccess.file_exists(p):
			return _as_cmd_array(JSON.parse_string(FileAccess.get_file_as_string(p)))
		return []
	if args.has("cmd"):
		var single := { "verb": String(args["cmd"]) }
		var sa: Dictionary = args.get("_single_args", {})
		for k in sa:
			single[k] = _coerce(String(sa[k]))
		return [single]
	return []

func _as_cmd_array(parsed) -> Array:
	if typeof(parsed) == TYPE_ARRAY:
		return parsed
	if typeof(parsed) == TYPE_DICTIONARY:
		return [parsed]
	return []

## Coerce a --arg string value: JSON if it parses (numbers, arrays, objects, bools), else raw string.
func _coerce(v: String) -> Variant:
	var p = JSON.parse_string(v)
	if p != null:
		return p
	return v

func _emit(obj: Dictionary) -> void:
	var line := JSON.stringify(obj)
	# The one-line machine-readable form (the python wrapper greps this prefix).
	print("HARNESS_JSON:" + line)
	# A pretty copy for a human reading the raw log.
	print(JSON.stringify(obj, "  "))
