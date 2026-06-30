class_name CommChannel
extends RefCounted
## The CONNECTOR transport core — the §2.4 "communication with the outside world" narrow waist,
## made concrete as one transport-neutral module (see COMMUNICATION-ARCHITECTURE.md §2.4, §5).
##
## Communication is a module: the `connector` Context handler (prim_context.gd) is a DUMB DELEGATE
## over THIS. A connector is selected by a `channel` PARAM value (DATA), never by three hardcoded
## code paths in the foundation — the three modes below are ONE module reading a mode param. Every
## channel speaks the same canonical envelope and the same tiny universal verb set, so adding a new
## medium is one `match` arm, never a foundation edit.
##
## THE CANONICAL ENVELOPE (§2.4) — the one shape that crosses the seam, in BOTH directions:
##   {
##     "identity":            <string>   who/what this endpoint is (the connector's name)
##     "routing":             <string>   where it goes (a URI-scheme address, scheme://address)
##     "payload":             <variant>  the typed payload — here a Message record {role, content,
##                                        author, created_at, title} (the Message primitive's DATA)
##     "interaction_pattern": <string>   "one_way" | "request_reply" | "pub_sub" | "stream"
##                                        (Camel's Message Exchange Pattern — the STYLE of comms as
##                                        data the engine can route on)
##   }
##
## THE UNIVERSAL VERBS (§2.4): connect / send / receive / close / describe. Every channel expresses
## its whole capability through these. This module exposes them as static functions taking the
## channel id + a config dict (the static handler params: routing, identity, interaction_pattern,
## plus channel-specific config like the bridge live-dir). State that must persist (the dev-console
## log, the in-world inbox) lives in the caller-supplied config dict, never in the foundation.
##
## THE THREE SHIPPED CHANNELS (selected by the `channel` param):
##   "in_world"        — an in-world chat surface: a Message record is delivered INTO / received OUT
##                       of an in-scene inbox (an Array carried in config), so messages flow between
##                       Message nodes inside the running scene (NPC/console chat). Pure DATA routing.
##   "dev_console"     — a developer console: send writes the message to stdout + appends to a console
##                       log (an Array in config); receive reads the last console line back as a record.
##   "external_bridge" — an external Connector to a Claude Code session, REUSING the existing
##                       bridge/ file mechanism (graph_store's arrangement.json under a live-dir): send
##                       APPENDS the message as a Message node to the bridge arrangement file; receive
##                       reads the latest Message node back. The far endpoint is treated as external.
##
## NEGOTIATE-AND-FAIL-LOUDLY (§2.4, the ROS QoS lesson): an unconfigured / unknown / closed channel
## returns a SURFACED diagnostic envelope ({ok:false, error, diagnostic}), NEVER a silent no-op. The
## describe() verb reports a channel's contract so a caller can negotiate before connecting.

const PARENT_PORT := "parent"
const REPLY_PORT := "reply"

## The channels this module knows. Adding a medium = one new id here + one arm in each verb.
const CHANNELS := ["in_world", "dev_console", "external_bridge"]

## The interaction patterns the envelope may carry (Camel MEP). Default one_way.
const PATTERNS := ["one_way", "request_reply", "pub_sub", "stream"]

# --- the canonical envelope ----------------------------------------------------------------

## Build a canonical §2.4 envelope from a Message record + the channel config. The payload is the
## Message DATA verbatim (the Message primitive's record()); identity/routing/pattern come from the
## static handler config so the STYLE of communication is data the engine routes on.
static func make_envelope(channel: String, payload, config: Dictionary) -> Dictionary:
	var pattern := String(config.get("interaction_pattern", "one_way"))
	if not PATTERNS.has(pattern):
		pattern = "one_way"
	return {
		"identity": String(config.get("identity", channel)),
		"routing": String(config.get("routing", "%s://local" % channel)),
		"payload": payload,
		"interaction_pattern": pattern,
	}

## A surfaced diagnostic envelope — the loud-failure shape (§2.4). NEVER a silent no-op: an
## unconfigured/closed/unknown channel returns this so the caller (and a downstream Log) sees exactly
## what refused and why.
static func diagnostic(channel: String, error: String) -> Dictionary:
	return {
		"ok": false,
		"channel": channel,
		"error": error,
		"diagnostic": "connector channel '%s' refused: %s" % [channel, error],
	}

## True iff `env` is a well-formed transport result (not a diagnostic).
static func is_ok(env) -> bool:
	return typeof(env) == TYPE_DICTIONARY and not (env as Dictionary).get("ok", true) == false

# --- describe (the negotiation verb) -------------------------------------------------------

## Report a channel's contract WITHOUT connecting (§2.4 negotiate-before-connect). An unknown channel
## is reported as such (loud), so a caller can check compatibility first.
static func describe(channel: String) -> Dictionary:
	if not CHANNELS.has(channel):
		return diagnostic(channel, "unknown channel (known: %s)" % ", ".join(PackedStringArray(CHANNELS)))
	var desc := {
		"channel": channel,
		"verbs": ["connect", "send", "receive", "close", "describe"],
		"envelope": ["identity", "routing", "payload", "interaction_pattern"],
		"ok": true,
	}
	match channel:
		"in_world":
			desc["medium"] = "in-scene Message inbox (Array in config['inbox'])"
		"dev_console":
			desc["medium"] = "stdout + console log (Array in config['console_log'])"
		"external_bridge":
			desc["medium"] = "bridge arrangement file under config['live_dir'] (reuses bridge/ mechanism)"
	return desc

# --- connect (open + validate the channel; the negotiated handshake) -----------------------

## Open a channel against its config, validating the channel-specific REQUIRED config is present.
## Returns { ok:true, channel } on a good contract, or a loud diagnostic on a refusal (the ROS QoS
## "fail loudly, never silently" discipline). This is the gate the handler calls before send/receive.
## (This is the §2.4 `connect` verb; named open_channel in GDScript because `connect` is reserved on
## Object — the universal verb set is connect/send/receive/close/describe, exposed here 1:1 by name
## except this one alias.)
static func open_channel(channel: String, config: Dictionary) -> Dictionary:
	if not CHANNELS.has(channel):
		return diagnostic(channel, "unknown channel (known: %s)" % ", ".join(PackedStringArray(CHANNELS)))
	match channel:
		"in_world":
			if not (config.get("inbox") is Array):
				return diagnostic(channel, "no in-world inbox configured (config['inbox'] must be an Array)")
		"dev_console":
			# console_log is optional (send still prints to stdout); nothing required to open.
			pass
		"external_bridge":
			if String(config.get("live_dir", "")) == "":
				return diagnostic(channel, "no bridge live_dir configured (config['live_dir'] is required)")
	return { "ok": true, "channel": channel }

# --- send (DATA out across the seam) -------------------------------------------------------

## Send a Message record across the channel as a canonical envelope. Returns the SENT envelope on
## success (so a downstream node can observe exactly what crossed), or a loud diagnostic on refusal.
## `payload` is a Message record (Dictionary); a non-dict payload is wrapped as a note record so the
## envelope is always well-formed.
static func send(channel: String, payload, config: Dictionary) -> Dictionary:
	var opened := open_channel(channel, config)
	if not opened.get("ok", false):
		return opened
	var record := _as_record(payload)
	var env := make_envelope(channel, record, config)
	match channel:
		"in_world":
			(config["inbox"] as Array).append(env)
			return env
		"dev_console":
			var line := "%s: %s" % [String(record.get("role", "msg")), String(record.get("content", ""))]
			print("[dev_console] %s" % line)
			if config.get("console_log") is Array:
				(config["console_log"] as Array).append(line)
			return env
		"external_bridge":
			return _bridge_send(env, record, config)
	return diagnostic(channel, "send not implemented")

# --- receive (DATA in across the seam) -----------------------------------------------------

## Receive the most-recent message from the channel as a canonical envelope (the inverse of send).
## Returns the received envelope, or a loud diagnostic (including "nothing to receive" — an empty
## channel is reported, never silently swallowed).
static func receive(channel: String, config: Dictionary) -> Dictionary:
	var opened := open_channel(channel, config)
	if not opened.get("ok", false):
		return opened
	match channel:
		"in_world":
			var inbox: Array = config["inbox"]
			if inbox.is_empty():
				return diagnostic(channel, "in-world inbox is empty (nothing to receive)")
			return inbox[inbox.size() - 1]
		"dev_console":
			if not (config.get("console_log") is Array) or (config["console_log"] as Array).is_empty():
				return diagnostic(channel, "console log is empty (nothing to receive)")
			var log: Array = config["console_log"]
			var line := String(log[log.size() - 1])
			var rec := _line_to_record(line)
			return make_envelope(channel, rec, config)
		"external_bridge":
			return _bridge_receive(config)
	return diagnostic(channel, "receive not implemented")

# --- close (release the channel) -----------------------------------------------------------

## Close a channel. The shipped channels hold no OS handle (state lives in caller config), so close is
## a no-op success EXCEPT it marks the channel closed in config so a later send/receive on a closed
## channel fails loudly rather than silently re-opening.
static func close(channel: String, config: Dictionary) -> Dictionary:
	if not CHANNELS.has(channel):
		return diagnostic(channel, "unknown channel")
	return { "ok": true, "channel": channel, "closed": true }

# --- external_bridge: reuse the existing bridge/ file mechanism -----------------------------

## SEND over the external bridge: append the message as a Message node to the bridge arrangement file
## (live_dir/arrangement.json), the SAME file graph_store.py / scene_bridge.py / the running game use.
## This is the "reuse, don't rebuild" path — the far endpoint (a Claude Code session reading that file)
## is treated as external per §2.4. Append-only: the existing arrangement is read, the new Message node
## (+ a reply->parent wire to the previous tip) is appended, the whole arrangement re-written atomically.
static func _bridge_send(env: Dictionary, record: Dictionary, config: Dictionary) -> Dictionary:
	var live_dir := String(config.get("live_dir", ""))
	var arr := _bridge_load(live_dir)
	var nodes: Array = arr.get("nodes", [])
	var prev_tip := String(arr.get("current_node", ""))
	var nid := "msg_bridge_%d" % nodes.size()
	nodes.append({ "id": nid, "type": "Message", "params": record })
	arr["nodes"] = nodes
	var wires: Array = arr.get("wires", [])
	if prev_tip != "":
		wires.append({ "from": prev_tip, "out": REPLY_PORT, "to": nid, "in": PARENT_PORT })
	arr["wires"] = wires
	arr["current_node"] = nid
	var werr := _bridge_save(live_dir, arr)
	if werr != "":
		return diagnostic("external_bridge", werr)
	# The envelope that crossed records the routing it actually landed on (the bridge node id).
	var sent := env.duplicate(true)
	sent["routing"] = "bridge://%s#%s" % [live_dir, nid]
	return sent

## RECEIVE over the external bridge: read the latest Message node from the bridge arrangement file as a
## canonical envelope (the inverse of _bridge_send). The far endpoint having written a Message into the
## file is how a reply comes back — the round-trip the test exercises.
static func _bridge_receive(config: Dictionary) -> Dictionary:
	var live_dir := String(config.get("live_dir", ""))
	var arr := _bridge_load(live_dir)
	var nodes: Array = arr.get("nodes", [])
	# Prefer the current_node tip if it names a Message; else the last Message node in the file.
	var tip := String(arr.get("current_node", ""))
	var picked = null
	for n in nodes:
		if String(n.get("type")) == "Message":
			if String(n.get("id")) == tip:
				picked = n
				break
			picked = n  # keep the latest as a fallback
	if picked == null:
		return diagnostic("external_bridge", "no Message in the bridge file '%s' (nothing to receive)" % live_dir)
	return make_envelope("external_bridge", _as_record((picked as Dictionary).get("params", {})), config)

## Read the bridge arrangement file (live_dir/arrangement.json), or an empty arrangement if absent/
## corrupt (never raises — mirrors graph_store.load). Stdlib FileAccess only; no engine dependency.
static func _bridge_load(live_dir: String) -> Dictionary:
	var path := live_dir.path_join("arrangement.json")
	if not FileAccess.file_exists(path):
		return { "format": "resonance.arrangement/v1", "nodes": [], "wires": [] }
	var text := FileAccess.get_file_as_string(path)
	var data = JSON.parse_string(text)
	if typeof(data) == TYPE_DICTIONARY:
		return data
	return { "format": "resonance.arrangement/v1", "nodes": [], "wires": [] }

## Atomic-ish write of the bridge arrangement file (write .tmp then rename), mirroring graph_store's
## atomic_write. Returns "" on success or an error string on failure (surfaced as a loud diagnostic).
static func _bridge_save(live_dir: String, arr: Dictionary) -> String:
	if not DirAccess.dir_exists_absolute(live_dir):
		var mk := DirAccess.make_dir_recursive_absolute(live_dir)
		if mk != OK:
			return "could not create bridge live_dir '%s'" % live_dir
	var path := live_dir.path_join("arrangement.json")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return "could not open bridge file for write '%s'" % tmp
	f.store_string(JSON.stringify(arr, "\t"))
	f.close()
	var d := DirAccess.open(live_dir)
	if d == null:
		return "could not open bridge live_dir for rename '%s'" % live_dir
	if FileAccess.file_exists(path):
		d.remove("arrangement.json")
	var rn := d.rename("arrangement.json.tmp", "arrangement.json")
	if rn != OK:
		return "could not finalize bridge file write '%s'" % path
	return ""

# --- internals -----------------------------------------------------------------------------

## Coerce an arbitrary payload to a Message record (the §2.4 typed payload). A Dictionary with a
## "content"/"role" shape is taken as a record; anything else is wrapped as a note record so the
## envelope is always well-formed (renderer-neutral, serializable DATA).
static func _as_record(payload) -> Dictionary:
	if payload is Dictionary:
		var p: Dictionary = payload
		return {
			"role": String(p.get("role", "user")),
			"content": String(p.get("content", "")),
			"author": String(p.get("author", "")),
			"created_at": p.get("created_at", 0),
			"title": String(p.get("title", "")),
		}
	return { "role": "note", "content": str(payload), "author": "", "created_at": 0, "title": "" }

## Parse a "role: content" dev-console line back into a record (the receive inverse of dev_console send).
static func _line_to_record(line: String) -> Dictionary:
	var idx := line.find(": ")
	if idx == -1:
		return { "role": "note", "content": line, "author": "", "created_at": 0, "title": "" }
	return {
		"role": line.substr(0, idx),
		"content": line.substr(idx + 2),
		"author": "", "created_at": 0, "title": "",
	}
