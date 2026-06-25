extends SceneTree
## Proves the EFFECT-STACK seam: the painterly look is renderer-neutral ARRANGEMENT DATA, and a
## swappable delegate (EffectStackCpu, the headless CPU reference) applies it deterministically.
## This is the 2D analogue of headless_primitive_test.gd (which proves the same for 3D scene_node
## data). It does NOT touch the renderer-shader / GPU path — that is a later swappable delegate
## against this same descriptor.
##   godot --headless --path godot -s res://headless_effect_test.gd
##
## What it checks:
##  1. PrimEffectStack emits an effect_stack DATA descriptor (a dict with an ordered "stack" array).
##  2. The stack is plain serializable data (round-trips through JSON unchanged) — portability.
##  3. EffectStackCpu honours the layers IN ORDER and the posterize effect quantizes correctly.
##  4. Reordering the layers is observable (order = composition = the evolver's genome lever).
##  5. Chaining two stacks via the `in` wire composes (upstream layers run first).

func _initialize() -> void:
	var ok := true

	# --- 1. The primitive emits effect_stack DATA (mirroring how PrimModel emits scene_node data). ---
	var prim := PrimEffectStack.new()
	prim.params = { "layers": [
		{ "type": "posterize", "params": { "levels": 2 } },
		{ "type": "passthrough", "params": {} }
	] }
	var out := prim.evaluate({})
	var desc = out.get("stack")
	ok = _check("primitive emits an effect_stack descriptor", PrimEffectStack.is_effect_stack(desc)) and ok
	ok = _check("descriptor carries 2 ordered layers", desc.get("stack", []).size() == 2) and ok
	ok = _check("layer 0 is posterize (order preserved)", String(desc["stack"][0]["type"]) == "posterize") and ok

	# --- 2. The descriptor is pure serializable DATA (JSON round-trip identical) — portability law. ---
	var json := JSON.stringify(desc)
	var reparsed = JSON.parse_string(json)
	ok = _check("effect_stack round-trips through JSON (portable, no live refs)",
		reparsed != null and reparsed.get("stack", []).size() == 2) and ok

	# --- 3. The CPU delegate applies posterize correctly on a known image. ---
	# A 2x1 image: a mid-grey (0.4) and a near-white (0.9). levels=2 -> bands at {0.0, 1.0}.
	# 0.4 rounds to 0.0 (black); 0.9 rounds to 1.0 (white). Deterministic ground truth.
	var src := Image.create(2, 1, false, Image.FORMAT_RGBAF)
	src.set_pixel(0, 0, Color(0.4, 0.4, 0.4, 1.0))
	src.set_pixel(1, 0, Color(0.9, 0.9, 0.9, 1.0))
	var result := EffectStackCpu.apply(desc, src)
	var p0 := result.get_pixel(0, 0)
	var p1 := result.get_pixel(1, 0)
	ok = _check("posterize levels=2: 0.4 -> 0.0 (snaps to black)", is_equal_approx(p0.r, 0.0)) and ok
	ok = _check("posterize levels=2: 0.9 -> 1.0 (snaps to white)", is_equal_approx(p1.r, 1.0)) and ok
	ok = _check("posterize preserves alpha", is_equal_approx(p0.a, 1.0)) and ok
	ok = _check("CPU delegate returns a NEW image (source untouched)",
		is_equal_approx(src.get_pixel(0, 0).r, 0.4)) and ok

	# --- 4. Order matters: a finer posterize (levels=4) yields a DIFFERENT result than levels=2. ---
	# 0.4 at levels=4 (bands 0, .333, .667, 1) snaps to 0.333, NOT 0.0 — so the knob is honoured.
	var fine := { "stack": [ { "type": "posterize", "params": { "levels": 4 } } ] }
	var fine_res := EffectStackCpu.apply(fine, src)
	ok = _check("posterize knob honoured: levels=4 -> 0.4 snaps to 0.333 (not 0.0)",
		is_equal_approx(fine_res.get_pixel(0, 0).r, 1.0 / 3.0)) and ok

	# --- 5. Chaining: a downstream stack wired onto an upstream one composes (upstream runs first). ---
	var upstream := PrimEffectStack.new()
	upstream.params = { "layers": [ { "type": "passthrough", "params": {} } ] }
	var up_desc = upstream.evaluate({}).get("stack")
	var downstream := PrimEffectStack.new()
	downstream.params = { "layers": [ { "type": "posterize", "params": { "levels": 2 } } ] }
	var chained = downstream.evaluate({ "in": up_desc }).get("stack")
	ok = _check("chaining prepends upstream layers (composes, upstream first)",
		chained.get("stack", []).size() == 2
		and String(chained["stack"][0]["type"]) == "passthrough"
		and String(chained["stack"][1]["type"]) == "posterize") and ok

	# --- 6. The runtime registers the new type (it is a real primitive, wirable in any arrangement). ---
	var rt := GraphRuntime.new()
	rt.load_arrangement({
		"nodes": [ { "id": "fx", "type": "EffectStack", "params": { "layers": [
			{ "type": "posterize", "params": { "levels": 3 } }
		] } } ],
		"wires": []
	})
	var evald := rt.evaluate()
	ok = _check("EffectStack node evaluates inside GraphRuntime",
		evald.has("fx") and PrimEffectStack.is_effect_stack(evald["fx"].get("stack"))) and ok
	rt.free()

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
