extends SceneTree
## Headless proof of the GENERALIZED PROBABILISTIC wfc engine (primitives/wfc_generalized.gd — the
## weight-oracle generalization of the deterministic `wfc` Context handler, per
## notes/design/generalized_probabilistic_wfc_2026-07-01.md). The contract proven here:
##   1. BASE-CASE EQUIVALENCE (the hard invariant): with uniform/static weights the generalized path
##      emits the BYTE-IDENTICAL grid/contradiction/collapses the base handler emits for the same
##      (ruleset, seed) — across several rulesets, seeds, and grid sizes; weighted entropy under
##      all-equal weights equals the size heuristic; mode absent => rules ignored (T0).
##   2. WEIGHTED BEHAVIOUR: 3:1 static weights converge near a 0.75 tile frequency (seeded,
##      tolerance-banded); a T1 conditional rule measurably biases adjacency structure.
##   3. EVOLVING DISTRIBUTIONS (T2): a tile_count quota (scarcity — weight falls as instances are
##      placed) measurably changes the distribution vs static weights AND respects its cap; the
##      spec's exact example P(A|B) ∝ f(n_AB) produces clustering under linear feedback and
##      anti-clustering under inverse; a run_length quota bounds max consecutive runs; all of it
##      SEED-DETERMINISTIC (two runs, identical output).
##   4. CONTRADICTION / CONVERGENCE: fail-soft is preserved under evolving weights; soft STARVATION
##      (all weights 0, domain legal) fills the grid and is counted distinctly; min_weight floors it
##      away; opt-in BACKTRACKING repairs a fail-soft contradiction, terminates on unsatisfiable
##      rulesets (never hangs), and reports `exhausted` when the budget runs out.
##   5. PERF: measured timings for base vs generalized-uniform (overhead) and a T2+weighted-entropy
##      run on larger grids — printed for the record, sanity-capped.
##
##   godot --headless --path godot -s res://headless_wfc_prob_test.gd
##
## Mirrors headless_wfc_test.gd style (PASS/FAIL, RESULT, non-zero exit). The base suite
## (headless_wfc_test.gd) must still pass verbatim beside this one — that is the subset proof's
## other half.

func _initialize() -> void:
	var ok := true

	# ---- rulesets --------------------------------------------------------------------------------
	var stripes := {
		"width": 4, "height": 3, "tiles": ["A", "B"],
		"adjacency": { "right": { "A": ["B"], "B": ["A"] } },
	}
	var open2 := { "width": 4, "height": 3, "tiles": ["A", "B"], "adjacency": {} }
	var open3 := { "width": 8, "height": 8, "tiles": ["A", "B", "C"], "adjacency": {} }
	var weighted31 := { "width": 6, "height": 6,
		"tiles": [ { "name": "A", "weight": 3.0 }, { "name": "B", "weight": 1.0 } ], "adjacency": {} }
	var open8 := { "width": 8, "height": 8, "tiles": ["A", "B"], "adjacency": {} }
	var open12 := { "width": 12, "height": 12, "tiles": ["A", "B"], "adjacency": {} }
	var seeds := [0, 1, 7, 42, 123]

	# ---- (1) BASE-CASE EQUIVALENCE (the hard invariant, mechanized) -------------------------------
	var eq_ok := true
	for rs in [stripes, open2, open3, weighted31]:
		for s in seeds:
			var base := _outs(rs, s)
			var gen := _outs(_ext(rs, { "weights": { "mode": "uniform" } }), s)
			if base.get("grid") != gen.get("grid") \
					or base.get("contradiction") != gen.get("contradiction") \
					or base.get("collapses") != gen.get("collapses"):
				eq_ok = false
	ok = _check("prob-wfc 1a: generalized path with uniform/static weights is BYTE-IDENTICAL to the base handler (4 rulesets x 5 seeds, incl. 3:1 static per-tile weights)", eq_ok) and ok

	var went_ok := true
	for rs2 in [stripes, open2, open3]:
		for s2 in seeds:
			if _outs(rs2, s2).get("grid") != _outs(_ext(rs2, { "entropy": "weighted" }), s2).get("grid"):
				went_ok = false
	ok = _check("prob-wfc 1b: entropy='weighted' equals the size heuristic under all-equal weights (3 rulesets x 5 seeds)", went_ok) and ok

	# mode ABSENT means uniform: a rules block without a mode is ignored (T0) — the least-surprising
	# reading of the schema's "Absent => uniform".
	var noderule := _ext(open2, { "weights": { "rules": [
		{ "tile": "A", "given": { "dir": "any", "neighbor": "A" }, "weight": 99.0 } ] } })
	ok = _check("prob-wfc 1c: weights.mode absent => 'uniform' (rules ignored; base-identical grid)", _outs(open2, 7).get("grid") == _outs(noderule, 7).get("grid")) and ok

	var trivial := _outs(_ext(open2, { "weights": { "mode": "uniform" } }), 7)
	ok = _check("prob-wfc 1d: trivial generalized run reports starved=0 / exhausted=false", int(trivial.get("starved")) == 0 and trivial.get("exhausted") == false) and ok
	var base_ports := _outs(open2, 7)
	ok = _check("prob-wfc 1e: base path emits 0 / false defaults on the new starved/exhausted ports", int(base_ports.get("starved")) == 0 and base_ports.get("exhausted") == false) and ok

	# ---- (2) WEIGHTED BEHAVIOUR (static ratios) ----------------------------------------------------
	var big31 := { "width": 20, "height": 20,
		"tiles": [ { "name": "A", "weight": 3.0 }, { "name": "B", "weight": 1.0 } ], "adjacency": {},
		"weights": { "mode": "uniform" } }
	var n_a := 0
	for s3 in [11, 22, 33]:
		n_a += _count_tile(_grid(big31, s3), "A")
	var freq := float(n_a) / 1200.0
	ok = _check("prob-wfc 2a: 3:1 static weights -> pooled frequency(A) in [0.70, 0.80] (got %.4f over 1200 cells, 3 seeds)" % freq, freq >= 0.70 and freq <= 0.80) and ok

	var t1cfg := _ext(open12, { "weights": { "mode": "conditional", "rules": [
		{ "tile": "A", "given": { "dir": "any", "neighbor": "A" }, "weight": 8.0 } ] } })
	var pairs_rule := 0
	var pairs_base := 0
	for s4 in [3, 4, 5]:
		pairs_rule += _count_pairs(_grid(t1cfg, s4), "A", "A")
		pairs_base += _count_pairs(_grid(open12, s4), "A", "A")
	ok = _check("prob-wfc 2b: T1 conditional rule (A 8x likelier beside committed A) raises A-A adjacencies (%d > %d, 3 seeds)" % [pairs_rule, pairs_base], pairs_rule > pairs_base) and ok

	# ---- (3) EVOLVING DISTRIBUTIONS (T2) -----------------------------------------------------------
	# (a) scarcity via tile_count quota: the weight of A falls to 0 as instances are placed.
	var quota_cfg := _ext(open8, {
		"counters": { "nA": { "track": "tile_count", "tile": "A" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "weight_expr": { "op": "quota", "target": 10, "counter": "nA" } } ] } })
	var q_out := _outs(quota_cfg, 9)
	var q_a := _count_tile(q_out.get("grid"), "A")
	var q_base := _count_tile(_grid(open8, 9), "A")
	ok = _check("prob-wfc 3a: tile_count quota holds — count(A) <= 10 (got %d; static baseline %d) on 64 cells" % [q_a, q_base], q_a <= 10 and q_a < q_base) and ok
	ok = _check("prob-wfc 3b: the quota fills toward its target (count(A) >= 8) and the grid completes cleanly", q_a >= 8 and q_out.get("contradiction") == false and _full(q_out.get("grid"))) and ok

	# (b) the spec's exact example: P(A next to B) ∝ f(n_AB) — linear feedback clusters.
	var pair_cfg := _ext(open12, {
		"counters": { "pAB": { "track": "adjacent_pair", "a": "A", "b": "B" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "given": { "dir": "any", "neighbor": "B" },
			  "weight_expr": { "op": "linear", "base": 1.0, "k": 1.0, "cap": 10.0, "counter": "pAB" } } ] } })
	var ab_evo := 0
	var ab_base := 0
	for s5 in [5, 6, 7]:
		ab_evo += _count_pairs(_grid(pair_cfg, s5), "A", "B")
		ab_base += _count_pairs(_grid(open12, s5), "A", "B")
	ok = _check("prob-wfc 3c: linear pair feedback (P(A|B) ∝ 1 + n_AB, cap 10) RAISES A-B adjacencies (%d > %d, 3 seeds)" % [ab_evo, ab_base], ab_evo > ab_base) and ok

	# (c) inverse feedback anti-clusters (saturation).
	var anti_cfg := _ext(open12, {
		"counters": { "pAB": { "track": "adjacent_pair", "a": "A", "b": "B" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "given": { "dir": "any", "neighbor": "B" },
			  "weight_expr": { "op": "inverse", "base": 1.0, "k": 0.5, "counter": "pAB" } } ] } })
	var ab_anti := 0
	for s6 in [5, 6, 7]:
		ab_anti += _count_pairs(_grid(anti_cfg, s6), "A", "B")
	ok = _check("prob-wfc 3d: inverse pair feedback (saturation) LOWERS A-B adjacencies (%d < %d, 3 seeds)" % [ab_anti, ab_base], ab_anti < ab_base) and ok

	# (d) determinism regression under evolving weights (design §4.4): same seed twice -> identical.
	ok = _check("prob-wfc 3e: T2 evolving run is seed-deterministic (two runs, byte-identical grids)", _grid(pair_cfg, 6) == _grid(pair_cfg, 6)) and ok

	# (e) run_length quota = Max-Consecutive as an evolving weight: no horizontal A-run exceeds 3.
	var run_cfg := _ext(open12, {
		"counters": { "runA": { "track": "run_length", "tile": "A", "axis": "x" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "weight_expr": { "op": "quota", "target": 3, "counter": "runA" } } ] } })
	var maxrun := 0
	for s7 in [1, 2]:
		maxrun = maxi(maxrun, _max_run_x(_grid(run_cfg, s7), "A"))
	ok = _check("prob-wfc 3f: run_length quota bounds max consecutive A per row to 3 (got %d, 2 seeds)" % maxrun, maxrun <= 3 and maxrun >= 1) and ok

	# ---- (4) CONTRADICTION / CONVERGENCE -----------------------------------------------------------
	# (a) fail-soft preserved with T2 fields active: an over-constrained ruleset REPORTS, never throws.
	var impossible := { "width": 3, "height": 1, "tiles": ["X", "Y"],
		"adjacency": { "right": { "X": ["Z"], "Y": ["Z"] } } }
	var imp_t2 := _ext(impossible, {
		"counters": { "nX": { "track": "tile_count", "tile": "X" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "X", "weight_expr": { "op": "quota", "target": 2, "counter": "nX" } } ] } })
	var io := _outs(imp_t2, 1)
	ok = _check("prob-wfc 4a: over-constrained + evolving weights -> contradiction REPORTED, grid still emitted (fail-soft preserved)", io.get("contradiction") == true and (io.get("grid") as Array).size() == 1) and ok

	# (b) soft STARVATION: both tiles quota'd below the cell count -> weights all hit 0, the grid
	# still fills (first-sorted-name fallback), and `starved` counts it distinctly from contradiction.
	var starve_cfg := { "width": 4, "height": 4, "tiles": ["A", "B"], "adjacency": {},
		"counters": { "nA": { "track": "tile_count", "tile": "A" }, "nB": { "track": "tile_count", "tile": "B" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "weight_expr": { "op": "quota", "target": 5, "counter": "nA" } },
			{ "tile": "B", "weight_expr": { "op": "quota", "target": 5, "counter": "nB" } } ] } }
	var so := _outs(starve_cfg, 2)
	ok = _check("prob-wfc 4b: unsatisfiable quotas (5+5 < 16 cells) -> starved=%d > 0, grid FULLY filled, contradiction=false" % int(so.get("starved")), int(so.get("starved")) > 0 and _full(so.get("grid")) and so.get("contradiction") == false) and ok

	# (c) min_weight floors starvation away (guaranteed-fill traded for strict quota, §4.5b).
	var floor_cfg: Dictionary = starve_cfg.duplicate(true)
	(floor_cfg["weights"] as Dictionary)["min_weight"] = 0.001
	var fo := _outs(floor_cfg, 2)
	ok = _check("prob-wfc 4c: min_weight floor keeps saturated tiles drawable -> starved=0, grid full", int(fo.get("starved")) == 0 and _full(fo.get("grid"))) and ok

	# (d) BACKTRACKING repairs what fail-soft cannot: a chain ruleset (a->b->c, right) is satisfiable
	# ONLY as [a,b,c], so any seed whose first draw is b or c contradicts fail-soft; with
	# backtrack=true the same seed rolls back, excludes the failed tile, and lands the valid grid.
	var chain := { "width": 3, "height": 1, "tiles": ["a", "b", "c"],
		"adjacency": { "right": { "a": ["b"], "b": ["c"] } } }
	var found_fail := 0
	var repaired := 0
	for s8 in range(0, 20):
		if _outs(chain, s8).get("contradiction") == true:
			found_fail += 1
			var bo := _outs(_ext(chain, { "backtrack": true }), s8)
			if bo.get("contradiction") == false and bo.get("grid") == [["a", "b", "c"]] and bo.get("exhausted") == false:
				repaired += 1
	ok = _check("prob-wfc 4d: backtracking repairs every fail-soft contradiction of the chain ruleset (%d found in 20 seeds, %d repaired)" % [found_fail, repaired], found_fail >= 1 and repaired == found_fail) and ok

	# (e) an UNSATISFIABLE ruleset with backtracking terminates (never hangs): root exhaustion falls
	# back to fail-soft; a tiny budget trips the `exhausted` flag (§4.1's livelock cap).
	var imp_bt := _ext(impossible, { "backtrack": true, "backtrack_limit": 50 })
	var bt_out := _outs(imp_bt, 1)
	ok = _check("prob-wfc 4e: impossible + backtrack -> terminates, contradiction reported (root exhausted, no hang)", bt_out.get("contradiction") == true) and ok
	var imp_bt1 := _ext(impossible, { "backtrack": true, "backtrack_limit": 1 })
	var bt1_out := _outs(imp_bt1, 1)
	ok = _check("prob-wfc 4f: backtrack_limit exceeded -> exhausted=true + fail-soft fallback (contradiction=true)", bt1_out.get("exhausted") == true and bt1_out.get("contradiction") == true) and ok

	# (f) authoring footguns fail SOFT (§4.6): an undeclared counter degrades to default_weight
	# (warned), so the run behaves like the static base — never a crash.
	var bad_cfg := _ext(open2, { "weights": { "mode": "evolving", "rules": [
		{ "tile": "A", "weight_expr": { "op": "linear", "base": 1.0, "k": 5.0, "counter": "NOPE" } } ] } })
	ok = _check("prob-wfc 4g: undeclared counter in weight_expr degrades to the base grid (warned, fail-soft)", _grid(bad_cfg, 7) == _grid(open2, 7)) and ok

	# ---- (5) PERF (measured; printed for the record, sanity-capped) --------------------------------
	var open30 := { "width": 30, "height": 30, "tiles": ["A", "B"], "adjacency": {} }
	var open50 := { "width": 50, "height": 50, "tiles": ["A", "B"], "adjacency": {} }
	var t0 := Time.get_ticks_msec()
	_grid(open30, 7)
	var t_base30 := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	_grid(_ext(open30, { "weights": { "mode": "uniform" } }), 7)
	var t_gen30 := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	_grid(open50, 7)
	var t_base50 := Time.get_ticks_msec() - t0
	t0 = Time.get_ticks_msec()
	_grid(_ext(open50, { "weights": { "mode": "uniform" } }), 7)
	var t_gen50 := Time.get_ticks_msec() - t0
	var t2_30 := _ext(open30, {
		"entropy": "weighted",
		"counters": { "pAB": { "track": "adjacent_pair", "a": "A", "b": "B" } },
		"weights": { "mode": "evolving", "rules": [
			{ "tile": "A", "given": { "dir": "any", "neighbor": "B" },
			  "weight_expr": { "op": "linear", "base": 1.0, "k": 0.2, "cap": 6.0, "counter": "pAB" } } ] } })
	t0 = Time.get_ticks_msec()
	_grid(t2_30, 7)
	var t_t2_30 := Time.get_ticks_msec() - t0
	print("PERF wfc 30x30 base=%dms generalized-uniform=%dms | 50x50 base=%dms generalized-uniform=%dms | 30x30 T2+weighted-entropy=%dms" % [t_base30, t_gen30, t_base50, t_gen50, t_t2_30])
	ok = _check("prob-wfc 5: perf sanity — every measured run under 60s", t_base30 < 60000 and t_gen30 < 60000 and t_base50 < 60000 and t_gen50 < 60000 and t_t2_30 < 60000) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# arrangement builders + drivers (mirrors headless_wfc_test.gd)
# ---------------------------------------------------------------------------------------------------

## Shallow-extend a base ruleset with extra top-level params.wfc fields (deep-duplicated first).
func _ext(base: Dictionary, extra: Dictionary) -> Dictionary:
	var out: Dictionary = base.duplicate(true)
	for k in extra.keys():
		out[k] = extra[k]
	return out

func _wfc_arr(ruleset: Dictionary, outputs: Array) -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": {
				"handler": "wfc", "wfc": ruleset,
				"ports": { "inputs": [], "outputs": outputs } } },
			{ "id": "s", "type": "Const", "params": { "value": 0 } },
		],
		"wires": [
			{ "from": "s", "out": "value", "to": "ctx", "in": "seed" },
		],
	}

func _ports5() -> Array:
	return [{ "name": "grid" }, { "name": "contradiction" }, { "name": "collapses" },
		{ "name": "starved" }, { "name": "exhausted" }]

func _eval_outputs(arr_template: Dictionary, seed: int) -> Dictionary:
	var arr: Dictionary = arr_template.duplicate(true)
	for n in arr.get("nodes", []):
		if String(n.get("id")) == "s":
			n["params"]["value"] = seed
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	var outs := rt.evaluate()
	var ctx_out: Dictionary = outs.get("ctx", {})
	get_root().remove_child(rt)
	rt.free()
	return ctx_out

## Full output dict (grid/contradiction/collapses/starved/exhausted) for a ruleset+seed.
func _outs(ruleset: Dictionary, seed: int) -> Dictionary:
	return _eval_outputs(_wfc_arr(ruleset, _ports5()), seed)

func _grid(ruleset: Dictionary, seed: int) -> Array:
	var g = _outs(ruleset, seed).get("grid")
	return g if g is Array else []

# ---------------------------------------------------------------------------------------------------
# grid analysers
# ---------------------------------------------------------------------------------------------------

func _count_tile(grid: Array, tile: String) -> int:
	var cnt := 0
	for row in grid:
		for cell in row:
			if String(cell) == tile:
				cnt += 1
	return cnt

## Count 4-neighbourhood adjacencies between tiles a and b (each edge once; a==b edges once).
func _count_pairs(grid: Array, a: String, b: String) -> int:
	var cnt := 0
	for y in grid.size():
		var row: Array = grid[y]
		for x in row.size():
			var t := String(row[x])
			if x + 1 < row.size():
				var t2 := String(row[x + 1])
				if (t == a and t2 == b) or (t == b and t2 == a):
					cnt += 1
			if y + 1 < grid.size():
				var t3 := String((grid[y + 1] as Array)[x])
				if (t == a and t3 == b) or (t == b and t3 == a):
					cnt += 1
	return cnt

func _full(grid) -> bool:
	if not (grid is Array) or (grid as Array).is_empty():
		return false
	for row in grid:
		for cell in row:
			if String(cell) == "":
				return false
	return true

func _max_run_x(grid: Array, tile: String) -> int:
	var best := 0
	for row in grid:
		var run := 0
		for cell in row:
			if String(cell) == tile:
				run += 1
				best = maxi(best, run)
			else:
				run = 0
	return best

# ---------------------------------------------------------------------------------------------------
func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
