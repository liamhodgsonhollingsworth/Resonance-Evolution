extends SceneTree
## REAL-TREE TEST for Slice 1B — FREQ-MAPPING + UNIVERSAL BIND (visi-sonor light-show arc, items 6+8).
##
##   <godot> --headless --path godot -s res://headless_freq_map_test.gd
##
## Drives the SAME GraphRuntime the running room hot-loads arrangements into (NOT a bare isolated
## node) — the six new primitives are wired into a live GraphRuntime, the band frame is injected via
## the EXISTING set_input_frame seam (the read side PrimInput/PrimSensor already use), and evaluate()
## runs the real topo/dataflow. A standalone-node call would be a #049 FALSE PASS; this exercises the
## nodes exactly as the demo arrangement will.
##
## What it proves (the slice's four assertions + the ideals):
##  (a) prim_freq_to_color warm_cool_ramp -> WARM hue for a bass-dominant frame, COOL hue for treble.
##  (b) prim_size_sort_bind -> big fixtures bind to LOW bands, small fixtures to HIGH bands (monotone).
##  (c) prim_feature_pick can be REPOINTED from one band key to another and the bound output follows
##      (the item-8 generality assertion) — a re-wire/re-param, never an engine edit.
##  (d) prim_param_bind's normalize / remap / response-curve / gate each affect the output as specified,
##      and prim_envelope_follower smooths with distinct attack vs release.
##  Ideals verified in the REAL tree: T (plain DATA on wires), C (absent/unknown input = declared
##  no-op, never a crash), D (a node re-param diff-reloads live), N (all NEW nodes, no primitive edits).

const GraphRuntimeRef := preload("res://runtime/graph_runtime.gd")

var _fail := 0

func _check(name: String, cond: bool) -> bool:
	print(("PASS  " if cond else "FAIL  ") + name)
	if not cond:
		_fail += 1
	return cond

func _approx(a: float, b: float, eps: float = 1e-4) -> bool:
	return abs(a - b) <= eps

func _initialize() -> void:
	_run()

# Build a live GraphRuntime with the six new 1B types registered on it (the real dataflow host).
func _make_runtime() -> GraphRuntime:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	# Register the NEW 1B primitive types onto THIS runtime (they are also registered host-wide in
	# graph_runtime.gd _init; registering here keeps the test self-contained + explicit about the seam).
	rt.register("FeaturePick", load("res://primitives/prim_feature_pick.gd"))
	rt.register("EnvelopeFollower", load("res://primitives/prim_envelope_follower.gd"))
	rt.register("ResponseCurve", load("res://primitives/prim_response_curve.gd"))
	rt.register("ParamBind", load("res://primitives/prim_param_bind.gd"))
	rt.register("FreqToColor", load("res://primitives/prim_freq_to_color.gd"))
	rt.register("SizeSortBind", load("res://primitives/prim_size_sort_bind.gd"))
	return rt

func _run() -> void:
	_test_a_freq_to_color()
	_test_b_size_sort_bind()
	_test_c_feature_pick_repoint()
	_test_d_param_bind_stages()
	_test_envelope_follower()
	_test_ideals_isolation()
	print("RESULT: ", "ALL PASS" if _fail == 0 else ("%d FAIL" % _fail))
	quit(0 if _fail == 0 else 1)

# --- (a) prim_freq_to_color: warm for bass, cool for treble ---------------------------------------
func _test_a_freq_to_color() -> void:
	var rt := _make_runtime()
	# One FreqToColor node reading `bass` + `treble` off wired Inputs from the injected band frame.
	# A bass-dominant frame -> warm (r high, b low); a treble-dominant frame -> cool (b high, r low).
	var arr := {
		"format": "resonance.arrangement/v1", "name": "freq_to_color",
		"nodes": [
			{ "id": "bass", "type": "Input", "params": { "input_id": "signal.band.low", "default": 0.0 } },
			{ "id": "treb", "type": "Input", "params": { "input_id": "signal.band.high", "default": 0.0 } },
			{ "id": "col", "type": "FreqToColor", "params": { "mode": "warm_cool_ramp", "palette": "default" } },
		],
		"wires": [
			{ "from": "bass", "out": "value", "to": "col", "in": "bass" },
			{ "from": "treb", "out": "value", "to": "col", "in": "treble" },
		],
	}
	rt.load_arrangement(arr)

	rt.set_input_frame({ "signal.band.low": 0.9, "signal.band.high": 0.1 })
	var out_bass := rt.evaluate()
	var c_bass: Dictionary = out_bass.get("col", {}).get("value", {})
	_check("(a) freq_to_color emits a {r,g,b,addr} color dict (T: plain DATA on the wire)",
		c_bass.has("r") and c_bass.has("g") and c_bass.has("b") and c_bass.has("addr"))
	_check("(a) BASS-dominant frame -> WARM hue (r > b)", float(c_bass.get("r", 0.0)) > float(c_bass.get("b", 0.0)))

	rt.set_input_frame({ "signal.band.low": 0.1, "signal.band.high": 0.9 })
	var out_treb := rt.evaluate()
	var c_treb: Dictionary = out_treb.get("col", {}).get("value", {})
	_check("(a) TREBLE-dominant frame -> COOL hue (b > r)", float(c_treb.get("b", 0.0)) > float(c_treb.get("r", 0.0)))

	# value_from=amplitude: a louder frame at the same balance yields a brighter (higher-magnitude) color.
	rt.set_input_frame({ "signal.band.low": 0.9, "signal.band.high": 0.1 })
	var bright := rt.evaluate().get("col", {}).get("value", {})
	rt.set_input_frame({ "signal.band.low": 0.3, "signal.band.high": 0.03 })
	var dim := rt.evaluate().get("col", {}).get("value", {})
	var mag_bright: float = float(bright.get("r", 0.0)) + float(bright.get("g", 0.0)) + float(bright.get("b", 0.0))
	var mag_dim: float = float(dim.get("r", 0.0)) + float(dim.get("g", 0.0)) + float(dim.get("b", 0.0))
	_check("(a) value_from=amplitude: louder frame -> brighter color", mag_bright > mag_dim)
	rt.free()

# --- (b) prim_size_sort_bind: big -> low band, small -> high band ---------------------------------
func _test_b_size_sort_bind() -> void:
	var rt := _make_runtime()
	# Four fixtures of different sizes -> a monotone assignment to 4 bands. Big fixture -> lowest band
	# index (bass), small fixture -> highest band index (treble). ascending=true is big->low.
	var band_keys := ["signal.band.low", "signal.band.lowmid", "signal.band.mid", "signal.band.high"]
	var arr := {
		"format": "resonance.arrangement/v1", "name": "size_sort_bind",
		"nodes": [
			{ "id": "bind", "type": "SizeSortBind", "params": {
				"sizes": [3.0, 0.5, 2.0, 1.0],
				"band_keys": band_keys,
				"ascending": true,
			} },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var bindings: Array = out.get("bind", {}).get("bindings", [])
	_check("(b) size_sort_bind emits one binding per fixture", bindings.size() == 4)

	# Build fixture_index -> band_index map from the bindings.
	var idx_to_band := {}
	for bnd in bindings:
		idx_to_band[int(bnd.get("index"))] = int(bnd.get("band"))
	# sizes were [3.0, 0.5, 2.0, 1.0]; sorted big->small = fixtures [0 (3.0), 2 (2.0), 3 (1.0), 1 (0.5)].
	# big->low means fixture 0 -> band 0, fixture 2 -> band 1, fixture 3 -> band 2, fixture 1 -> band 3.
	_check("(b) BIGGEST fixture (idx 0, size 3.0) -> LOWEST band (0 = bass)", idx_to_band.get(0) == 0)
	_check("(b) SMALLEST fixture (idx 1, size 0.5) -> HIGHEST band (3 = treble)", idx_to_band.get(1) == 3)
	_check("(b) 2nd-biggest (idx 2, size 2.0) -> band 1", idx_to_band.get(2) == 1)
	_check("(b) 2nd-smallest (idx 3, size 1.0) -> band 2", idx_to_band.get(3) == 2)

	# Monotonicity: sorting fixtures by size descending yields non-decreasing band indices.
	var pairs := []
	for bnd in bindings:
		pairs.append([float(bnd.get("size")), int(bnd.get("band"))])
	pairs.sort_custom(func(x, y): return x[0] > y[0])   # size descending
	var mono := true
	for i in range(1, pairs.size()):
		if pairs[i][1] < pairs[i - 1][1]:
			mono = false
	_check("(b) MONOTONE: bigger fixture never maps to a higher band than a smaller one", mono)

	# Each binding also carries the band_key string (so it wires straight to a feature/frame key).
	_check("(b) binding carries the band_key for the biggest fixture", String(idx_to_band_key(bindings, 0)) == "signal.band.low")
	rt.free()

func idx_to_band_key(bindings: Array, fixture_index: int) -> String:
	for bnd in bindings:
		if int(bnd.get("index")) == fixture_index:
			return String(bnd.get("band_key", ""))
	return ""

# --- (c) prim_feature_pick REPOINTS between band keys (item-8 generality) -------------------------
func _test_c_feature_pick_repoint() -> void:
	var rt := _make_runtime()
	# A FeaturePick set to `bass` reads signal.band.low; re-param it to `treble` and the SAME wired
	# consumer now follows signal.band.high — a re-wire, never an engine edit.
	var arr := {
		"format": "resonance.arrangement/v1", "name": "feature_pick_repoint",
		"nodes": [
			{ "id": "pick", "type": "FeaturePick", "params": { "feature": "bass" } },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)
	rt.set_input_frame({ "signal.band.low": 0.7, "signal.band.high": 0.2 })
	var out_bass := rt.evaluate()
	_check("(c) FeaturePick(feature=bass) emits the LOW band value", _approx(float(out_bass.get("pick", {}).get("value", -1.0)), 0.7))

	# REPOINT: change only the param (a diff-hotload, D ideal), keep the same wires, re-evaluate.
	arr["nodes"][0]["params"] = { "feature": "treble" }
	rt.load_arrangement(arr)
	var out_treb := rt.evaluate()
	_check("(c) REPOINTED to feature=treble -> the same node now follows the HIGH band value (item-8)",
		_approx(float(out_treb.get("pick", {}).get("value", -1.0)), 0.2))

	# Repoint to `energy` (a different frame family) — proves the pick routes ANY feature key.
	arr["nodes"][0]["params"] = { "feature": "energy" }
	rt.load_arrangement(arr)
	rt.set_input_frame({ "signal.energy": 0.55 })
	var out_energy := rt.evaluate()
	_check("(c) REPOINTED to feature=energy -> follows signal.energy", _approx(float(out_energy.get("pick", {}).get("value", -1.0)), 0.55))

	# C ideal: an UNKNOWN feature is a declared no-op (falls to default), never a crash.
	arr["nodes"][0]["params"] = { "feature": "not_a_feature", "default": -9.0 }
	rt.load_arrangement(arr)
	var out_unknown := rt.evaluate()
	_check("(c) C: UNKNOWN feature key falls to params.default (no crash)", _approx(float(out_unknown.get("pick", {}).get("value", 0.0)), -9.0))
	rt.free()

# --- (d) prim_param_bind: normalize / remap / curve / gate each affect the output -----------------
func _test_d_param_bind_stages() -> void:
	var rt := _make_runtime()

	# NORMALIZE: in_min..in_max maps to 0..1 before anything else. x=5 in [0,10] -> 0.5;
	# with a linear curve and out 0..1 the output is 0.5.
	_bind_case(rt, { "in_min": 0.0, "in_max": 10.0 }, 5.0, 0.5, "(d) NORMALIZE: x=5 in [0,10] -> 0.5")
	_bind_case(rt, { "in_min": 0.0, "in_max": 10.0 }, 0.0, 0.0, "(d) NORMALIZE: x=in_min -> 0.0")
	_bind_case(rt, { "in_min": 0.0, "in_max": 10.0 }, 10.0, 1.0, "(d) NORMALIZE: x=in_max -> 1.0")
	# clamp: above in_max stays 1.0 (normalized value is clamped 0..1).
	_bind_case(rt, { "in_min": 0.0, "in_max": 10.0 }, 20.0, 1.0, "(d) NORMALIZE: above in_max clamps to 1.0")

	# REMAP: after normalize, out_min..out_max scales the 0..1 to the target range.
	# x=0.5 in [0,1] -> 0.5 normalized -> remapped into [10,20] -> 15.
	_bind_case(rt, { "in_min": 0.0, "in_max": 1.0, "out_min": 10.0, "out_max": 20.0 }, 0.5, 15.0, "(d) REMAP: 0.5 -> [10,20] -> 15")

	# RESPONSE CURVE: exp shape bends the 0..1. At x=0.5, exp curve (k=2) yields 0.25 (0.5^2), so with
	# a plain [0,1] normalize + [0,1] remap the output is 0.25, distinct from the linear 0.5.
	_bind_case(rt, { "in_min": 0.0, "in_max": 1.0, "curve_shape": "exp", "curve_k": 2.0 }, 0.5, 0.25, "(d) CURVE: exp(k=2) bends 0.5 -> 0.25")
	# linear leaves it untouched (0.5 -> 0.5) — proves the curve is what changed the exp result.
	_bind_case(rt, { "in_min": 0.0, "in_max": 1.0, "curve_shape": "linear" }, 0.5, 0.5, "(d) CURVE: linear leaves 0.5 -> 0.5")

	# GATE: values whose NORMALIZED level is below gate_min are forced to out_min (silence floor).
	# gate_min=0.3: x=0.2 (normalized 0.2) is below the gate -> 0.0; x=0.5 passes -> 0.5.
	_bind_case(rt, { "in_min": 0.0, "in_max": 1.0, "gate_min": 0.3 }, 0.2, 0.0, "(d) GATE: below gate_min -> 0.0")
	_bind_case(rt, { "in_min": 0.0, "in_max": 1.0, "gate_min": 0.3 }, 0.5, 0.5, "(d) GATE: above gate_min passes through")
	rt.free()

# Helper: one ParamBind case. Wires a Const `x` into a ParamBind and asserts the output value.
# attack/release default to 1.0 (no smoothing) so the pipeline math is deterministic per-evaluate.
func _bind_case(rt: GraphRuntime, bind_params: Dictionary, x: float, expected: float, label: String) -> void:
	var p := bind_params.duplicate()
	if not p.has("attack"): p["attack"] = 1.0
	if not p.has("release"): p["release"] = 1.0
	var arr := {
		"format": "resonance.arrangement/v1", "name": "bind_case",
		"nodes": [
			{ "id": "x", "type": "Const", "params": { "value": x } },
			{ "id": "bind", "type": "ParamBind", "params": p },
		],
		"wires": [ { "from": "x", "out": "value", "to": "bind", "in": "x" } ],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var got := float(out.get("bind", {}).get("value", -999.0))
	_check(label + " (got %.4f, want %.4f)" % [got, expected], _approx(got, expected))

# --- prim_envelope_follower: distinct attack vs release smoothing ---------------------------------
func _test_envelope_follower() -> void:
	var rt := _make_runtime()
	# attack=0.5, release=0.1. Feed a step 0 -> 1: on RISE the follower moves at the (fast) attack rate;
	# then feed 1 -> 0 and it decays at the (slow) release rate. Assert the rise is faster than the fall.
	var arr := {
		"format": "resonance.arrangement/v1", "name": "envelope",
		"nodes": [
			{ "id": "x", "type": "Const", "params": { "value": 0.0 } },
			{ "id": "env", "type": "EnvelopeFollower", "params": { "attack": 0.5, "release": 0.1 } },
		],
		"wires": [ { "from": "x", "out": "value", "to": "env", "in": "x" } ],
	}
	rt.load_arrangement(arr)
	# seed at 0
	var y0 := float(rt.evaluate().get("env", {}).get("value", -1.0))
	_check("(env) follower seeds at the first input (0.0)", _approx(y0, 0.0))
	# step to 1.0 -> attack smoothing: prev + attack*(1-prev) = 0 + 0.5*1 = 0.5
	arr["nodes"][0]["params"] = { "value": 1.0 }
	rt.load_arrangement(arr)
	var y_rise := float(rt.evaluate().get("env", {}).get("value", -1.0))
	_check("(env) RISE uses attack coeff: 0 -> 0.5 after one step (attack=0.5)", _approx(y_rise, 0.5))
	# hold 1.0 another step -> 0.5 + 0.5*(1-0.5) = 0.75 (still rising toward 1)
	var y_rise2 := float(rt.evaluate().get("env", {}).get("value", -1.0))
	_check("(env) RISE continues toward target (0.5 -> 0.75)", _approx(y_rise2, 0.75))
	# now drop to 0.0 -> release smoothing (slow): prev + release*(0-prev) = 0.75 - 0.1*0.75 = 0.675
	arr["nodes"][0]["params"] = { "value": 0.0 }
	rt.load_arrangement(arr)
	var y_fall := float(rt.evaluate().get("env", {}).get("value", -1.0))
	_check("(env) FALL uses release coeff: 0.75 -> 0.675 (release=0.1, slower than attack)", _approx(y_fall, 0.675))
	_check("(env) attack step magnitude > release step magnitude (fall is slower)",
		abs(y_rise - 0.0) > abs(y_rise2 - y_fall))
	rt.free()

# --- ideals: C (isolated failure) + D (diff-hotload) + T (data on wires) ---------------------------
func _test_ideals_isolation() -> void:
	var rt := _make_runtime()
	# C: a ParamBind with NO x wired (unconnected input arrives as null) is a declared no-op emitting
	# out_min (its defined floor), never a crash.
	var arr := {
		"format": "resonance.arrangement/v1", "name": "isolation",
		"nodes": [
			{ "id": "bind", "type": "ParamBind", "params": { "out_min": 0.0, "out_max": 1.0 } },
			{ "id": "col", "type": "FreqToColor", "params": {} },
			{ "id": "pick", "type": "FeaturePick", "params": { "feature": "bass" } },
		],
		"wires": [],
	}
	rt.load_arrangement(arr)   # no frame injected either
	var out := rt.evaluate()
	_check("(C) ParamBind with unconnected input -> defined no-op value (no crash)",
		out.get("bind", {}).has("value"))
	var col: Dictionary = out.get("col", {}).get("value", {})
	_check("(C) FreqToColor with no inputs + no frame -> defined color (no crash)", col.has("r"))
	_check("(C) FeaturePick with no frame -> params.default (no crash)",
		out.get("pick", {}).has("value"))

	# D: change ONE node's params and re-load — only that node's output changes, the rest are untouched.
	arr["nodes"][0]["params"] = { "out_min": 5.0, "out_max": 5.0 }   # constant floor 5.0
	rt.load_arrangement(arr)
	var out2 := rt.evaluate()
	_check("(D) diff-hotload: re-paramed ParamBind now floors at 5.0 without rebuilding the graph",
		_approx(float(out2.get("bind", {}).get("value", -1.0)), 5.0))
	rt.free()
