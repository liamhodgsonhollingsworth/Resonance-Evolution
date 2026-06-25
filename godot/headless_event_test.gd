extends SceneTree
## Headless proof of the `event` (PUSH) Context handler — the dual of dataflow's pull (see
## COMMUNICATION-ARCHITECTURE.md §2.3, the `event` row: "push, not pull: a module fires; only its
## downstream re-propagates (menus, input, triggers)"). It reuses the SAME tick stepping core as
## tick/sim, conditioned on an implicit boolean "fire" input: a truthy fire advances the scope one
## continuous tick (committing State — a push permanently moves downstream state); a falsy fire is
## QUIESCENT (zero inner evaluations) and re-emits the last pushed outputs. So:
##   - between events nothing recomputes (a downstream Log fires once PER event, never on idle frames);
##   - before the first fire the scope emits null (the menu/trigger has not fired yet);
##   - the floor (GraphRuntime) is untouched — `event` is a new match arm + the fire gate, nothing more.
##
##   godot --headless --path godot -s res://headless_event_test.gd
##
## Mirrors headless_context_test.gd style (PASS/FAIL, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true

	# A top-level arrangement: a Context(handler="event") wrapping a State counter
	# (State -> Math(+1) -> State.next), its "count" output (= State's held value) wired to a Log "out".
	# A Const "f" feeds the Context's implicit "fire" input; we toggle f between evaluations of the SAME
	# runtime (load_arrangement preserves the kept Context instance, so its persistent State + last-pushed
	# snapshot survive across calls — exactly how a live event scope behaves frame to frame).
	var arr := _event_counter()

	# (1) A FRESH event scope that has NEVER fired emits null (the trigger has not fired yet).
	var seq_idle := _drive(arr, [false, false])
	ok = _check("event: un-fired scope is quiescent => [null, null]", seq_idle == [null, null]) and ok

	# (2) A single FIRE pushes one tick: the counter advances 0 -> 1 and the value reaches the Log.
	var seq_one := _drive(arr, [true])
	ok = _check("event: one fire pushes one tick => [1]", seq_one == [1.0]) and ok

	# (3) Repeated FIREs ACCUMULATE (continuous: a push permanently moves downstream State) => 1,2,3.
	var seq_acc := _drive(arr, [true, true, true])
	ok = _check("event: consecutive fires accumulate (push moves state) => [1, 2, 3]", seq_acc == [1.0, 2.0, 3.0]) and ok

	# (4) QUIESCENT frames between fires re-emit the LAST pushed value WITHOUT advancing — the defining
	# "nothing re-propagates between events" rest state. fire, idle, idle, fire => 1, 1, 1, 2.
	var seq_gap := _drive(arr, [true, false, false, true])
	ok = _check("event: idle frames hold the last pushed value, no advance => [1, 1, 1, 2]", seq_gap == [1.0, 1.0, 1.0, 2.0]) and ok

	# (5) PUSH, NOT PULL: the inner side-effecting Log inside the scope fires once PER event, never on
	# the idle frames between. Count the inner-Log emissions across [fire, idle, idle, fire, idle]:
	# exactly 2 (the two fires), not 5 (every evaluation).
	var inner_fires := _count_inner_log_pushes([true, false, false, true, false])
	ok = _check("event: inner side effect fires ONCE PER event, not per evaluation (2 fires => 2 logs)", inner_fires == 2) and ok

	# (6) The default-handler invariant is preserved: an otherwise-identical scope under `dataflow`
	# is NOT push-gated — it has no implicit "fire" port and recomputes every read. (Sanity that the
	# new arm did not leak into other handlers.)
	var df := _event_counter("dataflow")
	var df_ports: Array = _make_context_node(df).input_ports()
	var has_fire := false
	for p in df_ports:
		if String(p.get("name")) == "fire":
			has_fire = true
	ok = _check("event: the implicit 'fire' port exists ONLY for handler=event (not dataflow)", not has_fire) and ok
	var ev_ports: Array = _make_context_node(_event_counter("event")).input_ports()
	var ev_has_fire := false
	for p in ev_ports:
		if String(p.get("name")) == "fire":
			ev_has_fire = true
	ok = _check("event: handler=event DOES expose the implicit 'fire' port", ev_has_fire) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# ---------------------------------------------------------------------------------------------------
# arrangement builders
# ---------------------------------------------------------------------------------------------------

## The inner State-counter scope: State -> Math(+1) -> State.next. State's held "value" is the count.
func _inner_counter(with_inner_log := false) -> Dictionary:
	var nodes := [
		{ "id": "s", "type": "State", "params": { "init": 0 } },
		{ "id": "one", "type": "Const", "params": { "value": 1 } },
		{ "id": "m", "type": "Math", "params": { "op": "add" } },
	]
	var wires := [
		{ "from": "s", "out": "value", "to": "m", "in": "a" },
		{ "from": "one", "out": "value", "to": "m", "in": "b" },
		{ "from": "m", "out": "result", "to": "s", "in": "next" },
	]
	if with_inner_log:
		# A side-effecting sink INSIDE the scope, fed by the counter — fires only when the scope ticks.
		nodes.append({ "id": "ilog", "type": "Log", "params": {} })
		wires.append({ "from": "m", "out": "result", "to": "ilog", "in": "in" })
	return { "format": "resonance.arrangement/v1", "nodes": nodes, "wires": wires }

## Top-level arrangement: Context(handler) over the counter, "count" -> Log "out", with a Const "f"
## (default false) wired into the Context's implicit "fire" input.
func _event_counter(handler := "event", with_inner_log := false) -> Dictionary:
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": {
				"handler": handler, "steps": 1, "arrangement": _inner_counter(with_inner_log),
				"ports": { "inputs": [], "outputs": [{ "name": "count", "node": "s", "port": "value" }] } } },
			{ "id": "f", "type": "Const", "params": { "value": false } },
			{ "id": "out", "type": "Log", "params": {} },
		],
		"wires": [
			{ "from": "ctx", "out": "count", "to": "out", "in": "in" },
			{ "from": "f", "out": "value", "to": "ctx", "in": "fire" },
		],
	}

## A standalone Context node instance built from the arrangement's ctx spec (for port introspection).
func _make_context_node(arr: Dictionary) -> PrimContext:
	var ctx := PrimContext.new()
	for n in arr.get("nodes", []):
		if String(n.get("id")) == "ctx":
			ctx.params = n.get("params", {})
			break
	return ctx

# ---------------------------------------------------------------------------------------------------
# drivers
# ---------------------------------------------------------------------------------------------------

## Drive ONE runtime through a sequence of fire values, returning the Log "out" value after each
## evaluation. The runtime (and thus the Context instance + its persistent State + last-pushed snapshot)
## is kept across the sequence — only the "f" Const's value is rewritten each step (load_arrangement
## preserves kept instances), exactly modelling a live event scope across frames.
func _drive(arr_template: Dictionary, fires: Array) -> Array:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var seq := []
	for fire in fires:
		var arr: Dictionary = arr_template.duplicate(true)
		for n in arr.get("nodes", []):
			if String(n.get("id")) == "f":
				n["params"]["value"] = fire
		rt.load_arrangement(arr)
		rt.evaluate()
		var log_node = rt.nodes.get("out")
		var v = log_node.last_value if log_node != null else null
		seq.append(Primitive.as_num(v) if v != null else null)
	get_root().remove_child(rt)
	rt.free()
	return seq

## Count how many times the inner (in-scope) Log is pushed across a fire sequence. The inner Log lives
## INSIDE the Context's sub-runtime; it should be evaluated once per FIRE (a tick), never on an idle
## frame. We detect a push by the inner Log's last_value advancing (it strictly increases per tick).
func _count_inner_log_pushes(fires: Array) -> int:
	var arr := _event_counter("event", true)
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	var pushes := 0
	var prev_seen: Variant = null
	for fire in fires:
		var a: Dictionary = arr.duplicate(true)
		for n in a.get("nodes", []):
			if String(n.get("id")) == "f":
				n["params"]["value"] = fire
		rt.load_arrangement(a)
		rt.evaluate()
		# Reach into the Context's sub-runtime to read the inner Log's last_value.
		var ctx = rt.nodes.get("ctx")
		var sub = ctx._sub if ctx != null else null
		var ilog = sub.nodes.get("ilog") if sub != null else null
		var cur = ilog.last_value if ilog != null else null
		if cur != null and cur != prev_seen:
			pushes += 1
			prev_seen = cur
	get_root().remove_child(rt)
	rt.free()
	return pushes

# ---------------------------------------------------------------------------------------------------
func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
