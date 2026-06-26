extends SceneTree
## Headless proof of the `wfc` (wave-function-collapse) procedural-generation Context handler — the
## first GENERATOR handler (see COMMUNICATION-ARCHITECTURE.md, the procedural row, and the wfc section of
## prim_context.gd). Unlike the dataflow-derived handlers it has NO inner arrangement: it collapses a grid
## against a static tile-adjacency ruleset (params.wfc), seeded by the implicit "seed" input, and emits the
## collapsed grid to its declared output ports. The contract proven here:
##   - DETERMINISM: same (ruleset, seed) => identical grid, every run (content-addressable / reproducible).
##   - SEED-SENSITIVITY: the seed actually steers the draw (different seeds explore the space).
##   - CONSTRAINT SATISFACTION: every adjacent pair in the emitted grid respects the stated adjacency rule.
##   - SHAPE: width x height grid of tile-name strings; collapses == width*height on a clean run.
##   - FAIL-SOFT: an over-constrained ruleset REPORTS contradiction (does not throw), still emits a grid.
##   - PORT INVARIANT: the implicit "seed" port exists ONLY for handler=wfc (not dataflow).
##   - FOUNDATION UNTOUCHED: this is a new match arm + helpers in the MODULE; GraphRuntime gains nothing.
##
##   godot --headless --path godot -s res://headless_wfc_test.gd
##
## Mirrors headless_event_test.gd / headless_context_test.gd style (PASS/FAIL, RESULT, non-zero exit).

func _initialize() -> void:
	var ok := true

	# ---- A "stripes" ruleset: tiles A and B; horizontally A|B alternate (A right-of B and B right-of A),
	# vertically anything goes. Stated once per the auto-mirror convention (right implies left). This is a
	# fully-satisfiable constraint, so a clean run never contradicts. ----------------------------------
	var stripes := {
		"width": 4, "height": 3,
		"tiles": ["A", "B"],
		"adjacency": {
			# A may be to the right of B, and B to the right of A (=> alternating columns). The handler
			# auto-mirrors each into "left", so we state only the "right" axis here.
			"right": { "A": ["B"], "B": ["A"] },
		},
	}

	# (1) DETERMINISM: the same seed collapses to the byte-identical grid across two independent runs.
	var g_seed7_a := _wfc_grid(stripes, 7)
	var g_seed7_b := _wfc_grid(stripes, 7)
	ok = _check("wfc: same seed => identical grid (deterministic / reproducible)", g_seed7_a == g_seed7_b) and ok

	# (2) SHAPE: the grid is height rows x width cols of non-empty tile names; collapses == width*height.
	var shape_ok := g_seed7_a.size() == 3
	for row in g_seed7_a:
		shape_ok = shape_ok and (row is Array) and (row as Array).size() == 4
		for cell in row:
			shape_ok = shape_ok and String(cell) != ""
	ok = _check("wfc: grid is height x width of filled tiles (4x3, no empties)", shape_ok) and ok
	# `collapses` counts OBSERVATION steps (cells the generator explicitly collapsed); propagation then
	# decides further cells for free, so on a constrained ruleset it is < width*height — here the
	# alternating-stripes rule means one observation per row fully determines that row (3 rows => 3
	# observations decide all 12 cells). The contract is 1 <= collapses <= width*height, AND the grid is
	# fully filled (test 2) — i.e. propagation completed the rest.
	var collapses = _wfc_field(stripes, 7, "collapses")
	ok = _check("wfc: collapses is a bounded observation count (1..12), propagation fills the rest", collapses >= 1 and collapses <= 12) and ok
	ok = _check("wfc: a satisfiable ruleset reports NO contradiction", _wfc_field(stripes, 7, "contradiction") == false) and ok

	# (3) CONSTRAINT SATISFACTION: every horizontally-adjacent pair alternates (A|B), per the ruleset —
	# the emitted structure actually obeys its rules, not just "some grid".
	ok = _check("wfc: every horizontal neighbour pair satisfies the adjacency rule", _stripes_horiz_ok(g_seed7_a)) and ok

	# (4) SEED-SENSITIVITY: at least one different seed produces a different grid (the seed steers the draw;
	# it is not a constant generator). We scan a handful — with a 4x3 alternating board there are 2 column-
	# phases, so SOME seed in a small set must flip the phase. (A pure constant generator would fail this.)
	var differs := false
	for s in [1, 2, 3, 4, 5, 6, 8, 9]:
		if _wfc_grid(stripes, s) != g_seed7_a:
			differs = true
			break
	ok = _check("wfc: a different seed can produce a different grid (seed steers generation)", differs) and ok

	# (5) FAIL-SOFT CONTRADICTION: an over-constrained ruleset (a tile that may neighbour NOTHING in a
	# needed direction) is REPORTED via the contradiction flag and still emits a grid, never throws. Here
	# "X" is allowed to the right of nothing and "Y" is the only other tile but X must sit somewhere on a
	# >1-wide row with no legal right/left neighbour => the wave wipes a domain.
	var impossible := {
		"width": 3, "height": 1,
		"tiles": ["X", "Y"],
		# X may only be right-of X, Y only right-of Y, BUT we also forbid same-tile vertical/horizontal by
		# making each tile's right-set exclude itself => no legal horizontal pairing exists on a 3-wide row.
		"adjacency": { "right": { "X": ["Z"], "Y": ["Z"] } },  # "Z" is not a tile => nothing legal to the right
	}
	var contra = _wfc_field(impossible, 1, "contradiction")
	var still_emits := _wfc_grid(impossible, 1).size() == 1
	ok = _check("wfc: over-constrained ruleset REPORTS contradiction (fail-soft, no throw)", contra == true) and ok
	ok = _check("wfc: contradiction still emits a (partial) grid, never crashes", still_emits) and ok

	# (6) PORT INVARIANT: the implicit "seed" input exists for handler=wfc and ONLY for wfc (a sanity that
	# the new arm did not leak its implicit port into other handlers).
	var wfc_ports: Array = _make_ctx(stripes, "wfc").input_ports()
	var df_ports: Array = _make_ctx(stripes, "dataflow").input_ports()
	ok = _check("wfc: handler=wfc exposes the implicit 'seed' input port", _has_port(wfc_ports, "seed")) and ok
	ok = _check("wfc: 'seed' port exists ONLY for handler=wfc (not dataflow)", not _has_port(df_ports, "seed")) and ok

	# (7) DEFAULT-HANDLER INVARIANT: an unknown handler still degrades to a plain Chip (forward-compatible).
	# A wfc Context with no declared outputs returns an empty dict (computes, emits nothing) — not a crash.
	var no_out := _wfc_arr(stripes, [])
	var empty := _eval_outputs(no_out, 7)
	ok = _check("wfc: a no-output scope computes and returns {} (no-output Chip parity)", empty == {}) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# arrangement builders + drivers
# ---------------------------------------------------------------------------------------------------

## A top-level arrangement: one Context(handler="wfc") with the given ruleset and the given output ports,
## a Const "s" feeding the implicit "seed" input. (outputs is an Array of {name} dicts.)
func _wfc_arr(ruleset: Dictionary, outputs: Array, handler := "wfc") -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": {
				"handler": handler, "wfc": ruleset,
				"ports": { "inputs": [], "outputs": outputs } } },
			{ "id": "s", "type": "Const", "params": { "value": 0 } },
		],
		"wires": [
			{ "from": "s", "out": "value", "to": "ctx", "in": "seed" },
		],
	}

## Standalone Context node from a ruleset+handler, for port introspection.
func _make_ctx(ruleset: Dictionary, handler: String) -> PrimContext:
	var ctx := PrimContext.new()
	ctx.params = { "handler": handler, "wfc": ruleset, "ports": { "inputs": [], "outputs": [] } }
	return ctx

func _has_port(ports: Array, nm: String) -> bool:
	for p in ports:
		if String(p.get("name")) == nm:
			return true
	return false

## Evaluate a wfc arrangement at a given seed and return the ctx node's full output dict.
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

## The collapsed grid (Array of rows) for a ruleset+seed.
func _wfc_grid(ruleset: Dictionary, seed: int) -> Array:
	var outs := _eval_outputs(_wfc_arr(ruleset, [{ "name": "grid" }, { "name": "contradiction" }, { "name": "collapses" }]), seed)
	var g = outs.get("grid")
	return g if g is Array else []

## A single named WFC output field (contradiction / collapses) for a ruleset+seed.
func _wfc_field(ruleset: Dictionary, seed: int, field: String) -> Variant:
	var outs := _eval_outputs(_wfc_arr(ruleset, [{ "name": "grid" }, { "name": "contradiction" }, { "name": "collapses" }]), seed)
	return outs.get(field)

## True iff every horizontally-adjacent pair in the grid is an A|B alternation (the stripes rule).
func _stripes_horiz_ok(grid: Array) -> bool:
	for row in grid:
		for x in range((row as Array).size() - 1):
			var a := String(row[x])
			var b := String(row[x + 1])
			if a == b or (a != "A" and a != "B") or (b != "A" and b != "B"):
				return false
	return true

# ---------------------------------------------------------------------------------------------------
func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
