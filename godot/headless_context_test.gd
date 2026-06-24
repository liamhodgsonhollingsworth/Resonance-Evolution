extends SceneTree
## Headless proof that COMMUNICATION IS A MODULE (see COMMUNICATION-ARCHITECTURE.md). A Context
## scopes a sub-arrangement (like a Chip) AND supplies the handler for HOW its modules communicate.
##
##   godot --headless --path godot -s res://headless_context_test.gd
##
## Proves, over ONE shared inner arrangement (Const3 + Const4 -> Math add, feeding Log "out"):
##   - a Context with the default `dataflow` handler == a plain Chip (=> 7);
##   - a `gate` Context makes the SAME scope live when enabled (=> 7) and dormant when disabled
##     (=> null) — "behave differently depending on what is going on";
##   - a `modulate` Context makes the SAME inner modules compute different values per context
##     (add => 7 vs op=mul => 12) WITHOUT changing the modules, and without mutating the source.
## Mirrors headless_chip_test.gd style (PASS/FAIL, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true
	var base: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://schema/arrangement.example.json"))
	var resolver_rt := GraphRuntime.new()
	var resolver := Callable(resolver_rt, "port_type")

	# One scope, reused under every handler: Chip [a,b,m] (Const3 + Const4 -> Math add) -> Log "out".
	var g := ChipOps.group(base, ["a", "b", "m"], resolver)
	ok = _check("baseline Chip scope => 7", _eval_log(g) == 7.0) and ok

	# (1) Default handler is exactly a Chip — existing behaviour is unchanged.
	ok = _check("Context[dataflow] == Chip => 7", _eval_log(_as_context(g, "dataflow", {})) == 7.0) and ok

	# (2) gate — the powered scope. Same modules; the context decides whether they propagate.
	ok = _check("Context[gate] enabled => 7", _eval_log(_as_context_gated(g, 1)) == 7.0) and ok
	ok = _check("Context[gate] disabled => dormant (null)", _eval_log(_as_context_gated(g, 0)) == null) and ok

	# (3) modulate — same inner modules, different computed value per context, no module change.
	var math_id := _inner_math_id(g)
	ok = _check("found inner Math id", math_id != "") and ok
	var ctx_add := _as_context(g, "modulate", {})
	var ctx_mul := _as_context(g, "modulate", { math_id: { "op": "mul" } })
	ok = _check("Context[modulate] none => 7", _eval_log(ctx_add) == 7.0) and ok
	ok = _check("Context[modulate] op=mul => 12 (same modules, diff context)", _eval_log(ctx_mul) == 12.0) and ok

	# (4) modulate never mutates the source arrangement: re-eval both, values still hold, and the
	#     original Chip is untouched.
	ok = _check("modulate is non-destructive (mul=>12, add=>7, base Chip=>7 still)",
		_eval_log(ctx_mul) == 12.0 and _eval_log(ctx_add) == 7.0 and _eval_log(g) == 7.0) and ok

	# (5) abstract — "a primitive is a node you chose not to open": compute-once, then shortcut.
	#     (a) a pure scope abstracted == the same scope as a Chip; (b) across N evals (fresh
	#     instances sharing the process-wide cache) the real dataflow runs exactly ONCE; (c) a scope
	#     containing an impure node (Log) falls through and is never cached (the purity gate).
	PrimContext._summaries.clear()
	var ev_before := PrimContext._evals
	var ctx_abs := _as_context(g, "abstract", {})
	var av1 = _eval_log(ctx_abs)
	var av2 = _eval_log(ctx_abs)
	var av3 = _eval_log(ctx_abs)
	ok = _check("Context[abstract] pure scope == Chip => 7", av1 == 7.0) and ok
	ok = _check("Context[abstract] compute-once: 3 evals, real dataflow ran exactly once + cached",
		av1 == 7.0 and av2 == 7.0 and av3 == 7.0 and (PrimContext._evals - ev_before) == 1
		and PrimContext._summaries.size() == 1) and ok

	PrimContext._summaries.clear()
	var ctx_impure := _inject_inner_log(_as_context(g, "abstract", {}))
	var iv1 = _eval_log(ctx_impure)
	var iv2 = _eval_log(ctx_impure)
	ok = _check("Context[abstract] over impure (Log) scope falls through, not cached, still => 7",
		iv1 == 7.0 and iv2 == 7.0 and PrimContext._summaries.size() == 0) and ok

	# (6) abstract is HERMETIC on inputs: the same pure scope under different inputs caches per-input
	#     (no collision). A scope-with-inputs (group [m]) abstracted; bumping a feeding Const changes
	#     the input, so the result differs and a SECOND cache entry is made.
	PrimContext._summaries.clear()
	var g_in := ChipOps.group(base, ["m"], resolver)      # Context-with-inputs (a,b) => 7
	var ctx_in := _as_context(g_in, "abstract", {})
	var d1 = _eval_log(ctx_in)                            # a=3,b=4 => 7  (miss)
	var ctx_in2: Dictionary = ctx_in.duplicate(true)     # same scope, bump Const "a" 3 -> 30
	for n in ctx_in2.get("nodes", []):
		if String(n.get("id")) == "a":
			n["params"]["value"] = 30
	var d2 = _eval_log(ctx_in2)                           # a=30,b=4 => 34 (miss, different inputs)
	ok = _check("Context[abstract] is hermetic on inputs: 7 then 34, two distinct cache entries",
		d1 == 7.0 and d2 == 34.0 and PrimContext._summaries.size() == 2) and ok

	# (7) precondition canary: a scope containing a nested WRAPPER (Chip, which may hide a Log) is
	#     NOT cached, because wrappers default is_cacheable()=false and the gate is non-recursive.
	#     This passes trivially today; it exists to FAIL LOUDLY if a future edit ever flips a wrapper
	#     cacheable without making the purity gate recursive (which would wrongly cache an opaque,
	#     possibly-impure scope). Keep this green or make the gate recursive.
	PrimContext._summaries.clear()
	var ctx_nested := _inject_inner_chip_with_log(_as_context(g, "abstract", {}))
	var nv1 = _eval_log(ctx_nested)
	ok = _check("Context[abstract] over a nested-wrapper scope is NOT cached (precondition canary)",
		nv1 == 7.0 and PrimContext._summaries.size() == 0) and ok

	resolver_rt.free()
	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ---------------------------------------------------------------

## Copy `g`, retype its Chip node to a Context with the given handler (+ optional modulation).
func _as_context(g: Dictionary, handler: String, modulation: Dictionary) -> Dictionary:
	var out: Dictionary = g.duplicate(true)
	for n in out.get("nodes", []):
		if String(n.get("type")) == "Chip":
			n["type"] = "Context"
			var p: Dictionary = n.get("params", {})
			p["handler"] = handler
			if not modulation.is_empty():
				p["modulation"] = modulation
			n["params"] = p
			break
	return out

## A gate Context plus a Const wired into its implicit "enabled" input.
func _as_context_gated(g: Dictionary, enabled_val) -> Dictionary:
	var ctx_id := _first_type_id(g, "Chip")
	var out := _as_context(g, "gate", {})
	(out["nodes"] as Array).append({ "id": "en", "type": "Const", "params": { "value": enabled_val } })
	(out["wires"] as Array).append({ "from": "en", "out": "value", "to": ctx_id, "in": "enabled" })
	return out

func _inner_math_id(g: Dictionary) -> String:
	for n in g.get("nodes", []):
		if String(n.get("type")) == "Chip":
			for inner_n in (n["params"]["arrangement"] as Dictionary).get("nodes", []):
				if String(inner_n.get("type")) == "Math":
					return String(inner_n.get("id"))
	return ""

## Add an (unconnected) Log node into a Context's inner arrangement, making the scope impure so the
## abstract handler's purity gate must refuse to cache it.
func _inject_inner_log(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = ctx.duplicate(true)
	for n in out.get("nodes", []):
		if String(n.get("type")) == "Context":
			(n["params"]["arrangement"]["nodes"] as Array).append({ "id": "innerlog", "type": "Log", "params": {} })
			break
	return out

## Add a nested Chip (which itself hides a Log) into a Context's inner arrangement. The nested
## wrapper defaults is_cacheable()=false, so the whole scope must be refused by the (non-recursive)
## purity gate — the canary that catches a future wrapper opting in without a recursive gate.
func _inject_inner_chip_with_log(ctx: Dictionary) -> Dictionary:
	var out: Dictionary = ctx.duplicate(true)
	for n in out.get("nodes", []):
		if String(n.get("type")) == "Context":
			(n["params"]["arrangement"]["nodes"] as Array).append({
				"id": "innerchip", "type": "Chip",
				"params": {
					"arrangement": { "format": "resonance.arrangement/v1",
						"nodes": [{ "id": "hidlog", "type": "Log", "params": {} }], "wires": [] },
					"ports": { "inputs": [], "outputs": [] } } })
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
