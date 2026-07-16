class_name PhysicalSeedReader
extends RefCounted
## PhysicalSeedReader -- reads a "physical seed" (a small, minimal repeating unit-cell example) and
## normalizes it into ONE format-blind contract that any tiling generator can consume, per Liam's
## 2026-07-16 spec (Discord #dev, 02:11:38Z): "find a way that you can make the entire logic of the
## procedural generation based on a physical seed or example, such that all the logic can be changed
## using that example. if this needs to happen using logical blocks as physical objects, make sure
## this can happen in a physical format." Full design:
## notes/planning/physical_seed_procgen_design_2026_07_16.md (Wavelet repo).
##
## TWO BACKENDS, ONE OUTPUT SHAPE -- a caller (e.g. BrickPavementGenerator) never knows or cares which
## one produced its rule table:
##   read_data_json(path)  -- a small JSON file listing unit-cell members explicitly (offset/rotation/
##                             id) plus optional explicit lattice vectors. Fast, diffable, hand-editable
##                             without opening the engine at all.
##   read_scene_tscn(path) -- an actual Godot .tscn with real Node3D children physically arranged in
##                             the editor -- "logical blocks as physical objects" made literal. Reads
##                             each direct child's own position/rotation straight off its transform;
##                             lattice vectors are INFERRED from the member bounding box (no natural
##                             place to declare them explicitly in a hand-arranged scene).
##
## Output shape (both backends):
##   {
##     "members": Array of {"offset": Vector2 (world-space XZ, meters), "rotation_deg": float,
##                            "brick_id": String},
##     "lattice_a": Vector2, "lattice_b": Vector2,   -- the two tiling translation vectors (meters)
##     "brick_length": float, "brick_width": float,  -- real physical piece dims (meters), when the
##                                                       seed declares them (data_json only -- a
##                                                       scene_tscn seed has no natural place to
##                                                       declare these explicitly, so a caller falls
##                                                       back to its own default).
##   }
## Returns an empty members Array (and Vector2.ZERO lattice vectors) on any read failure -- callers
## degrade to "nothing to place" rather than crash, matching this corpus's fail-open posture for
## not-yet-ready/malformed external resources.


## Format A. `data_json` shape:
##   {"members": [{"offset": [x, z], "rotation_deg": float, "brick_id": String (optional)}, ...],
##    "lattice_a": [x, z] (optional), "lattice_b": [x, z] (optional)}
## When lattice_a/lattice_b are absent, they are inferred from the member bounding box (see
## `_infer_lattice`) -- same fallback both backends share.
static func read_data_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("PhysicalSeedReader.read_data_json: not found at %s" % path)
		return _empty()
	var text := FileAccess.get_file_as_string(path)
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY or not parsed.has("members"):
		push_error("PhysicalSeedReader.read_data_json: malformed seed at %s (expected {\"members\":[...]})" % path)
		return _empty()

	var members: Array = []
	for i in (parsed["members"] as Array).size():
		var m: Dictionary = parsed["members"][i]
		var off: Array = m.get("offset", [0.0, 0.0])
		members.append({
			"offset": Vector2(float(off[0]), float(off[1])),
			"rotation_deg": float(m.get("rotation_deg", 0.0)),
			"brick_id": String(m.get("brick_id", "brick_%d" % i)),
		})
	if members.is_empty():
		return _empty()

	var lattice_a: Vector2
	var lattice_b: Vector2
	if parsed.has("lattice_a") and parsed.has("lattice_b"):
		var la: Array = parsed["lattice_a"]
		var lb: Array = parsed["lattice_b"]
		lattice_a = Vector2(float(la[0]), float(la[1]))
		lattice_b = Vector2(float(lb[0]), float(lb[1]))
	else:
		var inferred := _infer_lattice(members)
		lattice_a = inferred["lattice_a"]
		lattice_b = inferred["lattice_b"]

	var out := {"members": members, "lattice_a": lattice_a, "lattice_b": lattice_b}
	if parsed.has("brick_length"):
		out["brick_length"] = float(parsed["brick_length"])
	if parsed.has("brick_width"):
		out["brick_width"] = float(parsed["brick_width"])
	return out


## Format B. Loads `path` as a PackedScene, instantiates it OFF-TREE (never added to the live scene
## tree -- this is a pure data-read, not a spawn), walks its direct Node3D children, and reads each
## one's position.x/position.z + rotation_degrees.y straight off the transform Liam (or a future
## session) set by hand in the Godot editor. The instantiated root is freed immediately after reading
## -- nothing from this call persists in the tree.
static func read_scene_tscn(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_error("PhysicalSeedReader.read_scene_tscn: not found at %s" % path)
		return _empty()
	var packed: Resource = load(path)
	if packed == null or not (packed is PackedScene):
		push_error("PhysicalSeedReader.read_scene_tscn: %s did not load as a PackedScene" % path)
		return _empty()
	var root := (packed as PackedScene).instantiate()
	var members: Array = []
	for child in root.get_children():
		if child is Node3D:
			var n3 := child as Node3D
			members.append({
				"offset": Vector2(n3.position.x, n3.position.z),
				"rotation_deg": n3.rotation_degrees.y,
				"brick_id": String(n3.name),
			})
	root.queue_free()
	if members.is_empty():
		return _empty()
	var inferred := _infer_lattice(members)
	return {"members": members, "lattice_a": inferred["lattice_a"], "lattice_b": inferred["lattice_b"]}


## Dispatch on file extension -- one call site for a caller that just has a "seed_handle" path and
## doesn't want to branch on format itself (matches KitGridPlacer's own "caller doesn't care about
## the loader's internals" ergonomics).
static func read(path: String) -> Dictionary:
	if path.ends_with(".tscn"):
		return read_scene_tscn(path)
	return read_data_json(path)


## §3.2 of the design doc: "tile the unit cell's own bounding box edge-to-edge with itself" -- the
## simplest correct default when no explicit periodicity is declared. Intentionally conservative
## (never overlaps; may leave a seam a hand-tuned lattice would tighten).
static func _infer_lattice(members: Array) -> Dictionary:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for m in members:
		var o: Vector2 = m["offset"]
		min_x = minf(min_x, o.x)
		max_x = maxf(max_x, o.x)
		min_z = minf(min_z, o.y)
		max_z = maxf(max_z, o.y)
	# A single-member unit cell has zero bbox extent -- fall back to a 1x1m default spacing so the
	# tiler still produces a sane (if arbitrary) result rather than dividing by zero downstream.
	var w := maxf(0.01, max_x - min_x) if members.size() > 1 else 1.0
	var h := maxf(0.01, max_z - min_z) if members.size() > 1 else 1.0
	return {"lattice_a": Vector2(w, 0.0), "lattice_b": Vector2(0.0, h)}


static func _empty() -> Dictionary:
	return {"members": [], "lattice_a": Vector2.ZERO, "lattice_b": Vector2.ZERO}
