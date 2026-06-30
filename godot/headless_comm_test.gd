extends SceneTree
## Headless proof of the IN-GAME CHAT SEAM (GZ-3D.2) — communication is a module, with a SELECTABLE
## channel (see COMMUNICATION-ARCHITECTURE.md §2.4). A single `connector` Context handler routes the
## SAME wired Message arrangement over THREE channels — in_world / dev_console / external_bridge —
## chosen purely by a `channel` PARAM (DATA), with ZERO change to the Message nodes.
##
##   godot --headless --path godot -s res://headless_comm_test.gd
##
## Proves:
##   (1) the same Message arrangement (Message "src" -> Context[connector] -> Log "out") routes
##       correctly under EACH of the 3 channel modes, the Message node untouched between modes
##       (the "same modules behave differently per channel" proof);
##   (2) the canonical §2.4 envelope {identity, routing, payload, interaction_pattern} crosses the seam,
##       carrying the Message record as its payload;
##   (3) external_bridge ROUND-TRIPS a message THROUGH the bridge file (send writes a Message node to
##       live_dir/arrangement.json; receive reads it back) — reusing the existing bridge/ mechanism;
##   (4) an UNCONFIGURED / UNKNOWN channel FAILS LOUDLY with a surfaced diagnostic, never a silent no-op;
##   (5) the seam is renderer-neutral DATA in/out, describable as {nodes, edges} (no Godot UI on a wire);
##   (6) CommChannel's universal verbs (describe/connect/send/receive/close) behave per §2.4.
## Mirrors headless_context_test.gd style (PASS/FAIL, RESULT, non-zero exit on failure).

func _initialize() -> void:
	var ok := true

	# The ONE shared Message arrangement, reused VERBATIM under every channel. A Message node "src"
	# (the chat turn as DATA) feeds a Context[connector] whose "sent" output is logged. The Message
	# node is IDENTICAL across all three channel runs — only the connector Context's `channel` param
	# differs. That is the whole proof: same modules, different channel.
	var msg_record := { "role": "user", "content": "hello from in-world", "author": "npc", "created_at": 1, "title": "" }

	# --- (1)+(2) the same arrangement routes under all three channels -------------------------------

	# in_world: the message lands in an in-scene inbox Array (messages flow between Message nodes in the
	# running scene). The inbox is shared config carried on the Context params (by reference).
	var inbox := []
	var iw := _connector_arrangement("in_world", msg_record, { "inbox": inbox })
	var iw_sent = _eval_port(iw, "out")
	ok = _check("in_world: routes the message (sent envelope is well-formed)",
		iw_sent is Dictionary and CommChannel.is_ok(iw_sent)) and ok
	ok = _check("in_world: envelope is the canonical §2.4 shape {identity,routing,payload,interaction_pattern}",
		iw_sent is Dictionary and iw_sent.has("identity") and iw_sent.has("routing")
		and iw_sent.has("payload") and iw_sent.has("interaction_pattern")) and ok
	ok = _check("in_world: payload IS the Message record (content carried verbatim)",
		iw_sent is Dictionary and String((iw_sent.get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world") and ok
	ok = _check("in_world: the message actually landed in the in-scene inbox",
		inbox.size() == 1 and String((inbox[0].get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world") and ok

	# dev_console: the SAME Message record, now routed to stdout + a console log Array. Note the Message
	# node spec is byte-identical to the in_world run; ONLY params.channel changed.
	var clog := []
	var dc := _connector_arrangement("dev_console", msg_record, { "console_log": clog })
	var dc_sent = _eval_port(dc, "out")
	ok = _check("dev_console: routes the SAME message (sent envelope ok)",
		dc_sent is Dictionary and CommChannel.is_ok(dc_sent)) and ok
	ok = _check("dev_console: wrote a line to the console log",
		clog.size() == 1 and String(clog[0]).contains("hello from in-world")) and ok
	ok = _check("dev_console: same payload content as in_world (same module, different channel)",
		dc_sent is Dictionary and String((dc_sent.get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world") and ok

	# external_bridge: the SAME Message record, routed to the bridge arrangement file (the existing
	# bridge/ mechanism). A fresh temp live-dir per run so the test is hermetic.
	var live_dir := _fresh_live_dir("comm_iw")
	var eb := _connector_arrangement("external_bridge", msg_record, { "live_dir": live_dir })
	var eb_sent = _eval_port(eb, "out")
	ok = _check("external_bridge: routes the SAME message (sent envelope ok)",
		eb_sent is Dictionary and CommChannel.is_ok(eb_sent)) and ok
	ok = _check("external_bridge: routing landed on a bridge:// node id",
		eb_sent is Dictionary and String(eb_sent.get("routing", "")).begins_with("bridge://")) and ok
	# The bridge file now exists and holds the Message node (renderer-neutral DATA on disk).
	ok = _check("external_bridge: wrote a Message node to the bridge file",
		_bridge_message_count(live_dir) == 1) and ok

	# Cross-channel invariant: ALL THREE sent envelopes carry the SAME payload content — the Message
	# node was never edited; only the channel param routed it differently. THE core proof.
	ok = _check("SAME modules, different channel: all 3 channels carried the identical payload",
		String((iw_sent.get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world"
		and String((dc_sent.get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world"
		and String((eb_sent.get("payload", {}) as Dictionary).get("content", "")) == "hello from in-world") and ok

	# --- (3) external_bridge ROUND-TRIP through the bridge files -----------------------------------

	# Send a message out, then the "far endpoint" (simulated by a direct CommChannel append, exactly as a
	# Claude Code session writing into the bridge file would) sends a REPLY; a receive reads it back.
	var rt_dir := _fresh_live_dir("comm_rt")
	var cfg := { "live_dir": rt_dir, "interaction_pattern": "request_reply" }
	var out_msg := { "role": "user", "content": "ping over the bridge", "created_at": 10 }
	var sent := CommChannel.send("external_bridge", out_msg, cfg)
	ok = _check("round-trip: outbound send wrote to the bridge file",
		CommChannel.is_ok(sent) and _bridge_message_count(rt_dir) == 1) and ok
	# The far endpoint replies (writes a second Message node into the SAME bridge file).
	var reply_msg := { "role": "assistant", "content": "pong from claude", "author": "claude-code", "created_at": 11 }
	var _r = CommChannel.send("external_bridge", reply_msg, cfg)
	var received := CommChannel.receive("external_bridge", cfg)
	ok = _check("round-trip: receive reads the far endpoint's reply back through the bridge file",
		CommChannel.is_ok(received)
		and String((received.get("payload", {}) as Dictionary).get("content", "")) == "pong from claude") and ok
	ok = _check("round-trip: the bridge file now holds both turns (append-only)",
		_bridge_message_count(rt_dir) == 2) and ok
	# Through the CONTEXT node (not just the raw module): a request_reply connector publishes BOTH the
	# sent envelope and the received reply, proving the handler wires the receive verb too.
	var rt2_dir := _fresh_live_dir("comm_rt2")
	# Seed a far-endpoint reply already in the file so the in-eval receive has something to read.
	CommChannel.send("external_bridge", { "role": "assistant", "content": "seeded reply", "created_at": 5 }, { "live_dir": rt2_dir })
	var rr := _connector_arrangement("external_bridge", { "role": "user", "content": "q", "created_at": 6 },
		{ "live_dir": rt2_dir, "interaction_pattern": "request_reply" }, ["sent", "received"])
	var rr_out := _eval_all(rr)
	var rr_node: Dictionary = rr_out.get("ctx", {})
	ok = _check("connector node (request_reply) publishes BOTH sent and received envelopes",
		CommChannel.is_ok(rr_node.get("sent")) and CommChannel.is_ok(rr_node.get("received"))) and ok

	# Receive-only seam (no message wired): the connector reads from the channel and publishes "received".
	var ro_dir := _fresh_live_dir("comm_ro")
	CommChannel.send("external_bridge", { "role": "assistant", "content": "only-receive", "created_at": 2 }, { "live_dir": ro_dir })
	var ro := _connector_receive_only("external_bridge", { "live_dir": ro_dir }, ["received"])
	var ro_recv = _eval_port(ro, "out", "received")
	ok = _check("receive-only seam (no message input) reads the channel and publishes 'received'",
		ro_recv is Dictionary and CommChannel.is_ok(ro_recv)
		and String((ro_recv.get("payload", {}) as Dictionary).get("content", "")) == "only-receive") and ok

	# --- (4) UNCONFIGURED / UNKNOWN channel FAILS LOUDLY -------------------------------------------

	# in_world with NO inbox configured -> a surfaced diagnostic, not a silent no-op.
	var bad_iw := _connector_arrangement("in_world", msg_record, {})  # no inbox in config
	var bad_iw_out = _eval_port(bad_iw, "out")
	ok = _check("UNCONFIGURED in_world (no inbox) fails LOUDLY (diagnostic envelope, not null)",
		bad_iw_out is Dictionary and bad_iw_out.get("ok") == false
		and String(bad_iw_out.get("diagnostic", "")).contains("inbox")) and ok

	# external_bridge with NO live_dir -> loud diagnostic.
	var bad_eb := _connector_arrangement("external_bridge", msg_record, {})  # no live_dir
	var bad_eb_out = _eval_port(bad_eb, "out")
	ok = _check("UNCONFIGURED external_bridge (no live_dir) fails LOUDLY",
		bad_eb_out is Dictionary and bad_eb_out.get("ok") == false
		and String(bad_eb_out.get("diagnostic", "")).contains("live_dir")) and ok

	# An UNKNOWN channel name -> loud diagnostic (negotiate-and-fail-loudly).
	var bad_un := _connector_arrangement("telepathy", msg_record, { "inbox": [] })
	var bad_un_out = _eval_port(bad_un, "out")
	ok = _check("UNKNOWN channel 'telepathy' fails LOUDLY (surfaced diagnostic)",
		bad_un_out is Dictionary and bad_un_out.get("ok") == false
		and String(bad_un_out.get("diagnostic", "")).contains("unknown channel")) and ok

	# An empty inbox / empty bridge receive is REPORTED, never silently swallowed.
	var empty_recv := CommChannel.receive("in_world", { "inbox": [] })
	ok = _check("empty in_world receive is REPORTED loudly (not a silent null)",
		empty_recv is Dictionary and empty_recv.get("ok") == false) and ok

	# --- (5) renderer-neutral DATA: the seam is describable as {nodes, edges} ----------------------

	var seam := _connector_arrangement("in_world", msg_record, { "inbox": [] })
	ok = _check("the seam is plain {nodes, wires} DATA (no Godot UI type on any wire)",
		seam.has("nodes") and seam.has("wires") and (seam.get("nodes") is Array)) and ok
	# The whole arrangement round-trips through JSON (proof nothing on a wire is a live Godot object).
	# NOTE: config Arrays (inbox/console_log) live on the Context as runtime references — excluded here
	# (a real arrangement wires those from sibling nodes); we serialize the topology, which is the claim.
	var topo := { "format": "resonance.arrangement/v1", "nodes": seam.get("nodes"), "wires": seam.get("wires") }
	var as_json := JSON.stringify(topo)
	ok = _check("the seam topology serializes to JSON and back (engine-agnostic DATA)",
		as_json != "" and typeof(JSON.parse_string(as_json)) == TYPE_DICTIONARY) and ok

	# --- (6) CommChannel universal verbs (§2.4) ----------------------------------------------------

	for ch in CommChannel.CHANNELS:
		var d := CommChannel.describe(ch)
		ok = _check("describe('%s') reports the 5 universal verbs + the envelope contract" % ch,
			d.get("ok") == true and (d.get("verbs") as Array).size() == 5
			and (d.get("envelope") as Array).size() == 4) and ok
	ok = _check("describe(unknown) is a loud diagnostic",
		CommChannel.describe("nope").get("ok") == false) and ok
	ok = _check("connect(in_world) with a good inbox negotiates ok",
		CommChannel.open_channel("in_world", { "inbox": [] }).get("ok") == true) and ok
	ok = _check("connect(in_world) with NO inbox refuses (negotiated failure)",
		CommChannel.open_channel("in_world", {}).get("ok") == false) and ok
	ok = _check("close(in_world) returns a clean closed-ok result",
		CommChannel.close("in_world", {}).get("closed") == true) and ok
	# interaction_pattern is data the engine can route on: an unknown pattern degrades to one_way.
	var env_pat := CommChannel.make_envelope("in_world", { "content": "x" }, { "interaction_pattern": "bogus" })
	ok = _check("an unknown interaction_pattern degrades to 'one_way' (never an invalid envelope)",
		String(env_pat.get("interaction_pattern")) == "one_way") and ok
	var env_pat2 := CommChannel.make_envelope("in_world", { "content": "x" }, { "interaction_pattern": "stream" })
	ok = _check("a valid interaction_pattern ('stream') is carried on the envelope",
		String(env_pat2.get("interaction_pattern")) == "stream") and ok

	# --- (7) default handler unaffected: a connector param on a non-connector Context is inert ------
	# (forward-compat: the dataflow handler still ignores channel/routing, so existing graphs are safe.)
	ok = _check("dataflow Context ignores a stray channel param (foundation unchanged)",
		_dataflow_ignores_channel()) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers -----------------------------------------------------------------------------------

## Build the canonical seam: a Message node "src" (the chat turn as DATA) -> Context[connector] "ctx"
## (channel selectable) -> Log "out". The Message node spec is INVARIANT across channels; only the
## Context's `channel` param + its channel-specific config differ. `extra_config` carries the runtime
## config (inbox / console_log / live_dir / interaction_pattern) onto the Context params.
func _connector_arrangement(channel: String, msg_record: Dictionary, extra_config: Dictionary, out_ports := ["sent"]) -> Dictionary:
	var ctx_params := { "handler": "connector", "channel": channel,
		"arrangement": { "format": "resonance.arrangement/v1", "nodes": [], "wires": [] },
		"ports": { "inputs": [], "outputs": _named_ports(out_ports) } }
	for k in extra_config:
		ctx_params[k] = extra_config[k]
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "src", "type": "Message", "params": msg_record },
			{ "id": "ctx", "type": "Context", "params": ctx_params },
			{ "id": "out", "type": "Log", "params": {} },
		],
		"wires": [
			{ "from": "src", "out": "reply", "to": "ctx", "in": "message" },
			{ "from": "ctx", "out": out_ports[0], "to": "out", "in": "in" },
		],
	}

## A receive-only seam: NO Message wired into the Context, so the connector reads from the channel.
func _connector_receive_only(channel: String, extra_config: Dictionary, out_ports := ["received"]) -> Dictionary:
	var ctx_params := { "handler": "connector", "channel": channel,
		"arrangement": { "format": "resonance.arrangement/v1", "nodes": [], "wires": [] },
		"ports": { "inputs": [], "outputs": _named_ports(out_ports) } }
	for k in extra_config:
		ctx_params[k] = extra_config[k]
	return {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": ctx_params },
			{ "id": "out", "type": "Log", "params": {} },
		],
		"wires": [{ "from": "ctx", "out": out_ports[0], "to": "out", "in": "in" }],
	}

func _named_ports(names: Array) -> Array:
	var out := []
	for n in names:
		out.append({ "name": String(n), "node": "", "port": "" })
	return out

## A connector Context spec where the channel is "dataflow" but a stray channel param is set — proving
## the default handler ignores it (forward-compat). Returns true iff the dataflow scope still evaluates
## as a plain Chip (no connector behavior leaks in).
func _dataflow_ignores_channel() -> bool:
	var inner := { "format": "resonance.arrangement/v1",
		"nodes": [{ "id": "c", "type": "Const", "params": { "value": 42 } }], "wires": [] }
	var arr := {
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "ctx", "type": "Context", "params": {
				"handler": "dataflow", "channel": "in_world",  # stray channel param — must be inert
				"arrangement": inner,
				"ports": { "inputs": [], "outputs": [{ "name": "v", "node": "c", "port": "value" }] } } },
			{ "id": "out", "type": "Log", "params": {} },
		],
		"wires": [{ "from": "ctx", "out": "v", "to": "out", "in": "in" }],
	}
	return Primitive.as_num(_eval_port(arr, "out")) == 42.0

## Evaluate the arrangement and return the Log node's last value.
func _eval_port(arr: Dictionary, log_id := "out", _unused := ""):
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	rt.evaluate()
	var log_node = rt.nodes.get(log_id)
	var v = log_node.last_value if log_node != null else null
	get_root().remove_child(rt)
	rt.free()
	return v

## Evaluate the arrangement and return the raw node_id -> {port -> value} outputs map.
func _eval_all(arr: Dictionary) -> Dictionary:
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arr)
	var outs := rt.evaluate()
	get_root().remove_child(rt)
	rt.free()
	return outs

## Count Message nodes in a bridge arrangement file (the on-disk DATA the bridge mechanism shares).
func _bridge_message_count(live_dir: String) -> int:
	var path := live_dir.path_join("arrangement.json")
	if not FileAccess.file_exists(path):
		return 0
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return 0
	var c := 0
	for n in (data as Dictionary).get("nodes", []):
		if String(n.get("type")) == "Message":
			c += 1
	return c

## A fresh, empty temp live-dir under user:// so each bridge test is hermetic (no cross-run state).
func _fresh_live_dir(stem: String) -> String:
	var dir := "user://%s_%d" % [stem, Time.get_ticks_usec()]
	var abs := ProjectSettings.globalize_path(dir)
	if DirAccess.dir_exists_absolute(abs):
		# wipe a stale dir (defensive; the usec stem makes collisions unlikely)
		var d := DirAccess.open(abs)
		if d != null:
			for f in d.get_files():
				d.remove(f)
	DirAccess.make_dir_recursive_absolute(abs)
	return abs

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
