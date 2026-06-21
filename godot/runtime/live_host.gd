class_name LiveHost
extends Node
## Watches an arrangement file and hotloads it into a running GraphRuntime whenever the
## file's CONTENT changes — the "live, parallel hotloading" loop. When Claude Code (or
## you) rewrites the arrangement on disk, the running game re-wires its already-loaded
## primitives with no restart.
##
## Change detection is by CONTENT HASH, not modified-time: Godot's get_modified_time has
## 1-second resolution (two quick edits share a timestamp), and a content hash also gives
## us free idempotence (re-saving identical data does nothing). This mirrors the project's
## content-addressing throughout.

## Emitted after a successful reload + evaluate, so a consumer (e.g. the renderer delegate)
## can rebuild from the fresh evaluate() output without LiveHost knowing anything about
## rendering. No-op for headless tests that don't connect it.
signal reloaded

var runtime: GraphRuntime = null
var path: String = ""
var poll_interval := 0.25

## The monotonic revision of the arrangement last loaded (top-level `rev`, stamped by the shared
## graph_store write seam — see CONNECTION-CONTRACT.md §5). A consumer reads this after `reloaded`
## to order changes / detect that it is behind. 0 if the arrangement carries no rev yet.
var rev := 0

var _last_hash := ""
var _accum := 0.0

func _process(delta: float) -> void:
	if runtime == null or path == "":
		return
	_accum += delta
	if _accum < poll_interval:
		return
	_accum = 0.0
	poll_once()

## Check the file once; reload + re-evaluate if its content changed. Returns true if a
## reload happened. Called every poll_interval in a running game; called directly in tests.
func poll_once() -> bool:
	if runtime == null or path == "" or not FileAccess.file_exists(path):
		return false
	var text := FileAccess.get_file_as_string(path)
	var h := text.sha256_text()
	if h == _last_hash:
		return false
	_last_hash = h
	var data = JSON.parse_string(text)
	if typeof(data) != TYPE_DICTIONARY:
		push_error("LiveHost: '%s' is not a valid arrangement JSON" % path)
		return false
	runtime.load_arrangement(data)
	runtime.evaluate()
	rev = int(data.get("rev", 0))
	reloaded.emit()
	return true
