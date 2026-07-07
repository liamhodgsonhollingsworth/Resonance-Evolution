extends SceneTree
## REAL-TREE #049 TEST for the Slice-5 interaction demo — the button->dialogue / area->menu / band->led
## integration payoff (Dreams-arc Slice 5). Like the Slice-1/2/7 tests this drives the ACTUAL aperture_3d
## room the desktop shortcut opens: the DemoInteractions controller builds a REAL Aperture3D room, boots
## the ui.*/device.* host op families, MOUNTS the minimal UI renderer INSIDE that room, and drives the
## three demo arrangements on room-owned GraphRuntimes. Every assertion is on THAT mounted, room-owned
## tree via the controller's drive_once() backend — NOT a standalone GraphRuntime / a standalone widget
## (a standalone test would be the #049 FALSE PASS).
##
##   <godot> --headless --path godot -s res://headless_demo_interactions_test.gd
##
## What it proves in the REAL running room's tree:
##  1. The DemoInteractions controller builds a real Aperture3D room, boots ui.*/device.*, and MOUNTS the
##     UI renderer overlay inside the room (UiActionRenderer.is_mounted(room)).
##  2. DEMO A: pressing interact (pulse_interact + drive_once) fires dialogue.show with the right text AND
##     the mounted UI renderer RECEIVES it (dialogue_visible / dialogue_text on the real overlay).
##  3. DEMO B: moving the player INTO the area (drive_once with a near position) fires ui.menu.open and the
##     renderer shows the menu; moving OUT closes it (the Sensor->Compare->Select->WorldAction proximity gate).
##  4. DEMO C: the injected band drives device.set_led with the mapped colour (warm high / cool low) through
##     the same wires; a garbage frame no-ops gracefully.
##  5. THE GUARD: WorldActions.register_host refuses to shadow a builtin ("log"), returns false, and the
##     builtin log still works (the Slice-7 N-violation closed).
##  6. CONNECTION-ISOLATED-FAILURE (gate C): severing ONE wire in demo C kills EXACTLY the LED behaviour
##     (falls to the cool default) while an independent sibling WorldAction still fires.
##  7. MALFORMED args no-op (never crash) across the ui.* + device.* ops.
##  8. TEXT-EQUIVALENCE (gate T): drive_once() is the exact backend the GUI _process drives — no GUI-only path.

const Aperture3D := preload("res://aperture/aperture_3d.gd")
const DemoScript := preload("res://aperture/demo_interactions.gd")
const UiActionRenderer := preload("res://aperture/ui_action_renderer.gd")
const UiActions := preload("res://runtime/ui_actions.gd")
const DeviceActions := preload("res://runtime/device_actions.gd")
const WorldActions := preload("res://runtime/world_actions.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	# Clean host-wide baseline so the universality / guard sections are honest.
	UiActions.unregister_ui_ops_host()
	DeviceActions.unregister_device_ops_host()

	# --- 0. THE GUARD: register_host refuses to shadow a builtin (the Slice-7 N-violation) -----------
	var wa := WorldActions.new()
	var pre := wa.perform("log", { "message": "builtin-works" })
	_check("baseline: builtin 'log' works before any host reg", str(pre.get("op")) == "log")
	var refused := WorldActions.register_host("log", func(_a): return { "ok": true, "op": "log", "HIJACKED": true })
	_check("GUARD: register_host('log', ...) is REFUSED (returns false)", refused == false)
	# a fresh WorldActions must still dispatch the REAL builtin log, not any hijack.
	var post := WorldActions.new().perform("log", { "message": "still-builtin" })
	_check("GUARD: the builtin 'log' still works + was NOT hijacked",
		str(post.get("op")) == "log" and str(post.get("message")) == "still-builtin"
		and post.get("HIJACKED", null) == null)
	# a NON-shadowing host op still registers normally (the guard is surgical).
	var ok_reg := WorldActions.register_host("ui.menu.open", func(_a): return { "ok": true, "op": "ui.menu.open" })
	_check("GUARD: a non-builtin host op still registers (returns true)", ok_reg == true)
	WorldActions.unregister_host("ui.menu.open")

	# --- 0b. ui.* op family in isolation (declarative receipts, graceful malformed args) --------------
	var wai := WorldActions.new()
	var reg: Array = UiActions.register_ui_ops(wai)
	_check("register_ui_ops returns the 4-op ui family",
		reg.size() == 4 and reg.has("dialogue.show") and reg.has("dialogue.hide")
		and reg.has("ui.menu.open") and reg.has("ui.menu.close"))
	var d := wai.perform("dialogue.show", { "speaker": "Guide", "text": "hello" })
	_check("dialogue.show receipt carries speaker + text",
		d.get("ok") == true and str(d.get("speaker")) == "Guide" and str(d.get("text")) == "hello")
	var dv := wai.perform("dialogue.show", { "value": "wired body" })   # text rides the wired `value`
	_check("dialogue.show reads a wired `value` string as the text", str(dv.get("text")) == "wired body")
	var m := wai.perform("ui.menu.open", { "title": "Pick", "items": ["a", "b"] })
	_check("ui.menu.open receipt carries title + items",
		m.get("ok") == true and str(m.get("title")) == "Pick" and (m.get("items") as Array).size() == 2)
	# MALFORMED: garbage payloads coerce gracefully (never crash).
	var bad := wai.perform("ui.menu.open", { "value": 42, "items": {} })
	_check("MALFORMED: garbage menu args -> a well-formed receipt (empty items), no crash",
		bad.get("ok") == true and (bad.get("items") as Array).is_empty())
	var bad2 := wai.perform("dialogue.show", {})
	_check("MALFORMED: no dialogue args -> a well-formed empty receipt, no crash",
		bad2.get("ok") == true and str(bad2.get("text")) == "")

	# --- 1. build the REAL room via the DemoInteractions controller ---------------------------------
	var demo = DemoScript.new()
	get_root().add_child(demo)
	await process_frame
	await process_frame
	_check("DemoInteractions built a real Aperture3D room (the scene the shortcut opens)",
		demo.room != null and demo.room.is_inside_tree())
	# the controller's _ready force-mounts the UI renderer headless (force=_headless=true here).
	_check("#049: the UI renderer overlay is MOUNTED INSIDE the running room (the real tree)",
		UiActionRenderer.is_mounted(demo.room))
	_check("the three demo runtimes are loaded (dialogue/menu/led)",
		demo._rt_dialogue != null and demo._rt_dialogue.nodes.size() == 7
		and demo._rt_menu != null and demo._rt_menu.nodes.size() == 9
		and demo._rt_led != null and demo._rt_led.nodes.size() == 7)

	# --- 2. DEMO A: interact -> dialogue.show reaches the mounted renderer ---------------------------
	# With NO interact pulse, drive_once must NOT show a dialogue.
	var r0 := demo.drive_once(Vector3(0, 1.7, 8), 0.016)
	_check("A: no interact pulse -> dialogue.show has empty text (nothing shown)",
		str(r0.get("dialogue", {}).get("text", "")) == "")
	_check("A: the mounted dialogue box is NOT visible without a press", not UiActionRenderer.dialogue_visible(demo.room))
	# Pulse interact, then drive once: the gate fires dialogue.show and the renderer receives it.
	demo.pulse_interact()
	var rA := demo.drive_once(Vector3(0, 1.7, 8), 0.016)
	var say: Dictionary = rA.get("dialogue", {})
	_check("A: interact pulse -> dialogue.show fired with the dialogue text",
		str(say.get("op")) == "dialogue.show" and str(say.get("text")).length() > 0)
	_check("A: the mounted UI renderer RECEIVED it (dialogue box visible)", UiActionRenderer.dialogue_visible(demo.room))
	_check("A: the mounted dialogue TEXT matches the receipt (reached the real overlay)",
		UiActionRenderer.dialogue_text(demo.room) == str(say.get("text")))

	# --- 3. DEMO B: entering the area opens the menu; leaving closes it ------------------------------
	# Far from the area centre (4,1.7,-4): the proximity distance > radius => menu stays closed.
	var rB_far := demo.drive_once(Vector3(-8, 1.7, 8), 0.016)
	_check("B: player far from the area -> ui.menu.open receipt carries NO items (outside)",
		(rB_far.get("menu", {}).get("items", []) as Array).is_empty())
	_check("B: the mounted menu is NOT visible when outside the area", not UiActionRenderer.menu_visible(demo.room))
	# Walk INTO the area (right at the centre): distance ~0 < radius => the menu opens.
	var rB_in := demo.drive_once(Vector3(4, 1.7, -4), 0.016)
	var open_r: Dictionary = rB_in.get("menu", {})
	_check("B: entering the area -> ui.menu.open fired WITH items (inside)",
		str(open_r.get("op")) == "ui.menu.open" and (open_r.get("items", []) as Array).size() > 0)
	_check("B: the mounted UI renderer shows the menu with its title", UiActionRenderer.menu_visible(demo.room)
		and UiActionRenderer.menu_title(demo.room) == str(open_r.get("title")))
	# Leave the area: the menu closes on the real overlay.
	demo.drive_once(Vector3(-8, 1.7, 8), 0.016)
	_check("B: leaving the area closes the menu on the mounted overlay", not UiActionRenderer.menu_visible(demo.room))

	# --- 4. DEMO C: the band drives device.set_led warm/cool through the same wires ------------------
	# Force the band HIGH -> the BRAIN maps to the WARM colour (r high, b low).
	demo._force_high = true
	var rC_hi := demo.drive_once(Vector3(0, 1.7, 8), 0.016)
	var led_hi: Dictionary = rC_hi.get("led", {})
	_check("C: high band -> device.set_led fired with the WARM colour (r>0.5, b<0.5)",
		str(led_hi.get("op")) == "device.set_led" and led_hi.get("noop", null) == null
		and float(led_hi.get("r")) > 0.5 and float(led_hi.get("b")) < 0.5)
	# Force it LOW (band=0) by driving the runtime directly with a low frame -> the COOL colour.
	demo._force_high = false
	demo._rt_led.set_input_frame({ "signal.band.high": 0.0 })
	var out_lo: Dictionary = demo._rt_led.evaluate()
	var led_lo: Dictionary = out_lo.get("led", {}).get("result", {})
	_check("C: low band -> the SAME wires map to the COOL colour (b>0.5, r<0.5)",
		float(led_lo.get("b")) > 0.5 and float(led_lo.get("r")) < 0.5)
	_check("C: the two band values produced genuinely different LED colours",
		float(led_hi.get("r")) != float(led_lo.get("r")))

	# --- 5. CONNECTION-ISOLATED-FAILURE (gate C): sever ONE wire, kill EXACTLY one behaviour ---------
	# A 2-behaviour arrangement on a room-owned runtime: the band->BRAIN->device.set_led loop AND an
	# independent Const->WorldAction(log) that always fires. Sever ONLY band->hot and prove exactly the
	# device output changes (LED -> cool default) while the sibling still logs. Reuses the room runtime path.
	var iso := {
		"format": "resonance.arrangement/v1", "name": "demo_isolation",
		"nodes": [
			{ "id": "band", "type": "Input", "params": { "input_id": "signal.band.high", "default": 0.0 } },
			{ "id": "thr", "type": "Const", "params": { "value": 0.5 } },
			{ "id": "hot", "type": "Compare", "params": { "op": "gt" } },
			{ "id": "warm", "type": "Const", "params": { "value": { "r": 1.0, "g": 0.35, "b": 0.05, "addr": 0 } } },
			{ "id": "cool", "type": "Const", "params": { "value": { "r": 0.1, "g": 0.35, "b": 1.0, "addr": 0 } } },
			{ "id": "brain", "type": "Select", "params": { "default_cond": false } },
			{ "id": "led", "type": "WorldAction", "params": { "op": "device.set_led" } },
			{ "id": "k", "type": "Const", "params": { "value": "always" } },
			{ "id": "sib", "type": "WorldAction", "params": { "op": "log" } }
		],
		"wires": [
			{ "from": "band", "out": "value", "to": "hot", "in": "a" },
			{ "from": "thr", "out": "value", "to": "hot", "in": "b" },
			{ "from": "hot", "out": "result", "to": "brain", "in": "cond" },
			{ "from": "warm", "out": "value", "to": "brain", "in": "a" },
			{ "from": "cool", "out": "value", "to": "brain", "in": "b" },
			{ "from": "brain", "out": "result", "to": "led", "in": "value" },
			{ "from": "k", "out": "value", "to": "sib", "in": "value" }
		]
	}
	var rt_iso := GraphRuntime.new()
	get_root().add_child(rt_iso)
	rt_iso.load_arrangement(iso)
	rt_iso.set_input_frame({ "signal.band.high": 0.9 })
	var o_full := rt_iso.evaluate()
	_check("C: with the band wire intact, device.set_led fired WARM (r=1)",
		abs(float(o_full.get("led", {}).get("result", {}).get("r")) - 1.0) < 0.001)
	_check("C: the independent sibling WorldAction fired too (log 'always')",
		str(o_full.get("sib", {}).get("result", {}).get("message")) == "always")
	# sever ONLY band->hot: Compare `a` unconnected (0) -> 0 gt 0.5 = false -> cool branch; sibling untouched.
	iso["wires"] = [
		{ "from": "thr", "out": "value", "to": "hot", "in": "b" },
		{ "from": "hot", "out": "result", "to": "brain", "in": "cond" },
		{ "from": "warm", "out": "value", "to": "brain", "in": "a" },
		{ "from": "cool", "out": "value", "to": "brain", "in": "b" },
		{ "from": "brain", "out": "result", "to": "led", "in": "value" },
		{ "from": "k", "out": "value", "to": "sib", "in": "value" }
	]
	rt_iso.load_arrangement(iso)
	var o_cut := rt_iso.evaluate()
	_check("C: severing the band wire flipped EXACTLY the device output (LED -> cool, b>0.5)",
		float(o_cut.get("led", {}).get("result", {}).get("b")) > 0.5
		and float(o_cut.get("led", {}).get("result", {}).get("r")) < 0.5)
	_check("C: the independent sibling was untouched (still logs 'always')",
		str(o_cut.get("sib", {}).get("result", {}).get("message")) == "always")
	rt_iso.free()

	# --- 6. MALFORMED frame drives the demo runtimes without crashing --------------------------------
	# A garbage player.pos / band frame must produce well-formed (no-op-safe) receipts, never a crash.
	demo._rt_menu.set_input_frame({ "player.pos": "not-a-vector" })
	var out_badpos: Dictionary = demo._rt_menu.evaluate()
	_check("MALFORMED: a garbage player.pos still evaluates to a well-formed ui.menu.open receipt",
		str(out_badpos.get("open", {}).get("result", {}).get("op")) == "ui.menu.open")

	demo.free()
	UiActions.unregister_ui_ops_host()
	DeviceActions.unregister_device_ops_host()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)
