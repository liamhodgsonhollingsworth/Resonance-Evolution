extends RefCounted
## WORLD STORE — arrangements persist as APPEND-ONLY versioned data files.
##
## Spec apx_e5c6f8dc: "compose scenes and rich worlds entirely from the editor ... starting
## the sandbox with a preselected arrangement that are preloaded and changing that as I move
## from scene to scene."
##
## LAYOUT (one directory per world, one immutable file per version):
##     <worlds_dir>/<world_name>/v0001.json
##     <worlds_dir>/<world_name>/v0002.json      <- save NEVER overwrites; it writes v(N+1)
##
## WHERE: the default worlds_dir is OUTSIDE this repo, in gitignored Wavelet state
## (G:/Wavelet/Alethea-cc/state/sandbox/worlds) — load-bearing user data must never live in
## a git-tracked file, because host launchers run git ops on this checkout at click time
## (the reset-hard-wipes-uncommitted-data lesson). Claude Code reads/writes the SAME files
## to iterate a world on disk — saving a new version while the sandbox runs hot-reloads it
## (the sandbox content-watches the latest version of the active world).
##
## SEED WORLDS: committed read-only starters under res://examples/worlds/*.json are copied
## into the store on first touch, so a fresh machine has something to open and every edit
## lands in versioned state, never in the repo file.
##
## WORLD FILE SHAPE (v2 — supersets the sandbox_params block list):
##   { "format": "sandbox.world/v2", "name": "...",
##     "blocks":  [ {cell:[x,y,z], block:"Cube", material?:{}} ],
##     "objects": [ {id, asset, position:[x,y,z], yaw_deg, scale, behaviors:[{type,params}]} ] }
##
## No class_name (mistake #046): consumers preload() this file by path.

const DEFAULT_WORLDS_DIR := "G:/Wavelet/Alethea-cc/state/sandbox/worlds"
const SEED_DIR := "res://examples/worlds"
const FORMAT := "sandbox.world/v2"

var worlds_dir: String = DEFAULT_WORLDS_DIR


func _init(dir: String = "") -> void:
	if dir != "":
		worlds_dir = dir


## Copy every committed seed world that is not yet in the store (first-run bootstrap).
## Never overwrites store content. Returns the names seeded.
func seed_from(seed_dir: String = SEED_DIR) -> Array:
	var seeded := []
	var d := DirAccess.open(seed_dir)
	if d == null:
		return seeded
	DirAccess.make_dir_recursive_absolute(worlds_dir)
	for f in d.get_files():
		if not f.ends_with(".json"):
			continue
		var name := f.get_basename()
		if latest_version(name) > 0:
			continue
		var text := FileAccess.get_file_as_string(seed_dir.path_join(f))
		var data = JSON.parse_string(text)
		if typeof(data) == TYPE_DICTIONARY:
			save_version(name, data)
			seeded.append(name)
	return seeded


## Every world in the store, sorted by name.
func list_worlds() -> Array:
	var out := []
	var d := DirAccess.open(worlds_dir)
	if d == null:
		return out
	for sub in d.get_directories():
		if latest_version(sub) > 0:
			out.append(sub)
	out.sort()
	return out


## Highest saved version number for a world (0 = world does not exist).
func latest_version(name: String) -> int:
	var d := DirAccess.open(worlds_dir.path_join(name))
	if d == null:
		return 0
	var best := 0
	for f in d.get_files():
		if f.begins_with("v") and f.ends_with(".json"):
			best = maxi(best, int(f.substr(1).get_basename()))
	return best


func version_path(name: String, version: int) -> String:
	return worlds_dir.path_join(name).path_join("v%04d.json" % version)


func latest_path(name: String) -> String:
	var v := latest_version(name)
	return version_path(name, v) if v > 0 else ""


## Load the latest (or a specific) version. {} when missing/invalid.
func load_world(name: String, version: int = 0) -> Dictionary:
	var v := version if version > 0 else latest_version(name)
	if v <= 0:
		return {}
	var path := version_path(name, v)
	if not FileAccess.file_exists(path):
		return {}
	var data = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		return {}
	data["name"] = name
	data["version"] = v
	return data


## APPEND-ONLY save: writes version latest+1, never touching prior files.
## Returns the new version number (0 on failure).
func save_version(name: String, data: Dictionary) -> int:
	var v := latest_version(name) + 1
	var dir := worlds_dir.path_join(name)
	DirAccess.make_dir_recursive_absolute(dir)
	var out := data.duplicate(true)
	# Preserve the payload's OWN format tag when it carries one (the sandbox now persists a
	# resonance.arrangement/v1 graph — every room is a node arrangement). Only stamp the legacy default
	# when the caller supplied no format, so old sandbox.world/v2 callers are unchanged (append-only).
	if not out.has("format") or String(out["format"]).strip_edges() == "":
		out["format"] = FORMAT
	out["name"] = name
	out["version"] = v
	out["saved_utc"] = Time.get_datetime_string_from_system(true) + "Z"
	var f := FileAccess.open(version_path(name, v), FileAccess.WRITE)
	if f == null:
		push_warning("WorldStore: cannot write %s" % version_path(name, v))
		return 0
	f.store_string(JSON.stringify(out, "\t"))
	f.close()
	return v


## The asset ids a world needs loaded — its PRELOAD SET (derived from its objects, so no
## hand-maintained list can go stale).
static func preload_set_of(world: Dictionary) -> Array:
	var ids := {}
	for o in world.get("objects", []):
		if typeof(o) == TYPE_DICTIONARY and o.has("asset"):
			ids[String(o["asset"])] = true
	return ids.keys()
