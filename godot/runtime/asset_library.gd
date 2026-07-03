extends Node
## LAZY ASSET LIBRARY — every imported asset available, NONE loaded at startup.
##
## Spec (Liam, card apx_e5c6f8dc, 2026-07-03): "efficient for having any number of assets by
## not having them loaded when the game starts up and instead loading them when they are
## needed, or starting the sandbox with a preselected arrangement that are preloaded and
## changing that as I move from scene to scene."
##
## HOW IT WORKS
##   * At startup only godot/assets/manifest.json is read (metadata: id/path/kit/tags —
##     a few KB regardless of how many assets exist). Zero GLB bytes touched.
##   * `request(id)` loads an asset ON DEMAND: GLB parsing (GLTFDocument.append_from_file —
##     the file read + parse, the expensive part) runs on a WorkerThreadPool background
##     thread; node generation (generate_scene) happens on the main thread when the parse
##     lands. The caller shows a placeholder until `asset_ready` fires.
##   * `preload_set(ids)` warms the cache for an arrangement's asset set (the "preselected
##     arrangement that are preloaded" path); `evict_except(keep)` releases everything a
##     newly-entered arrangement does not use (the "changing that as I move from scene to
##     scene" path) so memory tracks the CURRENT scene, not the whole catalog.
##   * Loaded templates are cached; `instantiate(id)` hands out duplicate()s, so placing the
##     same asset 100 times costs one load.
##
## Deliberately NO class_name: outside the editor class_name globals resolve via the
## gitignored .godot class cache (mistake #046) — consumers preload() this file by path.
## Runtime GLTF loading (not ResourceLoader) so it works with or without a .godot import
## cache — same rationale as GodotSceneRenderer._load_glb.

signal asset_ready(id: String)
signal asset_failed(id: String)

const MANIFEST_PATH := "res://assets/manifest.json"

var manifest: Dictionary = {}        # id -> manifest entry {id,name,path,type,kit,tags,...}
var kits: Array = []                 # kit names, manifest order

var _cache: Dictionary = {}          # id -> template Node3D (NOT in tree; instantiate() duplicates)
var _pending: Dictionary = {}        # id -> { "task": int, "state": GLTFState, "done": bool[shared] }
var _failed: Dictionary = {}         # id -> true (do not retry every frame)
var loads_completed := 0             # stats for the bench / tests


func _ready() -> void:
	set_process(_pending.size() > 0)


## Read the manifest (metadata only — this is ALL the startup cost). Safe to call again to
## re-read after a regeneration. Returns the number of assets indexed.
func load_manifest(path: String = MANIFEST_PATH) -> int:
	manifest = {}
	kits = []
	if not FileAccess.file_exists(path):
		push_warning("AssetLibrary: no manifest at %s" % path)
		return 0
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		push_warning("AssetLibrary: manifest is not valid JSON: %s" % path)
		return 0
	for k in data.get("kits", []):
		kits.append(String(k))
	for a in data.get("assets", []):
		if typeof(a) == TYPE_DICTIONARY and a.has("id") and a.has("path"):
			manifest[String(a["id"])] = a
	return manifest.size()


func has_asset(id: String) -> bool:
	return manifest.has(id)


func entry(id: String) -> Dictionary:
	return manifest.get(id, {})


## All manifest entries of one kit (inventory tab content), manifest order.
func kit_assets(kit: String) -> Array:
	var out := []
	for id in manifest:
		if String(manifest[id].get("kit", "")) == kit:
			out.append(manifest[id])
	out.sort_custom(func(a, b): return String(a["id"]) < String(b["id"]))
	return out


func is_loaded(id: String) -> bool:
	return _cache.has(id)


func is_pending(id: String) -> bool:
	return _pending.has(id)


## Begin loading an asset in the background (no-op if cached / already in flight / unknown).
## `asset_ready(id)` fires on the main thread when instantiate(id) will succeed.
func request(id: String) -> void:
	if _cache.has(id) or _pending.has(id) or _failed.has(id) or not manifest.has(id):
		return
	var path := String(manifest[id]["path"])
	var state := GLTFState.new()
	# `done` is a one-element shared array: the worker flips it, the main thread polls it.
	var done := [false, OK]
	var task := WorkerThreadPool.add_task(func():
		var doc := GLTFDocument.new()
		done[1] = doc.append_from_file(path, state)
		done[0] = true
	)
	_pending[id] = { "task": task, "state": state, "done": done }
	set_process(true)


## Synchronous load (headless tests + the --eager bench mode). Parses AND generates inline.
func request_sync(id: String) -> bool:
	if _cache.has(id):
		return true
	if not manifest.has(id):
		return false
	var path := String(manifest[id]["path"])
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		_failed[id] = true
		return false
	return _finish(id, state)


## Warm the cache for an arrangement's asset set (background). The "preselected arrangement
## that are preloaded" path.
func preload_set(ids: Array) -> void:
	for id in ids:
		request(String(id))


## Release every cached/in-flight asset NOT in `keep` — called when moving scene to scene so
## memory tracks the current arrangement. Returns how many templates were freed.
func evict_except(keep: Array) -> int:
	var keep_set := {}
	for id in keep:
		keep_set[String(id)] = true
	var freed := 0
	for id in _cache.keys():
		if not keep_set.has(id):
			var tpl: Node = _cache[id]
			if is_instance_valid(tpl):
				tpl.free()          # templates are NOT in the tree; free directly
			_cache.erase(id)
			freed += 1
	for id in _pending.keys():
		if not keep_set.has(id):
			# Let the worker finish parsing (tasks are not cancellable) but drop the result.
			var p: Dictionary = _pending[id]
			WorkerThreadPool.wait_for_task_completion(int(p["task"]))
			_pending.erase(id)
	_failed.clear()                  # allow retries after a scene change
	return freed


## A fresh instance of a loaded asset, or null if it is not loaded yet (callers keep their
## placeholder up and try again on `asset_ready`).
func instantiate(id: String) -> Node3D:
	var tpl = _cache.get(id)
	if tpl == null or not is_instance_valid(tpl):
		return null
	var inst := (tpl as Node).duplicate() as Node3D
	return inst


func loaded_count() -> int:
	return _cache.size()


func pending_count() -> int:
	return _pending.size()


func _process(_delta: float) -> void:
	# Poll in-flight parses; generate nodes on the MAIN thread as each parse lands.
	if _pending.is_empty():
		set_process(false)
		return
	for id in _pending.keys():
		var p: Dictionary = _pending[id]
		var done: Array = p["done"]
		if not done[0]:
			continue
		WorkerThreadPool.wait_for_task_completion(int(p["task"]))
		_pending.erase(id)
		if int(done[1]) != OK:
			_failed[id] = true
			push_warning("AssetLibrary: failed to parse '%s'" % id)
			asset_failed.emit(id)
			continue
		if _finish(id, p["state"]):
			asset_ready.emit(id)
		else:
			asset_failed.emit(id)


func _finish(id: String, state: GLTFState) -> bool:
	var doc := GLTFDocument.new()
	var scene := doc.generate_scene(state)
	if scene == null:
		_failed[id] = true
		push_warning("AssetLibrary: failed to generate scene for '%s'" % id)
		return false
	var tpl := Node3D.new()
	tpl.name = id
	tpl.add_child(scene)
	_cache[id] = tpl
	loads_completed += 1
	return true
