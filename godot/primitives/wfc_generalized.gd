extends RefCounted
## Generalized PROBABILISTIC wave-function-collapse — the weight-ORACLE generalization of the
## deterministic `wfc` Context handler, implementing (exactly, no further)
## notes/design/generalized_probabilistic_wfc_2026-07-01.md.
##
## The base handler (prim_context.gd `_wfc_collapse`) is ALREADY a weighted collapser whose weight is a
## constant per tile. This module un-hides that weight as an oracle `W(tile, cell, ctx) -> float >= 0`,
## evaluated per (cell, tile) at draw time, in three tiers of one function (design §1.2):
##   T0 "uniform"     — W = the static per-tile weight (the base case).
##   T1 "conditional" — W = a constant selected by the cell's COMMITTED neighbourhood (first matching
##                      rule in declared order wins). "grass is 5x likelier next to grass."
##   T2 "evolving"    — W = a closed, data-only EXPRESSION over generation-state COUNTERS that the
##                      collapse itself writes as cells commit: P(A|B) ∝ f(n_AB) — the spec's exact
##                      example. Static rules are the k=0 / constant-in-the-counters degenerate case.
##
## HARD INVARIANT (mechanized in headless_wfc_prob_test.gd): with every new field absent or trivial
## (mode "uniform", entropy "size", backtrack false) this module reproduces the base handler's output
## BYTE-IDENTICALLY for the same (ruleset, seed) — same observe argmin (domain size, lowest-index
## tie-break), same sorted-domain draw with the same float accumulation order, same single seeded RNG
## drawn once per observe, same AC-3 propagation. Probabilistic does NOT mean non-deterministic: the
## contract "same (ruleset, seed) -> identical grid, every run, every machine" holds for all tiers,
## because the oracle is a pure function of COMMITTED state and the seed determines the commit history
## (design §1.4).
##
## Extended params.wfc fields (ALL optional — design §3.1; a base-case ruleset is a valid instance):
##   "weights": {
##     "mode":  "uniform" (=base) | "conditional" (T1) | "evolving" (T2).  Absent => "uniform"
##              (rules are parsed/validated but IGNORED under "uniform"; weight_expr rules under
##              "conditional" degrade to default_weight with a surfaced warning — §4.6 fail-soft).
##     "rules": [ { "tile": <name>,
##                  "given": { "dir": "right"|"left"|"down"|"up"|"any", "neighbor": <name> },  (optional;
##                          dir = direction FROM the candidate cell TO the required committed neighbour,
##                          matching the adjacency orientation; absent "given" = unconditional rule)
##                  "weight": <number>            (T1: clamped >= 0.000001 — the base clamp, kept for
##                                                 T0/T1 per §2: a static tier never weight-starves)
##                  OR "weight_expr": { op, ... } (T2: may reach 0 — soft quotas; §4.5) } ]
##              First matching rule (declared order) wins; no match => the per-tile base weight.
##     "default_weight": <number>  fallback for a tile with no stated per-tile weight (default 1.0).
##     "min_weight":     <number>  optional floor on T2 expression results (default 0.0). > 0 keeps a
##                                 saturated tile minimally drawable — strict-quota traded for
##                                 guaranteed-fill (§4.5 mitigation b).
##   }
##   "counters": { "<name>": { "track": ..., ... } }  the generation-state tallies T2 expressions read
##              (§3.2). A closed vocabulary — DATA, never code:
##     tile_count    { tile }                    cells committed to `tile` so far.
##     adjacent_pair { a, b, directed=false }    committed a-b adjacencies (counted once per edge when
##                                               its SECOND endpoint commits; directed counts ordered
##                                               occurrences, so a==b edges count twice).
##     region_count  { tile, rect=[x,y,w,h] }    tile_count restricted to a sub-rectangle (rect absent
##                                               => whole grid).
##     run_length    { tile, axis="x"|"y" }      computed AT READ, relative to the cell being weighed:
##                                               the contiguous committed run of `tile` immediately
##                                               adjacent along the axis (both directions, cell itself
##                                               excluded) — DeBroglie's Max-Consecutive as an evolving
##                                               weight (quota over run_length).
##              Counters increment at COMMIT time only and are read-only to the oracle — a pure
##              function of committed state, hence seed-deterministic (§1.4).
##   "entropy": "size" (=base: domain-count argmin) | "weighted" (Shannon over oracle weights, §1.3).
##              Under all-equal weights the weighted argmin EQUALS the size argmin (H = log k is
##              monotonic in k; equal sizes give bit-identical H; ties still break lowest-index).
##   "backtrack": false (=base fail-soft) | true — on a wiped domain, roll back the most recent
##              collapse, exclude the failed tile, redraw (§1.5/§4.1). Exhausting a cell's options
##              pops the frame and blames the parent's choice (depth-first).
##   "backtrack_limit": <int> (default 10000) — hard cap on rollbacks; on exceed the run falls back to
##              fail-soft and reports "exhausted": true. Never hangs (§4.1).
##
## weight_expr — a closed op set folded purely over counters and constants (§3.3). Each node is
## { "op": ..., ...args }:
##   const   { value }                          a static weight.
##   linear  { base, k, counter, cap? }         base + k*counter, optionally min(cap, ·) — positive
##                                              feedback / clustering; cap bounds the §4.2 blow-up.
##   inverse { base, k, counter }               base / (1 + k*counter) — saturation / anti-clustering.
##   quota   { target, counter }                max(0, target - counter) — a soft count cap.
##   sum     { exprs: [...] } / product { exprs: [...] }   combinators.
##   ref     { rule: <index into rules> }       composition; cycles/bad indices degrade to
##                                              default_weight (§4.6, warned at parse where static).
## Authoring footguns (§4.6) are parse-time WARNINGS + fail-soft degradations, never throws:
## undeclared counter -> const(default_weight); unknown op/mode/entropy/track -> base behavior;
## negative expression results clamp to max(0, min_weight).
##
## Extra outputs beyond the base { grid, contradiction, collapses }:
##   "starved":   int  — soft-starvation draws (§4.5): the domain was non-empty (legal by adjacency)
##                       but every oracle weight was 0 (saturated quotas); the cell is filled with the
##                       first sorted name (ugly-but-legal, grid stays complete) and counted here,
##                       DISTINCT from hard contradiction.
##   "exhausted": bool — the backtrack budget ran out and the run fell back to fail-soft (§4.1).

const MIN_POS := 0.000001  # the base handler's positive-weight clamp (prim_context._wfc_tiles)

# --- parsed configuration -------------------------------------------------------------------------
var _w: int = 1
var _h: int = 1
var _adjacency: Dictionary = {}
var _names: Array = []              # tile order as declared (the deterministic tie-break order)
var _base_weight: Dictionary = {}   # tile -> static weight (clamped >= MIN_POS)
var _mode: String = "uniform"
var _rules: Array = []              # normalized rules: { tile, dir?, neighbor?, weight? | expr? }
var _default_weight: float = 1.0
var _min_weight: float = 0.0
var _entropy_mode: String = "size"
var _backtrack: bool = false
var _backtrack_limit: int = 10000
var _counter_defs: Dictionary = {}  # name -> { track, ... }
var _tile_deps: Dictionary = {}     # tile -> Array[counter name] its expr rules reference (transitive)

# --- run state ------------------------------------------------------------------------------------
var _domains: Array = []
var _committed: Array = []          # bool per cell: counted into counters / visible to rule matching
var _counters: Dictionary = {}      # name -> float running tally (committed state only)
var _counter_gen: Dictionary = {}   # name -> int generation stamp (bumped on every change)
var _rng := RandomNumberGenerator.new()
var _collapses: int = 0
var _starved: int = 0
var _contradiction: bool = false
var _exhausted: bool = false
var _trail: Array = []              # backtrack frames (only populated when backtrack=true)
var _track_commits: bool = false
# weighted-entropy dirty-set cache (§4.3): H recomputed only when the cell's domain changed, a
# neighbour committed, or a counter the cell's domain depends on moved since last evaluation.
var _H_val: Array = []
var _H_ok: Array = []
var _H_stamp: Array = []            # per cell: { counter name: gen at compute }

## True iff params.wfc uses ANY of the extended fields — the dispatch seam prim_context.gd reads.
## An extended-but-trivial config (e.g. weights.mode="uniform") routes here and must reproduce the
## base output byte-identically (the subset proof, mechanized in the test).
static func is_generalized(cfg: Dictionary) -> bool:
	for k in ["weights", "counters", "entropy", "backtrack", "backtrack_limit"]:
		if cfg.has(k):
			return true
	return false

## Entry point. `adjacency` arrives PRE-PARSED from prim_context._wfc_adjacency (single source of
## truth for the hard constraints — weights never enter propagation; they bias choice, not legality).
## Tiles are re-read from cfg here (not reusing _wfc_tiles) for exactly one reason: default_weight
## must apply to tiles with NO stated weight, which the base normalization erases; with
## default_weight absent (1.0) this parse is value-identical to _wfc_tiles.
func collapse(cfg: Dictionary, w: int, h: int, adjacency: Dictionary, seed: int) -> Dictionary:
	_w = w
	_h = h
	_adjacency = adjacency
	_parse(cfg)
	return _run(seed)

# --- parse (§3.1 schema; §4.6 fail-soft validation) ------------------------------------------------

func _parse(cfg: Dictionary) -> void:
	var wb: Dictionary = cfg.get("weights") if cfg.get("weights") is Dictionary else {}
	_default_weight = maxf(MIN_POS, Primitive.as_num(wb.get("default_weight", 1.0)))
	_min_weight = maxf(0.0, Primitive.as_num(wb.get("min_weight", 0.0)))
	_mode = String(wb.get("mode", "uniform"))
	if not ["uniform", "conditional", "evolving"].has(_mode):
		push_warning("wfc: unknown weights.mode '%s' -> treated as 'uniform' (fail-soft)" % _mode)
		_mode = "uniform"
	_entropy_mode = String(cfg.get("entropy", "size"))
	if not ["size", "weighted"].has(_entropy_mode):
		push_warning("wfc: unknown entropy '%s' -> treated as 'size' (fail-soft)" % _entropy_mode)
		_entropy_mode = "size"
	_backtrack = bool(cfg.get("backtrack", false))
	_backtrack_limit = maxi(0, int(Primitive.as_num(cfg.get("backtrack_limit", 10000))))
	# tiles: declared order preserved; stated weights keep the base >= MIN_POS clamp.
	_names = []
	_base_weight = {}
	for t in (cfg.get("tiles") if cfg.get("tiles") is Array else []):
		var nm: String
		var wt: float
		if t is Dictionary:
			nm = String((t as Dictionary).get("name", ""))
			var wv = (t as Dictionary).get("weight")
			wt = _default_weight if wv == null else maxf(MIN_POS, Primitive.as_num(wv))
		else:
			nm = String(t)
			wt = _default_weight
		_names.append(nm)
		_base_weight[nm] = wt
	if _names.is_empty():
		_names.append("")
		_base_weight[""] = _default_weight
	# counters (§3.2): a closed track vocabulary; unknown kinds degrade to a fixed-0 counter + warning.
	_counter_defs = {}
	var craw: Dictionary = cfg.get("counters") if cfg.get("counters") is Dictionary else {}
	for cname in craw.keys():
		var d: Dictionary = craw[cname] if craw[cname] is Dictionary else {}
		var track := String(d.get("track", ""))
		if not ["tile_count", "adjacent_pair", "region_count", "run_length"].has(track):
			push_warning("wfc: counter '%s' has unknown track '%s' -> reads as 0 (fail-soft)" % [cname, track])
			track = "none"
		var def := { "track": track }
		match track:
			"tile_count":
				def["tile"] = String(d.get("tile", ""))
			"adjacent_pair":
				def["a"] = String(d.get("a", ""))
				def["b"] = String(d.get("b", ""))
				def["directed"] = bool(d.get("directed", false))
			"region_count":
				def["tile"] = String(d.get("tile", ""))
				var rect = d.get("rect")
				if rect is Array and (rect as Array).size() == 4:
					def["rect"] = [int(Primitive.as_num(rect[0])), int(Primitive.as_num(rect[1])),
						int(Primitive.as_num(rect[2])), int(Primitive.as_num(rect[3]))]
				else:
					def["rect"] = [0, 0, _w, _h]  # absent rect => whole grid (== tile_count)
			"run_length":
				def["tile"] = String(d.get("tile", ""))
				var ax := String(d.get("axis", "x"))
				def["axis"] = ax if ["x", "y"].has(ax) else "x"
		_counter_defs[String(cname)] = def
	# rules: normalized in declared order (first match wins — deterministic).
	_rules = []
	for r in (wb.get("rules") if wb.get("rules") is Array else []):
		if not (r is Dictionary):
			push_warning("wfc: non-dict weight rule skipped (fail-soft)")
			continue
		var rd: Dictionary = r
		var rule := { "tile": String(rd.get("tile", "")) }
		if rd.get("given") is Dictionary:
			var g: Dictionary = rd["given"]
			var dir := String(g.get("dir", "any"))
			if not ["right", "left", "down", "up", "any"].has(dir):
				push_warning("wfc: rule given.dir '%s' unknown -> 'any' (fail-soft)" % dir)
				dir = "any"
			rule["dir"] = dir
			rule["neighbor"] = String(g.get("neighbor", ""))
		if rd.has("weight_expr"):
			if _mode == "conditional":
				# §4.6: a T2 expression under the T1 mode is an authoring mismatch — degrade, warn.
				push_warning("wfc: weight_expr rule under mode 'conditional' -> default_weight (declare mode 'evolving' for T2)")
				rule["weight"] = _default_weight
			else:
				rule["expr"] = _validate_expr(rd.get("weight_expr"))
		elif rd.has("weight"):
			rule["weight"] = maxf(MIN_POS, Primitive.as_num(rd.get("weight")))
		else:
			rule["weight"] = _default_weight
		_rules.append(rule)
	# ref post-pass: a ref to a rule index that doesn't exist is warned once, here (eval also guards).
	for r2 in _rules:
		if r2.has("expr"):
			_warn_bad_refs(r2["expr"])
	# per-tile counter dependencies (transitive through ref/sum/product) for the §4.3 entropy stamps.
	_tile_deps = {}
	for i in _rules.size():
		var rr: Dictionary = _rules[i]
		if not rr.has("expr"):
			continue
		var deps: Array = []
		_collect_deps(rr["expr"], deps, [i])
		var tn := String(rr["tile"])
		if not _tile_deps.has(tn):
			_tile_deps[tn] = []
		for c in deps:
			if not (_tile_deps[tn] as Array).has(c):
				(_tile_deps[tn] as Array).append(c)
	_precheck_quotas()

## Normalize + validate one weight_expr node (§3.3 / §4.6). Always returns a safe, evaluable dict.
func _validate_expr(e) -> Dictionary:
	if not (e is Dictionary):
		push_warning("wfc: weight_expr must be a dict -> const(default_weight) (fail-soft)")
		return { "op": "const", "value": _default_weight }
	var d: Dictionary = e
	var op := String(d.get("op", "const"))
	match op:
		"const":
			return { "op": "const", "value": Primitive.as_num(d.get("value", _default_weight)) }
		"linear", "inverse", "quota":
			var cname := String(d.get("counter", ""))
			if not _counter_defs.has(cname):
				push_warning("wfc: weight_expr references undeclared counter '%s' -> const(default_weight) (fail-soft)" % cname)
				return { "op": "const", "value": _default_weight }
			var out := { "op": op, "counter": cname }
			out["base"] = Primitive.as_num(d.get("base", 1.0))
			out["k"] = Primitive.as_num(d.get("k", 1.0))
			if op == "quota":
				out["target"] = Primitive.as_num(d.get("target", 0.0))
			if d.has("cap"):
				out["cap"] = Primitive.as_num(d.get("cap"))
			return out
		"sum", "product":
			var kids: Array = []
			for c in (d.get("exprs") if d.get("exprs") is Array else []):
				kids.append(_validate_expr(c))
			if kids.is_empty():
				push_warning("wfc: %s weight_expr with no exprs -> const(default_weight) (fail-soft)" % op)
				return { "op": "const", "value": _default_weight }
			return { "op": op, "exprs": kids }
		"ref":
			return { "op": "ref", "rule": int(Primitive.as_num(d.get("rule", -1))) }
	push_warning("wfc: unknown weight_expr op '%s' -> const(default_weight) (fail-soft)" % op)
	return { "op": "const", "value": _default_weight }

func _warn_bad_refs(x: Dictionary) -> void:
	if String(x.get("op")) == "ref":
		var idx := int(x.get("rule", -1))
		if idx < 0 or idx >= _rules.size():
			push_warning("wfc: weight_expr ref to missing rule %d -> default_weight (fail-soft)" % idx)
	for c in x.get("exprs", []):
		_warn_bad_refs(c)

func _collect_deps(x: Dictionary, out: Array, visited: Array) -> void:
	if x.has("counter") and not out.has(x["counter"]):
		out.append(x["counter"])
	for c in x.get("exprs", []):
		_collect_deps(c, out, visited)
	if String(x.get("op")) == "ref":
		var idx := int(x.get("rule", -1))
		if idx >= 0 and idx < _rules.size() and not visited.has(idx):
			visited.append(idx)
			var rr: Dictionary = _rules[idx]
			if rr.has("expr"):
				_collect_deps(rr["expr"], out, visited)

## §4.1 static satisfiability pre-check (the narrow, obviously-impossible case): when EVERY tile's
## weight is an unconditional quota over its own tile_count and the targets sum below the grid area,
## the grid cannot fill within quota — surfaced at parse as a warning (the run still proceeds
## fail-soft and reports starvation).
func _precheck_quotas() -> void:
	if _mode != "evolving" or _names.is_empty():
		return
	var total_target := 0.0
	for nm in _names:
		var found := false
		for r in _rules:
			if String(r["tile"]) != String(nm) or r.has("dir") or not r.has("expr"):
				continue
			var x: Dictionary = r["expr"]
			if String(x.get("op")) != "quota":
				continue
			var cdef: Dictionary = _counter_defs.get(String(x.get("counter")), {})
			if String(cdef.get("track")) == "tile_count" and String(cdef.get("tile")) == String(nm):
				total_target += float(x.get("target", 0.0))
				found = true
				break
		if not found:
			return
	if total_target < float(_w * _h):
		push_warning("wfc: quota targets sum to %s < %d grid cells — unsatisfiable quotas; expect starved soft-fill (§4.1)" % [total_target, _w * _h])

# --- the weight oracle (§1.2) ----------------------------------------------------------------------

## W(tile, cell, ctx). Under "uniform" (or with no rules) this is EXACTLY the base per-tile lookup —
## the degenerate constant the whole design un-hides. First matching rule in declared order wins;
## T1 weights are pre-clamped positive; T2 expression results clamp to max(0, min_weight) — 0 is
## reachable on purpose (soft quotas, §4.5).
func _weight_of(tile: String, cell: int) -> float:
	if _mode != "uniform":
		for i in _rules.size():
			var r: Dictionary = _rules[i]
			if String(r["tile"]) != tile:
				continue
			if not _rule_ctx_match(r, cell):
				continue
			if r.has("expr"):
				return maxf(_min_weight, maxf(0.0, _expr_value(r["expr"], cell, [i])))
			return float(r["weight"])
	return float(_base_weight.get(tile, _default_weight))

## given.dir is the direction FROM the candidate cell TO the required committed neighbour (the same
## orientation the adjacency allow-sets use). "any" matches any of the 4 committed neighbours.
func _rule_ctx_match(r: Dictionary, cell: int) -> bool:
	if not r.has("dir"):
		return true  # unconditional rule
	var want := String(r["neighbor"])
	@warning_ignore("integer_division")
	var cy := cell / _w
	var cx := cell % _w
	for nb in _neighbours(cx, cy):
		var ni: int = nb[0]
		if String(r["dir"]) != "any" and String(nb[1]) != String(r["dir"]):
			continue
		if _committed[ni] and String((_domains[ni] as Array)[0]) == want:
			return true
	return false

## Pure fold over the closed op set (§3.3). `visited` carries rule indices along the current ref
## path — a cycle or bad index degrades to default_weight (§4.6), never recurses forever.
func _expr_value(x: Dictionary, cell: int, visited: Array) -> float:
	match String(x.get("op")):
		"const":
			return float(x.get("value", _default_weight))
		"linear":
			var v: float = float(x["base"]) + float(x["k"]) * _counter_value(String(x["counter"]), cell)
			if x.has("cap"):
				v = minf(float(x["cap"]), v)  # §4.2: bound the positive-feedback blow-up
			return v
		"inverse":
			var den: float = 1.0 + float(x["k"]) * _counter_value(String(x["counter"]), cell)
			return float(x["base"]) / maxf(MIN_POS, den)
		"quota":
			return maxf(0.0, float(x["target"]) - _counter_value(String(x["counter"]), cell))
		"sum":
			var s := 0.0
			for c in x["exprs"]:
				s += _expr_value(c, cell, visited)
			return s
		"product":
			var p := 1.0
			for c in x["exprs"]:
				p *= _expr_value(c, cell, visited)
			return p
		"ref":
			var idx := int(x.get("rule", -1))
			if idx < 0 or idx >= _rules.size() or visited.has(idx):
				return _default_weight  # broken / cyclic composition -> fail-soft (§4.6)
			visited.append(idx)
			var rr: Dictionary = _rules[idx]
			var v2: float = _expr_value(rr["expr"], cell, visited) if rr.has("expr") else float(rr.get("weight", _default_weight))
			visited.pop_back()
			return v2
	return _default_weight

## Committed-state counter read (§3.2). run_length is the one AT-READ kind: it is a property of the
## cell being weighed (the adjacent committed run), not a global tally — still a pure function of
## committed state, so determinism is intact.
func _counter_value(cname: String, cell: int) -> float:
	var def: Dictionary = _counter_defs.get(cname, {})
	if String(def.get("track", "")) == "run_length":
		return float(_run_length_at(cell, String(def.get("tile", "")), String(def.get("axis", "x"))))
	return float(_counters.get(cname, 0.0))

func _run_length_at(cell: int, tile: String, axis: String) -> int:
	@warning_ignore("integer_division")
	var cy := cell / _w
	var cx := cell % _w
	var dx := 1 if axis == "x" else 0
	var dy := 0 if axis == "x" else 1
	var run := 0
	for sgn in [1, -1]:
		var step := int(sgn)
		var x := cx + dx * step
		var y := cy + dy * step
		while x >= 0 and x < _w and y >= 0 and y < _h:
			var i := y * _w + x
			if not _committed[i] or String((_domains[i] as Array)[0]) != tile:
				break
			run += 1
			x += dx * step
			y += dy * step
	return run

# --- observe (§1.3) ---------------------------------------------------------------------------------

func _observe() -> int:
	if _entropy_mode == "size":
		# byte-for-byte the base heuristic (prim_context._wfc_min_entropy_cell)
		var best := -1
		var best_size := 0
		for i in _domains.size():
			var sz: int = (_domains[i] as Array).size()
			if sz > 1 and (best < 0 or sz < best_size):
				best = i
				best_size = sz
		return best
	var bestw := -1
	var best_h := 0.0
	for i in _domains.size():
		if (_domains[i] as Array).size() <= 1:
			continue
		var hv := _entropy_of(i)
		if bestw < 0 or hv < best_h:
			bestw = i
			best_h = hv
	return bestw

## Weighted Shannon entropy over the cell's oracle weights, with the §4.3 dirty-set cache: recomputed
## only when the cell's domain changed, a neighbour committed, or a counter some domain tile's rules
## read has moved (per-counter generation stamps). All-equal weights give H = log(domain size), so the
## argmin (and its lowest-index tie-break) EQUALS the base size heuristic — the §1.3 preservation.
## A fully-starved cell (total weight 0) reports H = 0: maximally determined, collapsed (and
## starved-filled) eagerly rather than left to rot.
func _entropy_of(i: int) -> float:
	if _H_ok[i] and not _stamp_stale(i):
		return _H_val[i]
	var dom: Array = (_domains[i] as Array).duplicate()
	dom.sort()
	var wts: Array = []
	var total := 0.0
	var deps: Dictionary = {}
	for nm in dom:
		var t := String(nm)
		wts.append(_weight_of(t, i))
		total += float(wts[wts.size() - 1])
		for c in _tile_deps.get(t, []):
			deps[c] = _counter_gen.get(c, 0)
	var hv := 0.0
	if total > 0.0:
		for wv in wts:
			var p: float = float(wv) / total
			if p > 0.0:
				hv -= p * log(p)
	_H_val[i] = hv
	_H_ok[i] = true
	_H_stamp[i] = deps
	return hv

func _stamp_stale(i: int) -> bool:
	var st: Dictionary = _H_stamp[i]
	for c in st.keys():
		if _counter_gen.get(c, 0) != st[c]:
			return true
	return false

# --- collapse (the oracle-weighted draw) -------------------------------------------------------------

## The single draw site, generalized (§1.1): identical to the base _wfc_weighted_pick except the
## weight comes from the oracle. Same sorted domain, same accumulation order, same one randf() per
## draw — under uniform weights the floats (and hence the pick) are bit-identical to the base.
## total <= 0 with a NON-empty domain is SOFT STARVATION (§4.5): fill with the first sorted name
## (legal by adjacency — an ugly-but-legal grid beats a hole), count it, draw nothing from the RNG
## (the base path also returns before its draw in this branch, so the streams stay aligned).
func _pick(cell: int, domain: Array) -> String:
	if domain.is_empty():
		return ""
	var sorted := domain.duplicate()
	sorted.sort()
	var wts: Array = []
	var total := 0.0
	for nm in sorted:
		var wv := _weight_of(String(nm), cell)
		wts.append(wv)
		total += wv
	if total <= 0.0:
		_starved += 1
		return String(sorted[0])
	var r := _rng.randf() * total
	var acc := 0.0
	for i in sorted.size():
		acc += float(wts[i])
		if r < acc:
			return String(sorted[i])
	return String(sorted[sorted.size() - 1])

# --- commit sweep + counters (§3.2) ------------------------------------------------------------------

## Commit every newly-decided cell (domain size 1 — whether observed or forced by propagation) in
## ascending index order (deterministic), updating counters exactly once per cell and once per
## adjacency edge (an edge counts when its SECOND endpoint commits). Skipped entirely when nothing
## reads committed state (mode uniform, no counters, size entropy) — the base path's zero-cost
## guarantee (§4.3d).
func _sweep() -> void:
	if not _track_commits:
		return
	for i in _domains.size():
		if _committed[i]:
			continue
		var dom: Array = _domains[i]
		if dom.size() == 1 and String(dom[0]) != "":
			_committed[i] = true
			_on_commit(i, String(dom[0]))

func _on_commit(i: int, tile: String) -> void:
	@warning_ignore("integer_division")
	var cy := i / _w
	var cx := i % _w
	if _entropy_mode == "weighted":
		# the committed-neighbourhood ctx of the 4 neighbours changed -> their cached H is stale
		for nb in _neighbours(cx, cy):
			_H_ok[nb[0]] = false
	for cname in _counter_defs.keys():
		var def: Dictionary = _counter_defs[cname]
		match String(def.get("track")):
			"tile_count":
				if String(def.get("tile")) == tile:
					_counters[cname] = float(_counters.get(cname, 0.0)) + 1.0
					_counter_gen[cname] = int(_counter_gen.get(cname, 0)) + 1
			"region_count":
				if String(def.get("tile")) == tile:
					var rc: Array = def.get("rect", [0, 0, _w, _h])
					if cx >= int(rc[0]) and cx < int(rc[0]) + int(rc[2]) and cy >= int(rc[1]) and cy < int(rc[1]) + int(rc[3]):
						_counters[cname] = float(_counters.get(cname, 0.0)) + 1.0
						_counter_gen[cname] = int(_counter_gen.get(cname, 0)) + 1
			"run_length":
				# value is computed at read; the stamp still moves so weighted-entropy caches that
				# depend on it are conservatively re-derived (a commit can extend a distant run).
				if String(def.get("tile")) == tile:
					_counter_gen[cname] = int(_counter_gen.get(cname, 0)) + 1
			"adjacent_pair":
				var a := String(def.get("a"))
				var b := String(def.get("b"))
				var inc := 0
				for nb in _neighbours(cx, cy):
					var ni: int = nb[0]
					if not _committed[ni] or ni == i:
						continue
					var other := String((_domains[ni] as Array)[0])
					if bool(def.get("directed", false)):
						# ordered occurrences: (this, other) and (other, this) each count when they
						# match (a, b) — so a==b edges count twice, a!=b edges once.
						if tile == a and other == b:
							inc += 1
						if other == a and tile == b:
							inc += 1
					elif (tile == a and other == b) or (tile == b and other == a):
						inc += 1
				if inc > 0:
					_counters[cname] = float(_counters.get(cname, 0.0)) + float(inc)
					_counter_gen[cname] = int(_counter_gen.get(cname, 0)) + 1

# --- propagate (unchanged semantics; weights never enter legality) -----------------------------------

## Verbatim the base AC-3 wave (prim_context._wfc_propagate) plus weighted-entropy cache invalidation
## on every domain change. Hard adjacency is the ONLY thing that eliminates tiles — a 0-weight tile
## stays in the domain (legal, never drawn), which is what makes starvation soft (§4.5).
func _propagate(start: int) -> bool:
	var queue := [start]
	var ok := true
	while not queue.is_empty():
		var ci: int = queue.pop_back()
		@warning_ignore("integer_division")
		var cy := ci / _w
		var cx := ci % _w
		for nb in _neighbours(cx, cy):
			var ni: int = nb[0]
			var dir: String = nb[1]
			var allowed := {}
			for src_tile in _domains[ci]:
				var per: Dictionary = (_adjacency[dir] as Dictionary).get(String(src_tile), {})
				for at in per.keys():
					allowed[String(at)] = true
			var kept := []
			for nt in _domains[ni]:
				if allowed.has(String(nt)):
					kept.append(nt)
			if kept.size() != (_domains[ni] as Array).size():
				_domains[ni] = kept
				if _entropy_mode == "weighted":
					_H_ok[ni] = false
				if kept.is_empty():
					ok = false
				else:
					queue.append(ni)
	return ok

func _neighbours(x: int, y: int) -> Array:
	var out := []
	if x + 1 < _w:
		out.append([y * _w + (x + 1), "right"])
	if x - 1 >= 0:
		out.append([y * _w + (x - 1), "left"])
	if y + 1 < _h:
		out.append([(y + 1) * _w + x, "down"])
	if y - 1 >= 0:
		out.append([(y - 1) * _w + x, "up"])
	return out

# --- backtracking (§1.5 / §4.1, opt-in) ---------------------------------------------------------------

func _snapshot(cell: int) -> Dictionary:
	var doms := []
	for d in _domains:
		doms.append((d as Array).duplicate())
	return {
		"cell": cell, "tried": [], "applied": "",
		"domains": doms,
		"committed": _committed.duplicate(),
		"counters": _counters.duplicate(),
		"gens": _counter_gen.duplicate(),
		"collapses": _collapses, "starved": _starved,
	}

func _restore(fr: Dictionary) -> void:
	_domains = []
	for d in fr["domains"]:
		_domains.append((d as Array).duplicate())
	_committed = (fr["committed"] as Array).duplicate()
	_counters = (fr["counters"] as Dictionary).duplicate()
	_counter_gen = (fr["gens"] as Dictionary).duplicate()
	_collapses = int(fr["collapses"])
	_starved = int(fr["starved"])
	if _entropy_mode == "weighted":
		for i in _H_ok.size():
			_H_ok[i] = false  # rollback is rare; a full invalidation is the simple-correct choice

# --- the run loop -------------------------------------------------------------------------------------

func _run(seed: int) -> Dictionary:
	var n := _w * _h
	_domains = []
	_committed = []
	for i in n:
		_domains.append(_names.duplicate())
		_committed.append(false)
	_counters = {}
	_counter_gen = {}
	for cname in _counter_defs.keys():
		_counters[cname] = 0.0
		_counter_gen[cname] = 0
	if _entropy_mode == "weighted":
		_H_val.resize(n)
		_H_ok.resize(n)
		_H_stamp.resize(n)
		for i in n:
			_H_val[i] = 0.0
			_H_ok[i] = false
			_H_stamp[i] = {}
	_rng = RandomNumberGenerator.new()
	_rng.seed = seed
	_collapses = 0
	_starved = 0
	_contradiction = false
	_exhausted = false
	_trail = []
	_track_commits = _mode != "uniform" or not _counter_defs.is_empty() or _entropy_mode == "weighted"
	var budget := _backtrack_limit
	var backtracking := _backtrack
	# Termination guard: every iteration either decides a cell (<= n of those) or consumes backtrack
	# budget (<= backtrack_limit of those); the cap is belt-and-braces against both (§4.1: never hang).
	var guard := 2 * n + _backtrack_limit + 8
	while guard > 0:
		guard -= 1
		var ci := _observe()
		if ci < 0:
			break  # every cell decided
		var chosen := _pick(ci, _domains[ci])
		if backtracking:
			var fr0 := _snapshot(ci)
			fr0["applied"] = chosen
			_trail.append(fr0)
		_apply(ci, chosen)
		if _propagate(ci):
			_sweep()
			continue
		if not backtracking:
			# base fail-soft: flag, leave the wiped domain(s) empty, keep going (byte-identical path)
			_contradiction = true
			_sweep()
			continue
		# ---- rollback-and-redraw (§4.1): restore the most recent frame, blame its applied tile,
		# redraw from what remains; an exhausted frame pops and blames its parent's choice. ----
		var repaired := false
		while not repaired:
			if _trail.is_empty():
				# root exhausted: genuinely unsatisfiable from the start -> fail-soft onward
				_contradiction = true
				backtracking = false
				break
			if budget <= 0:
				# §4.1: budget exceeded -> restore a consistent pre-failure state, fall back to
				# fail-soft, report exhausted. Never hang.
				_restore(_trail.back())
				_exhausted = true
				_contradiction = true
				backtracking = false
				break
			budget -= 1
			var fr: Dictionary = _trail.back()
			_restore(fr)
			(fr["tried"] as Array).append(fr["applied"])
			var cand: Array = (_domains[fr["cell"]] as Array).duplicate()
			for t in fr["tried"]:
				cand.erase(t)
			if cand.is_empty():
				_trail.pop_back()
				continue
			var redraw := _pick(int(fr["cell"]), cand)
			fr["applied"] = redraw
			_apply(int(fr["cell"]), redraw)
			if _propagate(int(fr["cell"])):
				_sweep()
				repaired = true
	# materialize: a decided cell shows its tile; an undecided/wiped cell shows "" (identical to base)
	var grid := []
	for y in _h:
		var row := []
		for x in _w:
			var dom: Array = _domains[y * _w + x]
			row.append(String(dom[0]) if dom.size() == 1 else "")
		grid.append(row)
	return {
		"grid": grid, "contradiction": _contradiction, "collapses": _collapses,
		"starved": _starved, "exhausted": _exhausted,
	}

func _apply(cell: int, chosen: String) -> void:
	_domains[cell] = [chosen] if chosen != "" else []
	if chosen == "":
		_contradiction = true
	else:
		_collapses += 1
	if _entropy_mode == "weighted":
		_H_ok[cell] = false
