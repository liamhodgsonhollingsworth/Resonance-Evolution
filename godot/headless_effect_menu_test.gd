extends SceneTree
## HEADLESS SELF-TEST for the visi-sonor EFFECTS MENU backend (Slice 2B, item 7):
##   prim_effect_registry (additive register) -> prim_effect_menu_view (a VIEW over the registry) +
##   prim_demo_audio_loop (synthetic spectrum injector) + prim_audio_route_switch (demo|live perf toggle).
##
##   <godot> --headless --path godot -s res://headless_effect_menu_test.gd
##
## Judge PASS by the sentinel "RESULT: ALL PASS" (NOT the exit code — Godot's is unreliable headless).
##
## Why this shape (UI-independent backend + one seam, hardware-free):
##   • The registry is exercised as a BACKEND: a couple of STUB effects are registered as DATA (this
##     slice does NOT import Slice 2A's concrete effect classes — they build in parallel; the registry
##     discovers effects at runtime). A new effect is a NEW REGISTRATION (node-not-edit, N-ideal); the
##     test asserts additivity (register two, both present, no collision, re-register replaces cleanly).
##   • The menu view is asserted to be JUST a VIEW: layout=2d_grid vs 3d_panel yields an IDENTICAL tile
##     backend (same ids, same defaults) — only the emitted `view` descriptor's layout tag differs. That
##     is the "backend independent of UI so a 3D equivalent can exist" requirement made a headless assert.
##   • prim_demo_audio_loop injects a KNOWN synthetic frame (canned kick + sweep) into the SAME
##     set_input_frame seam the live analyzer fills; a downstream prim_feature_pick reads a band back out,
##     proving the demo-loop source feeds the exact seam. Deterministic in `t` so the value is known.
##   • prim_audio_route_switch flips demo<->live: in demo mode the downstream frame is the synthetic loop's;
##     in live mode it is the runtime's set_input_frame (the real analyzer's). The SAME feature_pick reads a
##     DIFFERENT value depending on the switch — proving the performance toggle re-sources the frame.
##   • prim_compare_diff is the pass/fail oracle where a numeric/dict comparison is the cleanest assertion.

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _initialize() -> void:
	_run()

func _run() -> void:
	_test_registry_additive_register_and_list()
	_test_menu_view_is_a_view_over_registry()
	_test_demo_loop_injects_known_frame_readable_via_feature_pick()
	_test_route_switch_flips_demo_vs_live()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- 1. prim_effect_registry: ADDITIVE register + list (a new effect = a new registration) -----------

func _test_registry_additive_register_and_list() -> void:
	# Fresh, isolated registry (the node namespaces registrations by a registry_id so parallel graphs
	# never collide, and a test starts clean). Registering is ADDITIVE — never an edit of prior rows.
	var reg := PrimEffectRegistry.new()
	get_root().add_child(reg)
	reg.params = { "registry_id": "test_menu_A" }
	reg.clear()   # start empty for a deterministic assertion

	# Register two STUB effects as DATA — no concrete 2A class imported. A registration is
	# { subgraph_factory (a type name / arrangement ref), defaults, thumbnail }.
	reg.register_effect("spectrum_bars", { "type": "VizSpectrumBars", "defaults": { "count": 32, "layout": "linear" }, "thumbnail": "res://thumbs/bars.png" })
	reg.register_effect("reactive_shape", { "type": "VizReactiveShape", "defaults": { "sides": 6 }, "thumbnail": "res://thumbs/shape.png" })

	var out: Dictionary = reg.evaluate({})
	var ids: Array = out.get("ids", [])
	_check("REGISTRY: two stub effects register + list (ids present)",
		ids.has("spectrum_bars") and ids.has("reactive_shape") and ids.size() == 2)

	var registry: Dictionary = out.get("registry", {})
	_check("REGISTRY: each registration carries factory type + defaults + thumbnail (DATA)",
		registry.has("spectrum_bars")
		and String(registry["spectrum_bars"].get("type")) == "VizSpectrumBars"
		and int(registry["spectrum_bars"].get("defaults", {}).get("count", 0)) == 32
		and String(registry["spectrum_bars"].get("thumbnail")) == "res://thumbs/bars.png")

	# ADDITIVITY: registering a THIRD effect does not disturb the first two (no collision, node-not-edit).
	reg.register_effect("waveform", { "type": "VizWaveform", "defaults": {} })
	var out3: Dictionary = reg.evaluate({})
	_check("REGISTRY: a third registration is additive (prior two untouched, now 3)",
		out3.get("ids", []).size() == 3
		and out3.get("ids", []).has("spectrum_bars")
		and out3.get("ids", []).has("reactive_shape")
		and out3.get("ids", []).has("waveform"))

	# RE-REGISTER same id = clean replace (defaults update), still 3 ids, no duplicate row.
	reg.register_effect("waveform", { "type": "VizWaveform", "defaults": { "mode": "lissajous" } })
	var out4: Dictionary = reg.evaluate({})
	_check("REGISTRY: re-registering an id replaces cleanly (no duplicate, defaults updated)",
		out4.get("ids", []).size() == 3
		and String(out4.get("registry", {}).get("waveform", {}).get("defaults", {}).get("mode", "")) == "lissajous")

	# DATA-DRIVEN registration via params.effects (an arrangement can seed the registry declaratively).
	var reg2 := PrimEffectRegistry.new()
	get_root().add_child(reg2)
	reg2.params = {
		"registry_id": "test_menu_B",
		"effects": {
			"flash": { "type": "VizFlash", "defaults": { "decay": 0.5 } },
			"particles": { "type": "VizParticles", "defaults": {} },
		},
	}
	reg2.clear()   # clear the namespaced registry, then evaluate re-seeds from params.effects
	var outB: Dictionary = reg2.evaluate({})
	_check("REGISTRY: params.effects seeds the registry declaratively (2 ids from data)",
		outB.get("ids", []).size() == 2
		and outB.get("ids", []).has("flash") and outB.get("ids", []).has("particles"))

	# EMPTY registry = a declared no-op (empty ids, empty registry), never a crash (C ideal).
	var reg3 := PrimEffectRegistry.new()
	get_root().add_child(reg3)
	reg3.params = { "registry_id": "test_menu_empty" }
	reg3.clear()
	var outE: Dictionary = reg3.evaluate({})
	_check("REGISTRY: empty registry -> empty ids (declared no-op, no crash)",
		outE.get("ids", []) is Array and outE.get("ids", []).is_empty())

	reg.free()
	reg2.free()
	reg3.free()

# --- 2. prim_effect_menu_view: a VIEW over the registry; 2d_grid vs 3d_panel = SAME backend ----------

func _test_menu_view_is_a_view_over_registry() -> void:
	# Seed a registry, then point the menu view at it. The menu only SELECTS/PREVIEWS; it does not own
	# the effects. Two layouts (2d_grid now / 3d_panel later) must yield an IDENTICAL tile backend.
	var reg := PrimEffectRegistry.new()
	get_root().add_child(reg)
	reg.params = { "registry_id": "test_menu_view" }
	reg.clear()
	reg.register_effect("spectrum_bars", { "type": "VizSpectrumBars", "defaults": { "count": 32 }, "thumbnail": "res://t/a.png" })
	reg.register_effect("waveform", { "type": "VizWaveform", "defaults": {} })
	var reg_out: Dictionary = reg.evaluate({})

	# 2D grid layout.
	var view2d := PrimEffectMenuView.new()
	get_root().add_child(view2d)
	view2d.params = { "layout": "2d_grid", "columns": 3 }
	var m2d: Dictionary = view2d.evaluate({ "registry": reg_out.get("registry"), "ids": reg_out.get("ids") })
	var tiles2d: Array = m2d.get("tiles", [])
	_check("MENU: 2d_grid enumerates one tile per registered effect (2 tiles)",
		tiles2d.size() == 2)
	_check("MENU: each tile carries id + thumbnail + defaults from the registry (selectable/previewable)",
		_tile_by_id(tiles2d, "spectrum_bars").get("thumbnail") == "res://t/a.png"
		and int(_tile_by_id(tiles2d, "spectrum_bars").get("defaults", {}).get("count", 0)) == 32)
	_check("MENU: the emitted view descriptor tags the 2d_grid layout (a VIEW, not an owner)",
		String(m2d.get("view", {}).get("layout", "")) == "2d_grid")

	# 3D panel layout — IDENTICAL backend (same ids, same defaults), only the layout tag differs.
	var view3d := PrimEffectMenuView.new()
	get_root().add_child(view3d)
	view3d.params = { "layout": "3d_panel" }
	var m3d: Dictionary = view3d.evaluate({ "registry": reg_out.get("registry"), "ids": reg_out.get("ids") })
	var tiles3d: Array = m3d.get("tiles", [])
	_check("MENU: 3d_panel yields the SAME tile backend (same count + same ids as 2d)",
		tiles3d.size() == tiles2d.size()
		and _tile_ids(tiles3d) == _tile_ids(tiles2d))
	_check("MENU: only the layout tag differs (backend independent of UI — 3D equivalent can exist)",
		String(m3d.get("view", {}).get("layout", "")) == "3d_panel")

	# ORACLE: the two layouts' tile-id sets must be dict_equal (CompareDiff oracle) — backend identity.
	var cmp := PrimCompareDiff.new()
	get_root().add_child(cmp)
	cmp.params = { "metric": "dict_equality" }
	var d := float(cmp.evaluate({
		"candidate": { "ids": _tile_ids(tiles3d) },
		"reference": { "ids": _tile_ids(tiles2d) },
	}).get("d", 1.0))
	_check("MENU: 2d vs 3d tile backend is identical (CompareDiff dict_equality == 0.0)", d == 0.0)

	# EMPTY registry input = a declared no-op (zero tiles), never a crash (C ideal).
	var mEmpty: Dictionary = view2d.evaluate({ "registry": {}, "ids": [] })
	_check("MENU: empty/absent registry -> zero tiles (declared no-op, no crash)",
		mEmpty.get("tiles", []) is Array and mEmpty.get("tiles", []).is_empty())

	cmp.free()
	view2d.free()
	view3d.free()
	reg.free()

# --- 3. prim_demo_audio_loop: injects a KNOWN synthetic frame readable via prim_feature_pick ---------

func _test_demo_loop_injects_known_frame_readable_via_feature_pick() -> void:
	# The demo loop emits a synthetic spectrum (canned kick + sweep) as a `frame` dict on the SAME keys
	# the live analyzer fills (signal.band.low/mid/high + energy). Deterministic in `t` so we can assert.
	var loop := PrimDemoAudioLoop.new()
	get_root().add_child(loop)
	loop.params = { "bpm": 120.0 }

	# A KICK lands on the beat (t == 0 => phase 0 => kick transient): low band should be strong.
	var on_beat: Dictionary = loop.evaluate({ "t": 0.0 })
	var frame_on: Dictionary = on_beat.get("frame", {})
	_check("DEMO: frame carries the seam keys (signal.band.low/mid/high)",
		frame_on.has("signal.band.low") and frame_on.has("signal.band.mid") and frame_on.has("signal.band.high"))
	_check("DEMO: on the beat (t=0) the kick makes the low band strong (> 0.5)",
		float(frame_on.get("signal.band.low", 0.0)) > 0.5)

	# OFF the beat (t = half a beat = 0.25s at 120bpm) the kick has decayed: low band much weaker.
	var off_beat: Dictionary = loop.evaluate({ "t": 0.25 })
	var frame_off: Dictionary = off_beat.get("frame", {})
	_check("DEMO: off the beat (t=0.25s) the kick has decayed (low band < on-beat low)",
		float(frame_off.get("signal.band.low", 1.0)) < float(frame_on.get("signal.band.low", 0.0)))

	# The SWEEP moves energy across bands over time: at a later t the high band differs from t=0.
	var later: Dictionary = loop.evaluate({ "t": 2.0 })
	var frame_late: Dictionary = later.get("frame", {})
	_check("DEMO: the frequency sweep moves energy over time (high band changes across t)",
		absf(float(frame_late.get("signal.band.high", 0.0)) - float(frame_on.get("signal.band.high", 0.0))) > 0.05)

	# All named values stay in [0,1] (a well-formed synthetic spectrum — C/T ideals).
	_check("DEMO: every synthetic band value is in [0,1]",
		_in_unit(frame_on.get("signal.band.low")) and _in_unit(frame_on.get("signal.band.mid"))
		and _in_unit(frame_on.get("signal.band.high")) and _in_unit(frame_on.get("signal.energy")))

	# READABLE via prim_feature_pick off the SAME frame (the seam the live analyzer uses). A feature_pick
	# with a wired `frame` reads the demo loop's output directly — proving the demo source feeds the seam.
	var pick := PrimFeaturePick.new()
	get_root().add_child(pick)
	pick.params = { "feature": "bass" }   # bass -> signal.band.low
	var picked: Dictionary = pick.evaluate({ "frame": frame_on })
	_check("DEMO: prim_feature_pick(bass) reads the demo loop's low band off the frame (== injected)",
		float(picked.get("value")) == float(frame_on.get("signal.band.low")))

	pick.free()
	loop.free()

# --- 4. prim_audio_route_switch: flips demo<->live; downstream frame source changes -------------------

func _test_route_switch_flips_demo_vs_live() -> void:
	# The switch chooses the DEMO frame (synthetic loop) vs the LIVE frame (runtime set_input_frame the
	# real analyzer fills). It emits the chosen `frame` on a wire; a downstream feature_pick then reads a
	# DIFFERENT value depending on the switch — the performance toggle re-sourcing the frame.
	var demo_frame := { "signal.band.low": 0.9, "signal.band.mid": 0.1, "signal.band.high": 0.1, "signal.energy": 0.5 }
	var live_frame := { "signal.band.low": 0.1, "signal.band.mid": 0.2, "signal.band.high": 0.8, "signal.energy": 0.6 }

	var sw := PrimAudioRouteSwitch.new()
	get_root().add_child(sw)

	# DEMO mode: the emitted frame is the synthetic one.
	sw.params = { "mode": "demo" }
	var out_demo: Dictionary = sw.evaluate({ "demo_frame": demo_frame, "live_frame": live_frame })
	_check("SWITCH: demo mode emits the synthetic (demo) frame",
		float(out_demo.get("frame", {}).get("signal.band.low", -1.0)) == 0.9
		and String(out_demo.get("source", "")) == "demo")

	# LIVE mode: the emitted frame is the real analyzer's.
	sw.params = { "mode": "live" }
	var out_live: Dictionary = sw.evaluate({ "demo_frame": demo_frame, "live_frame": live_frame })
	_check("SWITCH: live mode emits the live (analyzer) frame",
		float(out_live.get("frame", {}).get("signal.band.high", -1.0)) == 0.8
		and String(out_live.get("source", "")) == "live")

	# DOWNSTREAM: the SAME feature_pick reads a DIFFERENT value across the flip (re-sourcing proven).
	var pick := PrimFeaturePick.new()
	get_root().add_child(pick)
	pick.params = { "feature": "treble" }   # treble -> signal.band.high
	var v_demo := float(pick.evaluate({ "frame": out_demo.get("frame") }).get("value"))
	var v_live := float(pick.evaluate({ "frame": out_live.get("frame") }).get("value"))
	_check("SWITCH: downstream feature_pick(treble) reads demo=0.1 vs live=0.8 (frame source flipped)",
		v_demo == 0.1 and v_live == 0.8 and v_demo != v_live)

	# LIVE mode with NO live_frame wired: falls back to the runtime's set_input_frame seam if mounted,
	# else a declared no-op (empty frame), never a crash (C ideal).
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1", "name": "route_switch_live",
		"nodes": [ { "id": "sw", "type": "AudioRouteSwitch", "params": { "mode": "live" } } ],
		"wires": [],
	})
	rt.set_input_frame({ "signal.band.high": 0.77 })
	var rt_out := rt.evaluate()
	_check("SWITCH: live mode with no live_frame wire reads the runtime set_input_frame seam (0.77)",
		float(rt_out.get("sw", {}).get("frame", {}).get("signal.band.high", -1.0)) == 0.77)

	# ABSENT everything = a declared no-op (empty frame), no crash.
	var swbare := PrimAudioRouteSwitch.new()
	get_root().add_child(swbare)
	swbare.params = { "mode": "demo" }
	var bare: Dictionary = swbare.evaluate({})
	_check("SWITCH: absent inputs -> empty frame (declared no-op, no crash)",
		bare.get("frame", null) is Dictionary and (bare.get("frame") as Dictionary).is_empty())

	swbare.free()
	rt.free()
	pick.free()
	sw.free()

# --- helpers ---------------------------------------------------------------------------------------

func _tile_by_id(tiles: Array, id: String) -> Dictionary:
	for t in tiles:
		if t is Dictionary and String(t.get("id")) == id:
			return t
	return {}

func _tile_ids(tiles: Array) -> Array:
	var out: Array = []
	for t in tiles:
		if t is Dictionary:
			out.append(String(t.get("id")))
	out.sort()
	return out

func _in_unit(v) -> bool:
	if v == null:
		return false
	var f := float(v)
	return f >= 0.0 and f <= 1.0
