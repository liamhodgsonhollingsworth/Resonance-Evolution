extends SceneTree
## Headless verification of the GALLERY sample scene — the SECOND scene over the renderer-neutral
## seam (alongside walkabout). Proves the seam is scene-agnostic: a different layout module assembles
## the same Model -> Transform DATA, evaluates it through GraphRuntime, and renders it through
## GodotSceneRenderer, with NO engine/foundation change.
##
##   <godot> --headless --path godot -s res://headless_gallery_test.gd
##
## Asserts:
##   (1) the gallery assembles a non-empty arrangement from the ingested assets (Model + Transform);
##   (2) the assembled arrangement runs through GraphRuntime to scene_node DATA;
##   (3) GodotSceneRenderer builds a live node per ringed asset from that data;
##   (4) the ring layout is genuinely circular: assets sit at ~RING_RADIUS from the center, spread out
##       (not all stacked at one point) — the property that distinguishes this scene from walkabout's grid;
##   (5) the scene instances + runs _ready without error (camera + orbiting ring pivot present).

const RING_RADIUS := 6.0

func _initialize() -> void:
	var ok := true

	# (1) the gallery assembles a non-empty arrangement directly (no window, no _ready needed).
	var gallery_script: GDScript = load("res://gallery/gallery.gd")
	var gallery = gallery_script.new()
	var arrangement: Dictionary = gallery.assemble_arrangement()
	var model_count := 0
	var transform_count := 0
	for n in arrangement.get("nodes", []):
		match String(n.get("type")):
			"Model": model_count += 1
			"Transform": transform_count += 1
	ok = _check("gallery assembled Model node(s) (run asset_ingest_gltf.py first)", model_count >= 1) and ok
	ok = _check("gallery paired each Model with a Transform (ring layout)",
		transform_count == model_count or model_count == 1) and ok

	# (2)+(3) assemble -> evaluate -> render
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement(arrangement)
	var outputs := rt.evaluate()
	ok = _check("runtime evaluated the gallery arrangement", not outputs.is_empty()) and ok
	var scene_nodes := 0
	for nid in outputs.keys():
		if GodotSceneRenderer.is_scene_node(outputs[nid].get("node")):
			scene_nodes += 1
	ok = _check("gallery produced scene_node descriptors", scene_nodes >= 1) and ok
	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, rt.arrangement)
	ok = _check("renderer built live node(s) for the ringed assets", renderer.get_child_count() >= 1) and ok

	# (4) the layout is genuinely a RING: every Transform's position is ~RING_RADIUS from the center on
	#     the XZ plane, and (when there's more than one asset) the positions are spread, not coincident.
	var positions := []
	for n in arrangement.get("nodes", []):
		if String(n.get("type")) == "Transform":
			var pos: Array = n.get("params", {}).get("position", [0, 0, 0])
			positions.append(Vector2(float(pos[0]), float(pos[2])))   # XZ
	var on_ring := true
	for p in positions:
		if abs(p.length() - RING_RADIUS) > 0.01:
			on_ring = false
	ok = _check("every ringed asset sits at ~RING_RADIUS from center (circular layout)",
		positions.is_empty() or on_ring) and ok
	if positions.size() >= 2:
		var p0: Vector2 = positions[0]
		var p1: Vector2 = positions[1]
		var spread: bool = p0.distance_to(p1) > 0.01
		ok = _check("ring positions are spread, not all stacked at one point", spread) and ok

	# (5) the scene instances + runs _ready cleanly (camera + orbiting ring pivot exist).
	get_root().add_child(gallery)
	await process_frame
	var has_cam := false
	var has_ring := false
	for c in gallery.get_children():
		if c is Camera3D:
			has_cam = true
		if c is Node3D and c.name == "Ring":
			has_ring = true
	ok = _check("gallery scene created its center Camera3D", has_cam) and ok
	ok = _check("gallery scene created its orbiting Ring pivot", has_ring) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
