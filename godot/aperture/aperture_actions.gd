class_name ApertureActions
extends RefCounted
## The WRITE half of the Godot Aperture's full equivalence with the web board: skip (✕),
## bookmark (★), and the evolver verbs (evolve/save/cull) all write through the SAME channel
## the web surface uses. Channel selection is DATA (config.mode), mirroring the read side:
##   - "http": POST to the live server — /api/aperture/feedback {artifact_id, action} for
##             decisions (exactly what aperture.js postSkip / evolver buttons send) and
##             /api/aperture/bookmark {tile_id, title, image_url, action?} for saves.
##   - "file": append the SAME schema rows the server-side tools write, directly to the
##             substrate files — feedback rows byte-compatible with aperture_feedback.record
##             ({artifact_id, action, decided_at, by}) and bookmark rows byte-compatible with
##             aperture_bookmark.record ({tile_id, saved_at, by, ...}). This is the :8770-down
##             fallback AND, pointed at a temp dir, the zero-pollution mock mode for tests
##             (aperture_feedback.py reads back what this writes — proven in the headless test).
##
## Routing mirrors the web client exactly: bookmark/unbookmark → the bookmark channel;
## everything else (skip/unskip/evolve/save/cull/...) → the feedback/decision channel.

## config keys (all DATA):
##   mode           "http" | "file"
##   base_url       http mode — server origin (default http://127.0.0.1:8770)
##   feedback_path  file mode — feedback.jsonl to append decisions to
##   bookmarks_path file mode — bookmarks.jsonl to append saves to
##   by             actor recorded on file-mode rows (default "liam" — the same actor the
##                  server records for surface clicks; the Godot surface IS Liam clicking)
var config: Dictionary = {}

func _init(cfg: Dictionary = {}) -> void:
	config = cfg

## Record one action on a card. `card` is a normalized card dict (or {"id": ...}).
## Returns { ok, channel ("feedback"|"bookmark"), mode, action, id, [status], [error] }.
func act(card: Dictionary, action: String, comment: String = "") -> Dictionary:
	var id := String(card.get("id", ""))
	var act_l := action.strip_edges().to_lower()
	if id == "" or act_l == "":
		return { "ok": false, "error": "card id and action required" }
	if act_l in ["bookmark", "unbookmark", "unsave"]:
		return _bookmark(card, "" if act_l == "bookmark" else "unbookmark")
	return _feedback(id, act_l, comment)

# ---------------------------------------------------------------------------------------------------
# decision channel (skip / unskip / evolve / save / cull / ...) → feedback.jsonl
# ---------------------------------------------------------------------------------------------------

func _feedback(id: String, action: String, comment: String) -> Dictionary:
	var mode := String(config.get("mode", "file"))
	if mode == "http":
		var payload := { "artifact_id": id, "action": action }
		if comment != "":
			payload["comment"] = comment
		var res := _http_post_json("/api/aperture/feedback", payload)
		res["channel"] = "feedback"; res["mode"] = mode; res["action"] = action; res["id"] = id
		return res
	# file mode — the EXACT row aperture_feedback.record appends.
	var row := {
		"artifact_id": id,
		"action": action,
		"decided_at": now_iso(),
		"by": String(config.get("by", "liam")),
	}
	if comment.strip_edges() != "":
		row["comment"] = comment.strip_edges()
	var ok := _append_row(String(config.get("feedback_path", "")), row)
	return { "ok": ok, "channel": "feedback", "mode": mode, "action": action, "id": id }

# ---------------------------------------------------------------------------------------------------
# bookmark channel (★ save / un-save) → bookmarks.jsonl
# ---------------------------------------------------------------------------------------------------

func _bookmark(card: Dictionary, toggle_action: String) -> Dictionary:
	var id := String(card.get("id", ""))
	var mode := String(config.get("mode", "file"))
	var images: Array = card.get("images", [])
	var image_url := String(images[0]) if images.size() > 0 else ""
	if mode == "http":
		var payload := { "tile_id": id, "title": String(card.get("title", "")) }
		if image_url != "":
			payload["image_url"] = image_url
		if String(card.get("link", "")) != "":
			payload["link_url"] = String(card.get("link"))
		if toggle_action != "":
			payload["action"] = toggle_action
		var res := _http_post_json("/api/aperture/bookmark", payload)
		res["channel"] = "bookmark"; res["mode"] = mode
		res["action"] = toggle_action if toggle_action != "" else "bookmark"; res["id"] = id
		return res
	# file mode — the EXACT row aperture_bookmark.record appends (tile_id/saved_at/by first,
	# optional action toggle, then the denormalized context keys it stores when present).
	var row := {
		"tile_id": id,
		"saved_at": now_iso(),
		"by": String(config.get("by", "liam")),
	}
	if toggle_action != "":
		row["action"] = toggle_action
	if String(card.get("title", "")) != "":
		row["title"] = String(card.get("title"))
	if String(card.get("link", "")) != "":
		row["link_url"] = String(card.get("link"))
	if image_url != "":
		row["image_url"] = image_url
	var ok := _append_row(String(config.get("bookmarks_path", "")), row)
	return { "ok": ok, "channel": "bookmark", "mode": mode,
		"action": toggle_action if toggle_action != "" else "bookmark", "id": id }

# ---------------------------------------------------------------------------------------------------
# transports
# ---------------------------------------------------------------------------------------------------

## Append one JSON row to a JSONL file (creating parent dirs + the file on first write).
## Append-only by construction — mirrors the python tools' open("a") semantics.
static func _append_row(path: String, row: Dictionary) -> bool:
	if path == "":
		return false
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var f := FileAccess.open(abs, FileAccess.READ_WRITE)
	if f == null:
		f = FileAccess.open(abs, FileAccess.WRITE)
	if f == null:
		return false
	f.seek_end()
	f.store_line(JSON.stringify(row))
	f.close()
	return true

## Synchronous localhost POST via a blocking HTTPClient poll loop (the surface's action write is
## a single small localhost round-trip; an async request machine would be overkill here).
func _http_post_json(api_path: String, payload: Dictionary, timeout_ms: int = 4000) -> Dictionary:
	var base := String(config.get("base_url", "http://127.0.0.1:8770"))
	var host := base.trim_prefix("http://").trim_prefix("https://")
	var port := 80
	if ":" in host:
		var parts := host.split(":")
		host = parts[0]
		port = int(parts[1])
	var client := HTTPClient.new()
	if client.connect_to_host(host, port) != OK:
		return { "ok": false, "error": "connect failed" }
	var waited := 0
	while client.get_status() in [HTTPClient.STATUS_CONNECTING, HTTPClient.STATUS_RESOLVING]:
		client.poll()
		OS.delay_msec(10); waited += 10
		if waited > timeout_ms:
			return { "ok": false, "error": "connect timeout" }
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		return { "ok": false, "error": "server unreachable (status %d)" % client.get_status() }
	var body := JSON.stringify(payload)
	client.request(HTTPClient.METHOD_POST, api_path, ["Content-Type: application/json"], body)
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		client.poll()
		OS.delay_msec(10); waited += 10
		if waited > timeout_ms:
			return { "ok": false, "error": "request timeout" }
	if client.get_status() not in [HTTPClient.STATUS_BODY, HTTPClient.STATUS_CONNECTED]:
		return { "ok": false, "error": "request failed (status %d)" % client.get_status() }
	var code := client.get_response_code()
	var chunks := PackedByteArray()
	while client.get_status() == HTTPClient.STATUS_BODY:
		client.poll()
		var chunk := client.read_response_body_chunk()
		if chunk.size() > 0:
			chunks.append_array(chunk)
		else:
			OS.delay_msec(5); waited += 5
			if waited > timeout_ms:
				break
	client.close()
	var parsed = JSON.parse_string(chunks.get_string_from_utf8())
	var ok := code >= 200 and code < 300
	if typeof(parsed) == TYPE_DICTIONARY and parsed.has("ok"):
		ok = ok and bool(parsed.get("ok"))
	return { "ok": ok, "status": code }

## ISO-8601 UTC to the second with the trailing Z — the same format the python tools stamp.
static func now_iso() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"
