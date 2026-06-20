extends SceneTree
## Headless verification of the conversation/idea taxonomy (Message primitive) + the
## graph<->text protocol (ConvoProtocol):
##
##   godot --headless --path godot -s res://headless_convo_test.gd
##
## Proves: Message nodes load + evaluate over the substrate; a merge node is a real DAG node
## (2 parents); context assembly walks ancestors for a single tip (linear) and for a merge
## subgraph (de-duplicated, created_at-ordered); the XML structure mode; the reply interpreter
## validates + flags actions; apply() is append-only; set_active_tip + linear<->graph
## projection (a branch tip yields a different linear thread). PASS/FAIL/RESULT like the others.

func _initialize() -> void:
	var ok := true
	var arr := _build_convo()

	# Substrate: Message nodes instantiate + evaluate (expose their record).
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	var outs := rt.evaluate()
	ok = _check("5 Message nodes instantiate", rt.nodes.size() == 5) and ok
	ok = _check("Message exposes its record on reply",
		String((outs.get("n3", {}).get("reply", {}) as Dictionary).get("content", "")) == "Hi!") and ok
	get_root().remove_child(rt)
	rt.free()

	# DAG: the merge node has two parents.
	ok = _check("merge node n5 has 2 parents", ConvoProtocol.parents_of(arr, "n5").size() == 2) and ok

	# Context for a single tip (linear path): ancestors + self, created_at order.
	var ctx3 := ConvoProtocol.to_messages(arr, ["n3"])
	ok = _check("path to n3 => [system, user, assistant]",
		ctx3.size() == 3 and ctx3[0].role == "system" and ctx3[1].role == "user" and ctx3[2].role == "assistant") and ok

	# Context for a merge subgraph: de-duplicated union of ancestors, created_at order.
	var ctx5 := ConvoProtocol.to_messages(arr, ["n5"])
	ok = _check("merge context n5 dedups to 5 nodes in order",
		ctx5.size() == 5 and ctx5[0].content == "You are helpful" and ctx5[4].content == "combine") and ok

	# Branch tip => a DIFFERENT linear thread (linear<->graph duality from one canonical DAG).
	var ctx4 := ConvoProtocol.to_messages(arr, ["n4"])
	ok = _check("branch tip n4 => [system, user(Hello), user(reframe)] (distinct thread)",
		ctx4.size() == 3 and ctx4[2].content == "Actually, reframe") and ok

	# Structure (XML) mode contains the graph + the appended question.
	var xml := ConvoProtocol.to_xml(arr, ["n5"], "Summarize the thread.")
	ok = _check("xml has idea_graph + roles + question",
		xml.contains("<idea_graph>") and xml.contains("role=\"assistant\"") and xml.contains("Summarize the thread.")) and ok

	# The copy-paste prompt embeds the structure + the action-block instruction.
	var prompt := ConvoProtocol.to_prompt(arr, ["n5"], "Summarize the thread.")
	ok = _check("copy-paste prompt includes resonance-actions instruction",
		prompt.contains("<idea_graph>") and prompt.contains("resonance-actions")) and ok

	# Reply interpreter: parse a fenced resonance-actions block -> validated proposals.
	var reply := "Sure.\n\n```resonance-actions\n[{\"op\":\"add_node\",\"kind\":\"Message\",\"params\":{\"role\":\"assistant\",\"content\":\"Follow-up\",\"created_at\":6},\"parent\":\"n5\"},{\"op\":\"bogus\"}]\n```\n"
	var interp := ConvoProtocol.interpret_reply(reply)
	ok = _check("interpreter accepts 1 valid action, flags 1 bad op",
		(interp.actions as Array).size() == 1 and (interp.errors as Array).size() == 1) and ok

	# apply() is APPROVAL-GATED + append-only: original untouched; new arr gains node + wire.
	var before_n := (arr.get("nodes") as Array).size()
	var before_w := (arr.get("wires") as Array).size()
	var applied := ConvoProtocol.apply(arr, interp.actions)
	ok = _check("apply is append-only (original arr unchanged)",
		(arr.get("nodes") as Array).size() == before_n and (arr.get("wires") as Array).size() == before_w) and ok
	ok = _check("apply added 1 node + 1 reply->parent wire from n5",
		(applied.get("nodes") as Array).size() == before_n + 1
		and (applied.get("wires") as Array).size() == before_w + 1
		and _any_wire_from(applied, "n5")) and ok

	# set_active_tip sets the canonical pointer used by the linear projection.
	var applied2 := ConvoProtocol.apply(arr, [{ "op": "set_active_tip", "node": "n4" }])
	ok = _check("set_active_tip sets current_node", String(applied2.get("current_node", "")) == "n4") and ok

	# Hardened validation: the structural gate (parity with bridge/test_graph_logic.py).
	var val_ok := ConvoProtocol.validate_actions(arr, [
		{ "op": "add_node", "kind": "Message", "params": { "role": "user", "content": "hi" }, "parent": "n5" },
		{ "op": "wire", "from": "n3", "to": "n4" },
		{ "op": "set_active_tip", "node": "n4" },
	])
	ok = _check("validate_actions accepts a sound batch",
		(val_ok.actions as Array).size() == 3 and (val_ok.errors as Array).is_empty()) and ok

	var bad := ConvoProtocol.validate_actions(arr, [
		{ "op": "add_node", "kind": "Message", "params": { "role": "user", "content": "x" }, "parent": "ghost" },
		{ "op": "wire", "from": "n1", "to": "nope" },
		{ "op": "wire", "from": "n2", "to": "n2" },
		{ "op": "set_active_tip", "node": "missing" },
		{ "op": "add_node", "kind": "Message", "params": { "content": "no role" } },
		{ "op": "bogus" },
	])
	ok = _check("validate_actions rejects parent/endpoint/self/tip/role/op (6 errors, 0 valid)",
		(bad.actions as Array).is_empty() and (bad.errors as Array).size() == 6) and ok

	var batch := ConvoProtocol.validate_actions(arr, [
		{ "op": "add_node", "id": "fresh", "kind": "Message", "params": { "role": "user", "content": "a" }, "parent": "n5" },
		{ "op": "add_node", "id": "fresh2", "kind": "Message", "params": { "role": "assistant", "content": "b" }, "parent": "fresh" },
	])
	ok = _check("validate_actions resolves batch-local ids (added node referenceable later)",
		(batch.actions as Array).size() == 2 and (batch.errors as Array).is_empty()) and ok

	# cycle rejection: a wire that would close a loop in the parent graph (n5 -> ... -> n1 -> n5).
	var cyc := ConvoProtocol.validate_actions(arr, [{ "op": "wire", "from": "n5", "to": "n1" }])
	var cyc_flagged := false
	for e in (cyc.errors as Array):
		if String(e).contains("cycle"):
			cyc_flagged = true
	ok = _check("validate_actions rejects a cycle-closing wire", cyc_flagged) and ok

	# validate_arrangement soundness.
	ok = _check("validate_arrangement: clean convo is ok", bool(ConvoProtocol.validate_arrangement(arr).ok)) and ok
	var broken := {
		"format": "resonance.arrangement/v1", "current_node": "ghost",
		"nodes": [ _msg("a", "user", "x", 1) ],
		"wires": [ { "from": "a", "out": "reply", "to": "missing", "in": "parent" } ],
	}
	var bsound := ConvoProtocol.validate_arrangement(broken)
	ok = _check("validate_arrangement flags dangling wire + missing tip",
		not bool(bsound.ok) and (bsound.dangling_wires as Array).size() == 1 and not bool(bsound.active_tip_exists)) and ok
	var ring := {
		"format": "resonance.arrangement/v1",
		"nodes": [ _msg("x", "user", "x", 1), _msg("y", "user", "y", 2) ],
		"wires": [ { "from": "x", "out": "reply", "to": "y", "in": "parent" },
			{ "from": "y", "out": "reply", "to": "x", "in": "parent" } ],
	}
	var rsound := ConvoProtocol.validate_arrangement(ring)
	ok = _check("validate_arrangement flags a cyclic parent graph", not bool(rsound.ok) and not bool(rsound.acyclic)) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ------------------------------------------------------------------------------

func _build_convo() -> Dictionary:
	# n1(system) -> n2(user) -> n3(assistant)
	#                       \-> n4(user, branch)
	# n3, n4 -> n5(user, MERGE: two parents)
	return {
		"format": "resonance.arrangement/v1",
		"current_node": "n3",
		"nodes": [
			_msg("n1", "system", "You are helpful", 1),
			_msg("n2", "user", "Hello", 2),
			_msg("n3", "assistant", "Hi!", 3),
			_msg("n4", "user", "Actually, reframe", 4),
			_msg("n5", "user", "combine", 5),
		],
		"wires": [
			_wire("n1", "n2"), _wire("n2", "n3"),
			_wire("n2", "n4"),
			_wire("n3", "n5"), _wire("n4", "n5"),
		],
	}

func _msg(id: String, role: String, content: String, created_at: int) -> Dictionary:
	return { "id": id, "type": "Message",
		"params": { "role": role, "content": content, "author": "", "created_at": created_at } }

func _wire(from_id: String, to_id: String) -> Dictionary:
	return { "from": from_id, "out": "reply", "to": to_id, "in": "parent" }

func _any_wire_from(arr: Dictionary, id: String) -> bool:
	for w in arr.get("wires", []):
		if String(w.get("from")) == id and String(w.get("in")) == "parent":
			return true
	return false

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
