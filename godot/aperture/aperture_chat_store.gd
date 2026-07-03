class_name ApertureChatStore
extends RefCounted
## PURE-DATA client for the APERTURE CHAT channel — the SAME durable, append-only store the web
## composer writes (Wavelet `Alethea-cc/tools/aperture_chat.py`, SPEC-750). Both surfaces speak
## the SAME schema over the SAME files/routes, so session-routing hooks (claim/label/read in
## events.jsonl) fire identically no matter which surface Liam types into.
##
## Channels (source selection is DATA, never code — mirrors ApertureInbox):
##   - "http": the caller fetches GET /api/aperture/chat/history and hands the body text to
##             `parse_history_body`; sends POST /api/aperture/chat/send. Identical rows to the
##             web composer (the server persists via aperture_chat.append_message).
##   - "file": read/write the raw substrate directly (chat.jsonl + messages/*.json +
##             events.jsonl) — the fallback when :8770 is down. The file path mirrors the
##             Python tool's semantics EXACTLY:
##               * message row: {"id":"acm_<hex32>","ts":"<ISO-8601 Z>","from":"liam"|<sid>,
##                               "text":"<verbatim>","in_reply_to":null|"<id>"}
##               * persist ORDER (load-bearing recovery guarantee): write the per-message
##                 recovery copy messages/<id>.json FIRST, THEN append the chat.jsonl line.
##               * read path UNCONDITIONALLY reconciles chat.jsonl against messages/*.json
##                 (a lost/torn chat.jsonl line re-surfaces from its recovery copy).
##               * fold: assigned_to = LAST label event's `to` (last-label-wins);
##                 read_by = union of read events' `by`. Message rows are never mutated.
##
## Everything here is engine-agnostic data-in/data-out (no scene types) so the chat panel,
## the board, and the headless test share ONE implementation.

## The canonical live chat dir on this host (the same dir the web server reads/writes).
## Overridable everywhere — tests pass a temp dir so they never pollute the live channel.
static func default_chat_dir() -> String:
	var root := OS.get_environment("WAVELET_ROOT")
	if root == "":
		root = "G:/Wavelet"
	return root.replace("\\", "/").trim_suffix("/") + "/Alethea-cc/state/aperture/chat"


# ---------------------------------------------------------------------------------------------
# http channel — parse the /api/aperture/chat/history response body
# ---------------------------------------------------------------------------------------------

## Parse the JSON body of GET /api/aperture/chat/history → Array of message rows (each with
## assigned_to + read_by already folded by the server). Returns [] on malformed input.
static func parse_history_body(text: String) -> Array:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not bool(data.get("ok", false)):
		return []
	var out: Array = []
	for row in data.get("messages", []):
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out


# ---------------------------------------------------------------------------------------------
# file channel — read the raw substrate directly (server-down fallback)
# ---------------------------------------------------------------------------------------------

## Every message row from `chat_dir`, ALWAYS reconciled against the per-message recovery files
## (mirrors aperture_chat.read_messages): chat.jsonl in append order, corrupt lines skipped,
## then any messages/<id>.json id not already seen is unioned in. Re-sorts by (ts, id) only
## when a row was actually added or a line failed to parse — the clean case preserves order.
static func read_messages(chat_dir: String) -> Array:
	var rows: Array = []
	var seen := {}
	var had_parse_error := false
	var p := chat_dir.path_join("chat.jsonl")
	if FileAccess.file_exists(p):
		for line in FileAccess.get_file_as_string(p).split("\n"):
			line = line.strip_edges()
			if line == "":
				continue
			var r = JSON.parse_string(line)
			if typeof(r) != TYPE_DICTIONARY:
				had_parse_error = true
				continue
			rows.append(r)
			var rid := String(r.get("id", ""))
			if rid != "":
				seen[rid] = true
	if rows.is_empty():
		return _read_messages_from_files(chat_dir)
	var added := false
	for fr in _read_messages_from_files(chat_dir):
		var frid := String(fr.get("id", ""))
		if frid != "" and not seen.has(frid):
			rows.append(fr)
			seen[frid] = true
			added = true
	if added or had_parse_error:
		rows.sort_custom(_row_lt)
	return rows


static func _read_messages_from_files(chat_dir: String) -> Array:
	var out: Array = []
	var d := chat_dir.path_join("messages")
	var da := DirAccess.open(d)
	if da == null:
		return out
	for f in da.get_files():
		if not f.ends_with(".json"):
			continue
		var r = JSON.parse_string(FileAccess.get_file_as_string(d.path_join(f)))
		if typeof(r) == TYPE_DICTIONARY:
			out.append(r)
	out.sort_custom(_row_lt)
	return out


static func _row_lt(a, b) -> bool:
	var ta := String(a.get("ts", ""))
	var tb := String(b.get("ts", ""))
	if ta == tb:
		return String(a.get("id", "")) < String(b.get("id", ""))
	return ta < tb


## Fold events.jsonl over the messages → derived current state (mirrors aperture_chat.fold):
## each row gains `assigned_to` (LAST label event's `to`; null ⇒ unrouted) and `read_by`
## (sorted union of read events' `by`). Original row fields are preserved verbatim.
static func fold(chat_dir: String) -> Array:
	var msgs := read_messages(chat_dir)
	var assigned := {}
	var read_by := {}
	var ep := chat_dir.path_join("events.jsonl")
	if FileAccess.file_exists(ep):
		for line in FileAccess.get_file_as_string(ep).split("\n"):
			line = line.strip_edges()
			if line == "":
				continue
			var ev = JSON.parse_string(line)
			if typeof(ev) != TYPE_DICTIONARY:
				continue
			var mid := String(ev.get("id", ""))
			if mid == "":
				continue
			var et := String(ev.get("type", ""))
			if et == "label":
				assigned[mid] = ev.get("to")
			elif et == "read":
				var by := String(ev.get("by", ""))
				if by != "":
					if not read_by.has(mid):
						read_by[mid] = {}
					read_by[mid][by] = true
	var out: Array = []
	for m in msgs:
		var row: Dictionary = m.duplicate(true)
		var mid := String(m.get("id", ""))
		row["assigned_to"] = assigned.get(mid, null)
		var rb: Array = []
		if read_by.has(mid):
			rb = read_by[mid].keys()
			rb.sort()
		row["read_by"] = rb
		out.append(row)
	return out


# ---------------------------------------------------------------------------------------------
# file channel — durable write (the fallback send path)
# ---------------------------------------------------------------------------------------------

## Durably persist a new chat message into `chat_dir`, matching aperture_chat.append_message:
## per-message recovery copy messages/<id>.json FIRST (an existing id retries with a fresh
## 128-bit id — never overwrites verbatim text), THEN the chat.jsonl append. `text` is stored
## EXACTLY as given. Returns the message row, or {} on failure (empty text / io error).
static func append_message(chat_dir: String, sender: String, text: String,
		in_reply_to: String = "") -> Dictionary:
	if text.strip_edges() == "":
		return {}
	DirAccess.make_dir_recursive_absolute(chat_dir.path_join("messages"))
	var ts := Time.get_datetime_string_from_system(true) + "Z"
	var row := {}
	var line := ""
	var attempts := 0
	while true:
		var rid := "acm_" + Crypto.new().generate_random_bytes(16).hex_encode()
		row = {"id": rid, "ts": ts, "from": sender, "text": text,
			"in_reply_to": (in_reply_to if in_reply_to != "" else null)}
		line = JSON.stringify(row)
		var mp := chat_dir.path_join("messages").path_join(rid + ".json")
		if FileAccess.file_exists(mp):
			attempts += 1
			if attempts >= 8:
				return {}
			continue
		var mf := FileAccess.open(mp, FileAccess.WRITE)
		if mf == null:
			return {}
		mf.store_string(line + "\n")
		mf.flush()
		mf.close()
		break
	# (b) then the append-only stream. The per-message file is already durably written, so even
	# a lost append re-surfaces via read_messages' unconditional reconciliation.
	var cp := chat_dir.path_join("chat.jsonl")
	var cf: FileAccess
	if FileAccess.file_exists(cp):
		cf = FileAccess.open(cp, FileAccess.READ_WRITE)
		if cf != null:
			cf.seek_end()
	else:
		cf = FileAccess.open(cp, FileAccess.WRITE)
	if cf != null:
		cf.store_string(line + "\n")
		cf.flush()
		cf.close()
	return row
