class_name ApertureInbox
extends RefCounted
## PURE-DATA inbox reader for the GODOT APERTURE 3D surface — the SAME substrate the web board
## renders, reached through EITHER of the two channels (source selection is DATA, never code):
##   - "http": the caller fetches GET /api/aperture/inbox (server_local.py) and hands the body
##             text to `parse_inbox_body` — identical rows to what the web page renders.
##   - "file": read the raw substrate directly (Alethea-cc/state/aperture/inbox/inbox.jsonl +
##             feedback.jsonl) via `read_inbox_file` — the fallback when :8770 is down. The
##             file path mirrors the server's own reading semantics: duplicate ids collapse
##             LAST-WINS (append-only in-place correction), and a row is hidden when its LATEST
##             feedback action is a hide (latest-action-wins; an unskip/restore un-hides).
##
## Everything here is engine-agnostic data-in/data-out (no scene types) so the 3D surface, the
## primitives, and the headless test share ONE implementation. Cards come out NORMALIZED:
##   { id, kind, title, subtitle, summary, text, link, images:[String], actions:[{id,label}],
##     disposition, generation:int(-1 if none), source_session }

## Mirror of the web substrate's action semantics (endpoints/_substrate.py): the LATEST action
## hides a card unless it is an un-hide verb (or empty). evolve/save also hide — a decided
## evolver card leaves the board on both surfaces.
const UNHIDE_ACTIONS := ["unskip", "restore", "undo", "unarchive"]

# ---------------------------------------------------------------------------------------------------
# http channel — parse the /api/aperture/inbox response body
# ---------------------------------------------------------------------------------------------------

## Parse the JSON body of GET /api/aperture/inbox → Array of normalized cards. The server has
## already applied every filter (decided/skipped/dev-noise/review rotation), so this is a pure
## normalize pass. Returns [] on malformed input (never crashes).
static func parse_inbox_body(text: String) -> Array:
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY or not bool(data.get("ok", false)):
		return []
	var out: Array = []
	for row in data.get("artifacts", []):
		if typeof(row) == TYPE_DICTIONARY:
			out.append(normalize_card(row))
	return out

# ---------------------------------------------------------------------------------------------------
# file channel — read the raw substrate JSONL directly (server-down fallback)
# ---------------------------------------------------------------------------------------------------

## Read inbox.jsonl + feedback.jsonl directly and return the PENDING cards, mirroring the
## server's collapse + hide semantics: duplicate ids collapse last-wins; an id whose latest
## feedback action is anything but an un-hide verb is hidden.
static func read_inbox_file(inbox_path: String, feedback_path: String) -> Array:
	var rows := _read_jsonl(inbox_path)
	# last-wins collapse by id (append-only correction: a re-push of the same id supersedes)
	var by_id := {}
	var order: Array = []
	for row in rows:
		var id := String(row.get("id", ""))
		if id == "":
			continue
		if not by_id.has(id):
			order.append(id)
		by_id[id] = row
	var hidden := hidden_ids(feedback_path)
	var out: Array = []
	for id in order:
		var row: Dictionary = by_id[id]
		if hidden.has(id):
			continue
		if String(row.get("status", "pending")) != "pending":
			continue
		out.append(normalize_card(row))
	return out

## The set (Dictionary used as set) of ids whose LATEST feedback action hides them.
## Latest-action-wins: skip → hidden; skip then unskip → visible again.
static func hidden_ids(feedback_path: String) -> Dictionary:
	var latest := {}
	for row in _read_jsonl(feedback_path):
		var id := String(row.get("artifact_id", row.get("tile_id", "")))
		var act := String(row.get("action", "")).strip_edges().to_lower()
		if id != "" and act != "":
			latest[id] = act
	var hidden := {}
	for id in latest.keys():
		if not UNHIDE_ACTIONS.has(latest[id]):
			hidden[id] = true
	return hidden

# ---------------------------------------------------------------------------------------------------
# normalization — one canonical card shape for every renderer
# ---------------------------------------------------------------------------------------------------

## Normalize one raw inbox/artifact row into the canonical card dict every consumer renders from.
static func normalize_card(row: Dictionary) -> Dictionary:
	var media: Dictionary = row.get("media", {}) if typeof(row.get("media")) == TYPE_DICTIONARY else {}
	var images: Array = []
	var multi = media.get("images")
	if typeof(multi) == TYPE_ARRAY:
		for u in multi:
			var p := _local_path(String(u))
			if p != "":
				images.append(p)
	if images.is_empty():
		var raw_one = media.get("image_url")
		var one := _local_path(String(raw_one)) if raw_one != null else ""
		if one != "":
			images.append(one)
	var actions: Array = []
	var raw_actions = row.get("actions")
	if typeof(raw_actions) == TYPE_ARRAY:
		for a in raw_actions:
			if typeof(a) == TYPE_DICTIONARY and a.has("id"):
				actions.append({ "id": String(a.get("id")), "label": String(a.get("label", a.get("id"))) })
	return {
		"id": String(row.get("id", "")),
		"kind": String(row.get("kind", "artifact")),
		"title": String(row.get("title", "")),
		"subtitle": _str_or_empty(row.get("subtitle")),
		"summary": _str_or_empty(row.get("summary")),
		"text": _str_or_empty(media.get("text")),
		"link": _str_or_empty(media.get("link")),
		"images": images,
		"actions": actions,
		"disposition": String(row.get("disposition", "content")),
		"generation": int(row.get("generation")) if row.has("generation") and row.get("generation") != null else -1,
		"source_session": String(row.get("source_session", "")),
	}

## Resolve a media URL to a LOCAL filesystem path when possible: file://G:/... and plain drive
## paths pass through (file:// stripped); http(s) URLs are returned verbatim (the renderer
## decides whether it can show them); empty/null → "".
static func _local_path(url: String) -> String:
	var u := url.strip_edges()
	if u == "" or u == "null":
		return ""
	if u.begins_with("file://"):
		var p := u.substr(7)
		# file:///G:/x and file://G:/x both appear in the substrate — strip a lone leading slash
		# before a drive letter.
		if p.length() > 2 and p[0] == "/" and p[2] == ":":
			p = p.substr(1)
		return p
	return u

## True when a path is loadable from the local filesystem (not an http(s) URL).
static func is_local(path: String) -> bool:
	return path != "" and not path.begins_with("http://") and not path.begins_with("https://")

static func _str_or_empty(v) -> String:
	if v == null:
		return ""
	return String(v)

static func _read_jsonl(path: String) -> Array:
	var out: Array = []
	if path == "" or not FileAccess.file_exists(path):
		return out
	var text := FileAccess.get_file_as_string(path)
	for line in text.split("\n"):
		line = line.strip_edges()
		if line == "":
			continue
		var row = JSON.parse_string(line)
		if typeof(row) == TYPE_DICTIONARY:
			out.append(row)
	return out
