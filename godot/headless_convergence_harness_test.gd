extends SceneTree
## Headless CONTRACT test for the convergence harness (Dreams-arc Slice 6) in the REAL GraphRuntime:
##
##   godot --headless --path godot -s res://headless_convergence_harness_test.gd
##
## #049 REAL-TREE: every assertion below runs the ACTUAL convergence_harness.json arrangement inside a
## live GraphRuntime — the same runtime the user's graphs run on — and reads the WIRED output `d` (and the
## gate's `count`) off the evaluated graph, NEVER an isolated function call. The driver steps the harness
## ROUND BY ROUND by DIFF-HOTLOADING the candidate Const (the D ideal: one node re-splices, siblings keep
## their instances), so the harness is exercised exactly as a live evolver/Lathe-swap loop would drive it.
##
## THE WHOLE POINT (never "it ran"): the deliverable is that the harness REPORTS WHETHER d DECREASES.
##   • CONVERGING sequence  -> assert d is monotonically DECREASING toward the target AND the gate FIRES
##                             (Context `gate` propagates -> `count` non-null) exactly when d <= epsilon.
##   • NON-CONVERGING seq   -> assert the NON-DECREASING-d FAILURE signal fires (d rises on some round) AND
##                             the gate NEVER fires (count stays null: never reached convergence).
## Plus the ideals: N (metric in DATA, one comparator), D (candidate hot-loads as a diff — same instance),
## C (sever the reference wire -> only d changes), T (a text path drives the same backend), and the
## metric-plugin seam (dict_equality / l2 / abs + an unknown-metric declared sentinel).

const ARR_PATH := "res://arrangements/convergence_harness.json"

func _initialize() -> void:
	var ok := true
	ok = _converging_contract() and ok
	ok = _non_converging_contract() and ok
	ok = _metric_plugin_seam() and ok
	ok = _adversarial_robustness() and ok
	ok = _diff_hotload_same_instance() and ok
	ok = _connection_isolated_failure() and ok
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# -- Load the real harness arrangement fresh into a live runtime ------------------------------------
func _load_harness() -> GraphRuntime:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var text := FileAccess.get_file_as_string(ARR_PATH)
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("could not parse " + ARR_PATH)
		return rt
	rt.load_arrangement(data)
	return rt

func _free_rt(rt: GraphRuntime) -> void:
	get_root().remove_child(rt)
	rt.free()

## Diff-hotload ONE round: splice the candidate Const's value (a diff, not a rebuild), evaluate the whole
## wired graph, and return { d, count } read off the LIVE outputs. This IS the real-tree step.
func _run_round(rt: GraphRuntime, candidate_value) -> Dictionary:
	var arr: Dictionary = rt.arrangement.duplicate(true)
	for n in arr["nodes"]:
		if n["id"] == "candidate":
			n["params"] = { "value": candidate_value }
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	return {
		"d": out.get("diff", {}).get("d"),
		"count": out.get("gate", {}).get("count"),
		"iterate": out.get("iterate", {}).get("result"),
	}

# -- CONVERGING contract: d decreases every round; gate fires exactly at convergence ---------------
func _converging_contract() -> bool:
	var rt := _load_harness()
	# reference = 0.0, epsilon = 0.5 (from the arrangement). A candidate sequence marching toward 0.
	var seq := [10.0, 6.0, 3.0, 1.0, 0.4, 0.1]
	var ds := []
	var gate_fired_round := -1
	var iterate_ran_every_round := true
	for i in seq.size():
		var r := _run_round(rt, seq[i])
		ds.append(r["d"])
		# The Iterate Action must produce a receipt EVERY round (the fixture advances each round).
		if not (r["iterate"] is Dictionary and (r["iterate"] as Dictionary).get("ok") == true):
			iterate_ran_every_round = false
		# Gate fires (Context `gate` propagates -> count non-null) the FIRST round d <= epsilon (0.5).
		if r["count"] != null and gate_fired_round < 0:
			gate_fired_round = i
	_free_rt(rt)

	var ok := true
	# The load-bearing assertion: d is MONOTONICALLY DECREASING across the converging sequence.
	var monotone := true
	for i in range(1, ds.size()):
		if not (float(ds[i]) < float(ds[i - 1])):
			monotone = false
	ok = _check("CONVERGING: d strictly decreases every round %s" % [ds], monotone) and ok
	# d converges toward the target (last d is below epsilon).
	ok = _check("CONVERGING: final d (%s) <= epsilon 0.5" % [ds[ds.size() - 1] if not ds.is_empty() else "?"],
		not ds.is_empty() and float(ds[ds.size() - 1]) <= 0.5) and ok
	# The gate FIRES (count non-null) at convergence, and NOT before (d was > epsilon on round 0..3).
	ok = _check("CONVERGING: gate fires (count non-null) at convergence round %d" % gate_fired_round,
		gate_fired_round >= 0) and ok
	ok = _check("CONVERGING: gate did NOT fire before convergence (round >= 4)", gate_fired_round >= 4) and ok
	ok = _check("CONVERGING: Iterate Action advanced fixture every round", iterate_ran_every_round) and ok
	return ok

# -- NON-CONVERGING contract: the non-decreasing-d FAILURE signal fires; gate never fires ----------
func _non_converging_contract() -> bool:
	var rt := _load_harness()
	# A sequence that does NOT march toward 0 — d rises again (diverges / oscillates away).
	var seq := [2.0, 1.0, 3.0, 5.0, 8.0]
	var ds := []
	var gate_ever_fired := false
	for i in seq.size():
		var r := _run_round(rt, seq[i])
		ds.append(r["d"])
		if r["count"] != null:
			gate_ever_fired = true
	_free_rt(rt)

	var ok := true
	# The FAILURE signal is that d FAILS to be monotonically decreasing: some round has d[i] >= d[i-1].
	var non_decreasing_failure := false
	for i in range(1, ds.size()):
		if float(ds[i]) >= float(ds[i - 1]):
			non_decreasing_failure = true
	ok = _check("NON-CONVERGING: non-decreasing-d FAILURE signal fires %s" % [ds], non_decreasing_failure) and ok
	# The gate must NEVER fire on the diverging run (it never reached convergence within epsilon).
	ok = _check("NON-CONVERGING: gate never fires (never converged)", not gate_ever_fired) and ok
	return ok

# -- The metric-plugin seam: dict_equality / l2 / abs + the unknown-metric declared sentinel -------
func _metric_plugin_seam() -> bool:
	var ok := true
	# dict_equality: two deep-equal dicts -> 0.0; a differing dict -> 1.0. The parity / state-dict case.
	ok = _check("metric dict_equality: equal dicts => 0",
		_eval_metric("dict_equality", {"a": 1, "b": [2, 3]}, {"a": 1, "b": [2, 3]}) == 0.0) and ok
	ok = _check("metric dict_equality: differing dicts => 1",
		_eval_metric("dict_equality", {"a": 1}, {"a": 2}) == 1.0) and ok
	# l2 over scalars and over arrays.
	ok = _check("metric l2: |3 - 0| == 3", _eval_metric("l2", 3.0, 0.0) == 3.0) and ok
	ok = _check("metric l2: [3,4] vs [0,0] == 5 (3-4-5)", _eval_metric("l2", [3.0, 4.0], [0.0, 0.0]) == 5.0) and ok
	# abs (the 1-D l2).
	ok = _check("metric abs: |7 - 2| == 5", _eval_metric("abs", 7.0, 2.0) == 5.0) and ok
	# UNKNOWN metric = the declared +INF sentinel (portability keystone), never an error/crash.
	ok = _check("metric unknown => +INF declared sentinel (not a crash)",
		_eval_metric("ssim_not_registered_here", 1.0, 2.0) == INF) and ok
	# The registry is inspectable (N-ideal observability: metrics live in DATA, one comparator).
	var probe := PrimCompareDiff.new()
	var names := probe.metrics()
	probe.free()
	ok = _check("metric registry lists dict_equality/l2/abs", names.has("dict_equality") and names.has("l2") and names.has("abs")) and ok
	return ok

## Evaluate CompareDiff with a given metric inside a REAL runtime (candidate/reference are any-typed, so
## they are carried as Const params — Const emits its params.value verbatim, dict or array included).
func _eval_metric(metric: String, candidate, reference):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "c", "type": "Const", "params": { "value": candidate } },
			{ "id": "r", "type": "Const", "params": { "value": reference } },
			{ "id": "d", "type": "CompareDiff", "params": { "metric": metric } },
		],
		"wires": [
			{ "from": "c", "out": "value", "to": "d", "in": "candidate" },
			{ "from": "r", "out": "value", "to": "d", "in": "reference" },
		],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var v = out.get("d", {}).get("d")
	_free_rt(rt)
	return v

## Like _eval_metric but the metric param is passed RAW (untyped) — used by the adversarial cases that
## drive a NON-STRING metric (int / null) through the node exactly as a malformed arrangement would. The
## params dict carries whatever Variant is handed in; str() inside CompareDiff.evaluate() must coerce it.
func _eval_metric_raw(metric, candidate, reference):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "c", "type": "Const", "params": { "value": candidate } },
			{ "id": "r", "type": "Const", "params": { "value": reference } },
			{ "id": "d", "type": "CompareDiff", "params": { "metric": metric } },
		],
		"wires": [
			{ "from": "c", "out": "value", "to": "d", "in": "candidate" },
			{ "from": "r", "out": "value", "to": "d", "in": "reference" },
		],
	}
	rt.load_arrangement(arr)
	var out := rt.evaluate()
	var v = out.get("d", {}).get("d")
	_free_rt(rt)
	return v

# -- ADVERSARIAL ROBUSTNESS: the 3 reproduced defects must be fixed, in the REAL runtime ------------
# Each case is a live GraphRuntime evaluate() (never an isolated call), reading the wired `d` off the
# graph — so a regression re-surfaces here exactly as the verifier reproduced it.
func _adversarial_robustness() -> bool:
	var ok := true

	# BUG 1 — non-string metric must NOT crash evaluate() (String() constructor threw on a non-string).
	# It must resolve via str() to a name that isn't registered -> the declared +INF sentinel, no abort.
	# A crash would make evaluate() return d=<null> instead of +INF; assert we get the sentinel float.
	var d_int = _eval_metric_raw(42, 1.0, 2.0)
	ok = _check("ADV BUG1: non-string metric (int 42) => +INF sentinel, no crash (d=%s)" % [d_int],
		typeof(d_int) == TYPE_FLOAT and d_int == INF) and ok
	var d_null = _eval_metric_raw(null, 1.0, 2.0)
	ok = _check("ADV BUG1: null metric => +INF sentinel, no crash (d=%s)" % [d_null],
		typeof(d_null) == TYPE_FLOAT and d_null == INF) and ok

	# BUG 2 — dict_equality with a Dictionary candidate vs a scalar reference threw "Invalid operands
	# 'Dictionary' and 'float'"; the error was swallowed and it returned 0.0 ("identical") for values that
	# are NOT equal. It must now report NON-EQUAL (1.0), never a false 0.0.
	var d_ds = _eval_metric("dict_equality", {"a": 1}, 5.0)
	ok = _check("ADV BUG2: dict_equality Dictionary-vs-scalar => 1.0 non-equal (not a false 0.0) (d=%s)" % [d_ds],
		float(d_ds) == 1.0) and ok
	# and the symmetric case (scalar candidate vs Dictionary reference) is also non-equal, not a crash.
	var d_sd = _eval_metric("dict_equality", 5.0, {"a": 1})
	ok = _check("ADV BUG2: dict_equality scalar-vs-Dictionary => 1.0 non-equal (symmetric) (d=%s)" % [d_sd],
		float(d_sd) == 1.0) and ok
	# Regression guard: genuinely deep-equal dicts still score 0.0 (the fix didn't break the happy path).
	ok = _check("ADV BUG2: dict_equality still 0.0 for deep-equal dicts (happy path intact)",
		_eval_metric("dict_equality", {"a": [1, 2]}, {"a": [1, 2]}) == 0.0) and ok
	# and a same-shape but differing dict is still 1.0.
	ok = _check("ADV BUG2: dict_equality still 1.0 for same-shape differing dicts",
		_eval_metric("dict_equality", {"a": [1, 2]}, {"a": [1, 9]}) == 1.0) and ok

	# BUG 3 — l2 over RAGGED (mismatched-length) numeric arrays used to fall to as_num(Array)=0 on both
	# sides and return a FALSE 0.0 "identical" for clearly-different ragged arrays. It must now report a
	# large/+INF distance (not a false 0). [1,2,3] vs [0,0] are not componentwise-comparable => +INF.
	var d_ragged = _eval_metric("l2", [1.0, 2.0, 3.0], [0.0, 0.0])
	ok = _check("ADV BUG3: l2 ragged arrays => +INF, NOT a false 0.0 (d=%s)" % [d_ragged],
		typeof(d_ragged) == TYPE_FLOAT and d_ragged == INF and float(d_ragged) != 0.0) and ok
	# shape mismatch (Array vs scalar) is likewise not a false 0.0.
	var d_shape = _eval_metric("l2", [1.0, 2.0], 0.0)
	ok = _check("ADV BUG3: l2 Array-vs-scalar => +INF, not a false 0.0 (d=%s)" % [d_shape],
		typeof(d_shape) == TYPE_FLOAT and d_shape == INF) and ok
	# Regression guard: equal-length arrays still compute the true Euclidean distance (happy path intact).
	ok = _check("ADV BUG3: l2 equal-length arrays still correct ([3,4] vs [0,0] == 5)",
		_eval_metric("l2", [3.0, 4.0], [0.0, 0.0]) == 5.0) and ok

	return ok

# -- D ideal: a candidate hot-load is a DIFF — the SAME CompareDiff instance re-evaluates ----------
func _diff_hotload_same_instance() -> bool:
	var rt := _load_harness()
	var r1 := _run_round(rt, 10.0)
	var diff_inst1: int = rt.nodes.get("diff").get_instance_id()
	var r2 := _run_round(rt, 3.0)
	var diff_inst2: int = rt.nodes.get("diff").get_instance_id()
	_free_rt(rt)
	var ok := true
	ok = _check("D: candidate hotload re-evaluates d (10=>%s then 3=>%s)" % [r1["d"], r2["d"]],
		float(r1["d"]) == 10.0 and float(r2["d"]) == 3.0) and ok
	ok = _check("D: same CompareDiff instance across hotload (diff, not rebuild)",
		diff_inst1 != 0 and diff_inst1 == diff_inst2) and ok
	return ok

# -- C ideal: sever the reference wire => only d changes; the harness keeps running -----------------
func _connection_isolated_failure() -> bool:
	var rt := _load_harness()
	var before := _run_round(rt, 10.0)  # d = |10 - 0| = 10
	# Sever the reference -> diff.reference wire. reference now arrives null -> as_num -> 0.0, so d is
	# unchanged NUMERICALLY here (ref was 0); to make the isolation observable, drive reference off a
	# non-zero Const first, then cut. Re-splice reference=5 so before-cut d = |10-5| = 5, after-cut = 10.
	var arr: Dictionary = rt.arrangement.duplicate(true)
	for n in arr["nodes"]:
		if n["id"] == "reference":
			n["params"] = { "value": 5.0 }
	rt.load_arrangement(arr)
	var out_ref5 := rt.evaluate()
	var d_ref5 = out_ref5.get("diff", {}).get("d")  # |10 - 5| = 5
	var report_ref5 = out_ref5.get("report", {}).get("reply")  # sibling still runs
	# Now sever the reference -> diff wire.
	var cut: Dictionary = rt.arrangement.duplicate(true)
	var kept := []
	for w in cut["wires"]:
		if not (String(w.get("from")) == "reference" and String(w.get("to")) == "diff"):
			kept.append(w)
	cut["wires"] = kept
	rt.load_arrangement(cut)
	var out_cut := rt.evaluate()
	var d_cut = out_cut.get("diff", {}).get("d")  # reference unwired -> 0 -> |10 - 0| = 10
	var report_cut = out_cut.get("report", {}).get("reply")  # UNAFFECTED sibling
	_free_rt(rt)
	var ok := true
	ok = _check("C: with reference=5, d = |10-5| = 5", float(d_ref5) == 5.0) and ok
	ok = _check("C: severing reference wire flips d back to 10 (input died)", float(d_cut) == 10.0) and ok
	ok = _check("C: the Report sibling is UNAFFECTED by the severed wire",
		report_ref5 != null and report_ref5 == report_cut) and ok
	return ok

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
