extends SceneTree
## Headless proof of the OBSERVER-DRIVEN abstract / LOD Context handler (see
## COMMUNICATION-ARCHITECTURE.md §2.3 + §2.5). The `observer` handler is the spatial DUAL of
## `proximity`: it reads positions as INPUTS the same way, but instead of going dormant when far it
## COLLAPSES the scope to its content-addressed summary — live, re-simulatable up close; one cached
## primitive at a distance. "A primitive is a node you chose not to open", opened only when the
## observer is near enough to care (the §2.5 deferred camera-driven LOD-abstraction trigger).
##
##   <godot> --headless --path godot -s res://headless_observer_lod_test.gd
##
## Proves, over the SAME inner arrangement the context test uses (Const3 + Const4 -> Math add -> Log):
##   - observer WITHIN lod_radius runs the FULL live scope (=> 7), and does NOT cache (you see detail);
##   - observer OUTSIDE lod_radius computes the summary ONCE then SHORTCUTS to the cache forever after;
##   - the cache is hermetic on the scope's MAPPED inputs but INDEPENDENT of where the observer is
##     (two far evaluations at different observer positions share one summary);
##   - the observer cache never collides with the abstract cache (separate "observer:" key tag);
##   - an impure scope (Log inside) degrades to running live at EVERY distance (never freezes a side
##     effect), and is never cached;
##   - missing observer/scope position is the fail-safe STAY-LIVE case (never collapse an unplaceable
##     scope), the OPPOSITE of proximity's missing-position-is-dormant rule;
##   - lod_radius is inclusive (<=), clamps to >= 0, and accepts native Godot Vector3/Vector2 inputs.
## Mirrors headless_context_test.gd style (PASS/FAIL, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://schema/arrangement.example.json"))
	var resolver_rt := GraphRuntime.new()
	var resolver := Callable(resolver_rt, "port_type")

	# One pure scope, reused under the observer handler: Chip [a,b,m] (Const3 + Const4 -> Math add) -> Log "out".
	var g := ChipOps.group(base, ["a", "b", "m"], resolver)

	# (1) NEAR — observer within lod_radius runs the FULL live scope and does NOT cache (detail shown).
	PrimContext._summaries.clear()
	var near = _eval_log(_as_observer(g, 5.0, [0, 0, 0], [1, 0, 0]))
	ok = _check("Context[observer] NEAR (within lod_radius) runs live => 7",
		near == 7.0) and ok
	ok = _check("Context[observer] NEAR does NOT cache (live, re-simulatable up close)",
		PrimContext._summaries.size() == 0) and ok

	# (2) FAR — observer outside lod_radius COLLAPSES to the cached summary, computed once then shortcut.
	PrimContext._summaries.clear()
	var ev_before := PrimContext._evals
	var far_scope := _as_observer(g, 2.0, [0, 0, 0], [50, 0, 0])
	var f1 = _eval_log(far_scope)
	var f2 = _eval_log(far_scope)
	var f3 = _eval_log(far_scope)
	ok = _check("Context[observer] FAR collapses to summary => 7 (== the live value)", f1 == 7.0) and ok
	ok = _check("Context[observer] FAR computes once then shortcuts: 3 far evals, real dataflow ran exactly once",
		f1 == 7.0 and f2 == 7.0 and f3 == 7.0 and (PrimContext._evals - ev_before) == 1
		and PrimContext._summaries.size() == 1) and ok

	# (3) The FAR cache is INDEPENDENT of where the observer is: a second far evaluation at a DIFFERENT
	#     far observer position reuses the SAME summary (the observer's whereabouts decide near/far, not
	#     the output) — still exactly one cache entry, no real recompute.
	var ev_far2 := PrimContext._evals
	var f4 = _eval_log(_as_observer(g, 2.0, [0, 0, 0], [999, 7, -3]))
	ok = _check("Context[observer] FAR cache is observer-position-independent (one entry, no recompute)",
		f4 == 7.0 and (PrimContext._evals - ev_far2) == 0 and PrimContext._summaries.size() == 1) and ok

	# (4) The observer cache NEVER collides with the abstract cache: abstracting the same pure scope is a
	#     SEPARATE entry (distinct "observer:" vs "abstract:" key tag) — two entries, two real computes.
	PrimContext._summaries.clear()
	var ev_x := PrimContext._evals
	var _xa = _eval_log(_as_context(g, "abstract"))                          # abstract: key
	var _xo = _eval_log(_as_observer(g, 2.0, [0, 0, 0], [50, 0, 0]))         # observer: key
	ok = _check("Context[observer] cache does not collide with abstract cache (2 entries, 2 computes)",
		PrimContext._summaries.size() == 2 and (PrimContext._evals - ev_x) == 2) and ok

	# (5) The boundary is inclusive (<=) and a scope exactly AT lod_radius is treated as NEAR (live).
	PrimContext._summaries.clear()
	ok = _check("Context[observer] exactly AT lod_radius (inclusive <=) is NEAR => live, not cached",
		_eval_log(_as_observer(g, 3.0, [0, 0, 0], [0, 3, 0])) == 7.0 and PrimContext._summaries.size() == 0) and ok

	# (6) Impure scope (a Log inside) can't be memoized → runs LIVE at every distance, never cached.
	PrimContext._summaries.clear()
	var impure_far := _inject_inner_log(_as_observer(g, 2.0, [0, 0, 0], [50, 0, 0]))
	var iv1 = _eval_log(impure_far)
	var iv2 = _eval_log(impure_far)
	ok = _check("Context[observer] FAR over impure (Log) scope runs live, never cached, still => 7",
		iv1 == 7.0 and iv2 == 7.0 and PrimContext._summaries.size() == 0) and ok

	# (7) Fail-safe: a MISSING observer or scope position => STAY-LIVE (never collapse an unplaceable
	#     scope), the OPPOSITE of proximity's missing-position-is-dormant. Live => 7, nothing cached.
	PrimContext._summaries.clear()
	ok = _check("Context[observer] missing observer_pos => stay-live (fail-safe) => 7, not cached",
		_eval_log(_as_observer(g, 2.0, null, [50, 0, 0])) == 7.0 and PrimContext._summaries.size() == 0) and ok
	ok = _check("Context[observer] missing scope pos => stay-live (fail-safe) => 7, not cached",
		_eval_log(_as_observer(g, 2.0, [0, 0, 0], null)) == 7.0 and PrimContext._summaries.size() == 0) and ok

	# (8) lod_radius clamps to >= 0 (a stray negative range degrades to "coincident-only"), and native
	#     Godot Vector3/Vector2 position inputs are accepted + flattened identically to the array form.
	PrimContext._summaries.clear()
	ok = _check("Context[observer] negative lod_radius clamps to 0: coincident => NEAR (live)",
		_eval_log(_as_observer(g, -5.0, [0, 0, 0], [0, 0, 0])) == 7.0 and PrimContext._summaries.size() == 0) and ok
	ok = _check("Context[observer] negative lod_radius clamps to 0: non-coincident => FAR (cached)",
		_eval_log(_as_observer(g, -5.0, [0, 0, 0], [0, 1, 0])) == 7.0 and PrimContext._summaries.size() == 1) and ok
	PrimContext._summaries.clear()
	ok = _check("Context[observer] native Vector3 inputs, NEAR within lod_radius => live => 7",
		_eval_log(_as_observer(g, 2.0, Vector3(1, 2, 3), Vector3(1, 2, 4))) == 7.0 and PrimContext._summaries.size() == 0) and ok
	ok = _check("Context[observer] native Vector2 inputs, FAR outside lod_radius => cached => 7",
		_eval_log(_as_observer(g, 1.0, Vector2(0, 0), Vector2(50, 0))) == 7.0 and PrimContext._summaries.size() == 1) and ok

	# (9) Non-destructive: LOD gating never touches the source arrangement — base Chip still => 7.
	ok = _check("Context[observer] is non-destructive (base Chip still => 7)", _eval_log(g) == 7.0) and ok

	resolver_rt.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ---------------------------------------------------------------

## Copy `g`, retype its Chip node to a Context with the given handler.
func _as_context(g: Dictionary, handler: String) -> Dictionary:
	var out: Dictionary = g.duplicate(true)
	for n in out.get("nodes", []):
		if String(n.get("type")) == "Chip":
			n["type"] = "Context"
			var p: Dictionary = n.get("params", {})
			p["handler"] = handler
			n["params"] = p
			break
	return out

## An observer Context plus Const nodes feeding its implicit "observer_pos"/"pos" inputs and its static
## "lod_radius" param. With a null position the corresponding endpoint is left UNCONNECTED to exercise
## the stay-live fail-safe (missing position => run live). Positions are plain number arrays (or native
## Vector2/3, which the handler also flattens).
func _as_observer(g: Dictionary, lod_radius: float, observer_pos, pos) -> Dictionary:
	var ctx_id := _first_type_id(g, "Chip")
	var out := _as_context(g, "observer")
	for n in out.get("nodes", []):
		if String(n.get("id")) == ctx_id:
			n["params"]["lod_radius"] = lod_radius
			break
	if observer_pos != null:
		(out["nodes"] as Array).append({ "id": "obs", "type": "Const", "params": { "value": observer_pos } })
		(out["wires"] as Array).append({ "from": "obs", "out": "value", "to": ctx_id, "in": "observer_pos" })
	if pos != null:
		(out["nodes"] as Array).append({ "id": "scp", "type": "Const", "params": { "value": pos } })
		(out["wires"] as Array).append({ "from": "scp", "out": "value", "to": ctx_id, "in": "pos" })
	return out

## Add an (unconnected) Log node into a Context's inner arrangement, making the scope impure so the
## observer handler's purity gate (shared with `abstract`) must refuse to cache it (run live instead).
func _inject_inner_log(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = ctx.duplicate(true)
	for n in out.get("nodes", []):
		if String(n.get("type")) == "Context":
			(n["params"]["arrangement"]["nodes"] as Array).append({ "id": "innerlog", "type": "Log", "params": {} })
			break
	return out

func _first_type_id(arr: Dictionary, type_name: String) -> String:
	for n in arr.get("nodes", []):
		if String(n.get("type")) == type_name:
			return String(n.get("id"))
	return ""

func _eval_log(arr: Dictionary, log_id := "out"):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	rt.evaluate()
	var log_node = rt.nodes.get(log_id)
	var v = log_node.last_value if log_node != null else null
	get_root().remove_child(rt)
	rt.free()
	return Primitive.as_num(v) if v != null else null

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
