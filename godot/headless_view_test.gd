extends SceneTree
## Headless verification of the renderer-NEUTRAL View/Camera primitive — the "single scene ->
## static view" keystone. Proves the camera is DATA (a glTF-2.0 camera descriptor on a `view` wire),
## that the Godot delegate builds a live Camera3D from it, that it FRAMES IDENTICALLY to the prior
## hardcoded camera (parity), that a no-View arrangement still renders with the fallback camera, and
## that the view round-trips through glTF as a camera node (portable to three.js / model-viewer).
##
##   godot --headless --path godot -s res://headless_view_test.gd
##
## Asserts:
##   (a) a View node emits the expected glTF-2.0-camera descriptor (DATA, JSON-serializable);
##   (b) the delegate-built View camera FRAMES IDENTICALLY to the prior hardcoded main.gd camera
##       (same transform + fov) — the parity that lets the camera become data without changing looks;
##   (c) a no-View arrangement still renders its scene (the additive fallback path is intact);
##   (d) a scene Group + a View together export to a GLB carrying a glTF camera node, and the GLB
##       re-imports with that camera intact (portable single-scene view).

const VIEW_POS := [2.5, 2.0, 3.5]
const EXPORT_PATH := "res://live/view.glb"

func _initialize() -> void:
	var ok := true
	var glb := "user://view_box.glb"
	ok = _check("box GLB fixture exported", _make_box_glb(glb) == OK) and ok

	# --- (a) the View primitive emits the expected glTF-2.0-camera descriptor as DATA -----------
	var view_params := { "position": VIEW_POS, "look_at": [0.0, 0.0, 0.0], "yfov": 75.0, "znear": 0.05, "zfar": 4000.0 }
	var rt := GraphRuntime.new()
	get_root().add_child(rt)
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "cam", "type": "View", "params": view_params }
		],
		"wires": []
	})
	var outputs := rt.evaluate()
	var view = outputs.get("cam", {}).get("view")

	ok = _check("View emits a Dictionary descriptor (not a live Camera3D)", typeof(view) == TYPE_DICTIONARY) and ok
	ok = _check("descriptor is a glTF perspective camera",
		typeof(view) == TYPE_DICTIONARY and String(view.get("type", "")) == "perspective") and ok
	ok = _check("descriptor yfov is in RADIANS (75deg -> ~1.309)",
		typeof(view) == TYPE_DICTIONARY and abs(float(view.get("yfov", 0.0)) - deg_to_rad(75.0)) < 1e-5) and ok
	ok = _check("descriptor carries znear/zfar clip planes",
		typeof(view) == TYPE_DICTIONARY and abs(float(view.get("znear", 0.0)) - 0.05) < 1e-6 and abs(float(view.get("zfar", 0.0)) - 4000.0) < 1e-3) and ok
	var trs = view.get("transform") if typeof(view) == TYPE_DICTIONARY else null
	ok = _check("descriptor transform.translation == camera position",
		typeof(trs) == TYPE_DICTIONARY and _approx_arr(trs.get("translation"), VIEW_POS)) and ok
	ok = _check("descriptor carries the look_at aim point",
		typeof(view) == TYPE_DICTIONARY and _approx_arr(view.get("look_at"), [0.0, 0.0, 0.0])) and ok
	ok = _check("descriptor is JSON round-trippable (no live objects)",
		typeof(view) == TYPE_DICTIONARY and typeof(JSON.parse_string(JSON.stringify(view))) == TYPE_DICTIONARY) and ok
	ok = _check("the view's port type is 'view' (id %d)" % PortTypes.type_id("view"),
		rt.port_type("View", "view", false) == "view" and PortTypes.type_id("view") == 11) and ok

	# --- (b) PARITY: the delegate-built View camera frames IDENTICALLY to the old hardcoded one ---
	# The prior hardcoded camera (main.gd._add_view): position (2.5,2.0,3.5), look_at origin, default fov.
	# We build the EXPECTED reference transform tree-independently (Basis.looking_at, the exact math
	# Node3D.look_at applies once its global transform is valid) so the parity check doesn't depend on a
	# headless process_frame to settle — and a real Camera3D for the default fov value.
	var hardcoded_pos := Vector3(2.5, 2.0, 3.5)
	var hardcoded_xform := Transform3D(Basis.looking_at(Vector3.ZERO - hardcoded_pos, Vector3.UP), hardcoded_pos)
	var _fov_probe := Camera3D.new()
	var hardcoded_fov := _fov_probe.fov   # Camera3D's DEFAULT fov — what main.gd's hardcoded cam used
	_fov_probe.free()

	var renderer := GodotSceneRenderer.new()
	get_root().add_child(renderer)
	renderer.render(outputs, rt.arrangement)
	var view_cam := renderer.apply_view(outputs, rt.arrangement, renderer)
	ok = _check("delegate built a live Camera3D from the view descriptor", view_cam != null and view_cam is Camera3D) and ok
	# Compare LOCAL transforms: view_cam sits under the renderer (identity under root), so local ==
	# global without needing a process_frame to propagate the global-transform cache in headless mode.
	ok = _check("View camera is at the same position as the hardcoded camera",
		view_cam != null and view_cam.transform.origin.is_equal_approx(hardcoded_xform.origin)) and ok
	ok = _check("View camera has the same orientation (basis) as the hardcoded camera (look_at parity)",
		view_cam != null and view_cam.transform.basis.is_equal_approx(hardcoded_xform.basis)) and ok
	ok = _check("View camera fov == hardcoded camera fov (framing parity)",
		view_cam != null and abs(view_cam.fov - hardcoded_fov) < 1e-3) and ok
	ok = _check("applying the View made it the CURRENT camera (takes over from fallback)",
		view_cam != null and view_cam.current) and ok
	# The scene still rendered alongside the camera (render() untouched by the camera branch).
	ok = _check("scene still rendered (one scene_node node built next to the camera)",
		renderer.get_child_count() >= 2) and ok  # >=1 scene node + the ViewCamera

	# Hotload re-drives the SAME camera instance (re-wire, not rebuild).
	var view_params2 := view_params.duplicate(true)
	view_params2["position"] = [4.0, 1.0, 4.0]
	rt.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "cam", "type": "View", "params": view_params2 }
		],
		"wires": []
	})
	var outputs2 := rt.evaluate()
	renderer.render(outputs2, rt.arrangement)
	var view_cam2 := renderer.apply_view(outputs2, rt.arrangement, renderer)
	ok = _check("hotload kept the SAME camera instance (re-driven, not rebuilt)", view_cam != null and view_cam == view_cam2) and ok
	ok = _check("hotload moved the camera to (4,1,4)",
		view_cam2 != null and view_cam2.transform.origin.is_equal_approx(Vector3(4, 1, 4))) and ok

	# --- (c) the no-View fallback path still renders (camera branch is purely additive) ----------
	var rtf := GraphRuntime.new()
	get_root().add_child(rtf)
	rtf.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "place", "type": "Transform", "params": { "position": [0, 0, 0] } }
		],
		"wires": [ { "from": "box", "out": "node", "to": "place", "in": "node" } ]
	})
	var outf := rtf.evaluate()
	var rendererf := GodotSceneRenderer.new()
	get_root().add_child(rendererf)
	rendererf.render(outf, rtf.arrangement)
	ok = _check("no-View arrangement: delegate still built the scene node", rendererf.get_child_count() == 1) and ok
	var no_view := rendererf.apply_view(outf, rtf.arrangement, rendererf)
	ok = _check("no-View arrangement: apply_view is a no-op (returns null, no camera built)",
		no_view == null and rendererf.get_child_count() == 1) and ok

	# --- (c2) had-then-removed: View-present -> hotload-to-no-View RESTORES the host fallback ------
	# The regression case the never-had-a-View path (c) misses: on ONE renderer that ALREADY has a
	# current ViewCamera, hotloading to an arrangement with NO View must release the ViewCamera so the
	# host's hardcoded fallback camera resumes control. We use a DEDICATED SubViewport so the camera
	# set is exactly the realistic {fallback, ViewCamera} — matching a real game's single-fallback
	# topology, not the test root viewport which by here holds many leftover cameras from parts (a)-(c).
	# We assert against the VIEWPORT's active camera (get_camera_3d()), the authoritative signal: Godot
	# propagates a `current=true` takeover on the NEXT frame (deferred), so we await a frame before
	# asserting takeover; a `current=false` release restores the remaining camera synchronously.
	var viewport := SubViewport.new()
	get_root().add_child(viewport)
	var fallback := Camera3D.new()
	viewport.add_child(fallback)
	fallback.current = true   # the host's fallback is current before any View takes over
	var rths := GraphRuntime.new()
	viewport.add_child(rths)
	var renderer_hs := GodotSceneRenderer.new()
	viewport.add_child(renderer_hs)
	# (1) render WITH a View: the ViewCamera becomes the active viewport camera, ousting the fallback.
	rths.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [ { "id": "cam", "type": "View", "params": { "position": VIEW_POS, "look_at": [0, 0, 0] } } ],
		"wires": []
	})
	var outs_hs := rths.evaluate()
	renderer_hs.render(outs_hs, rths.arrangement)
	var hs_cam := renderer_hs.apply_view(outs_hs, rths.arrangement, renderer_hs)
	await process_frame   # let Godot propagate the deferred current-camera takeover
	ok = _check("had-then-removed (1): a View becomes the active viewport camera (ousts the fallback)",
		hs_cam != null and viewport.get_camera_3d() == hs_cam and viewport.get_camera_3d() != fallback) and ok
	# (2) hotload to NO View on the SAME renderer: the ViewCamera must be released + the fallback resume.
	rths.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [
			{ "id": "box", "type": "Model", "params": { "path": glb, "name": "box_model" } },
			{ "id": "place", "type": "Transform", "params": { "position": [0, 0, 0] } }
		],
		"wires": [ { "from": "box", "out": "node", "to": "place", "in": "node" } ]
	})
	var outs_hs2 := rths.evaluate()
	renderer_hs.render(outs_hs2, rths.arrangement)
	var hs_cam2 := renderer_hs.apply_view(outs_hs2, rths.arrangement, renderer_hs)
	ok = _check("had-then-removed (2): no-View hotload returns null (ViewCamera released)", hs_cam2 == null) and ok
	ok = _check("had-then-removed (2): the released ViewCamera is no longer current",
		not (is_instance_valid(hs_cam) and hs_cam.current)) and ok
	ok = _check("had-then-removed (2): the host fallback camera resumed control of the viewport",
		fallback.current and viewport.get_camera_3d() == fallback) and ok
	# (3) re-adding a View on the same renderer works again (rebuilds a fresh ViewCamera, takes over).
	rths.load_arrangement({
		"format": "resonance.arrangement/v1",
		"nodes": [ { "id": "cam", "type": "View", "params": { "position": VIEW_POS, "look_at": [0, 0, 0] } } ],
		"wires": []
	})
	var outs_hs3 := rths.evaluate()
	renderer_hs.render(outs_hs3, rths.arrangement)
	var hs_cam3 := renderer_hs.apply_view(outs_hs3, rths.arrangement, renderer_hs)
	await process_frame
	ok = _check("had-then-removed (3): re-adding a View takes over the viewport again",
		hs_cam3 != null and viewport.get_camera_3d() == hs_cam3) and ok

	# --- (d) glTF camera round-trip: Group scene + View export to a GLB carrying a camera node ---
	DirAccess.make_dir_recursive_absolute("res://live")
	var scene_roots := []
	for nid in outputs.keys():
		var n = outputs[nid].get("node")
		if GodotSceneRenderer.is_scene_node(n):
			scene_roots.append(n)
	var bytes := GltfExporter.export_buffer(scene_roots, view)
	ok = _check("exported a non-empty GLB (geometry + view)", bytes.size() > 0) and ok
	var doc := GLTFDocument.new()
	var st := GLTFState.new()
	var imp_err := doc.append_from_buffer(bytes, "", st) if bytes.size() > 0 else FAILED
	ok = _check("exported GLB re-imports OK", imp_err == OK) and ok
	var cam_count := st.cameras.size() if imp_err == OK else 0
	ok = _check("re-imported GLB carries exactly one glTF camera node", cam_count == 1) and ok
	if cam_count == 1:
		var gcam: GLTFCamera = st.cameras[0]
		ok = _check("round-tripped camera is perspective", gcam.perspective) and ok
		ok = _check("round-tripped camera preserves yfov (~1.309 rad for 75deg, within tol)",
			abs(gcam.fov - deg_to_rad(75.0)) < 0.02) and ok
	var imp = doc.generate_scene(st) if imp_err == OK else null
	var has_cam_node := imp != null and _has_camera(imp)
	ok = _check("re-imported scene contains a live Camera3D node (portable to three.js / model-viewer)", has_cam_node) and ok
	if imp != null:
		imp.free()
	# Write the GLB to disk so the external validator gate can confirm spec-conformance with a camera.
	var wrote := GltfExporter.export_to_file(scene_roots, EXPORT_PATH, view)
	ok = _check("wrote %s for the validator gate" % EXPORT_PATH, wrote == OK and FileAccess.file_exists(EXPORT_PATH)) and ok

	print("RESULT: ", "ALL PASS" if ok else "FAILURES PRESENT")
	quit(0 if ok else 1)

# --- helpers ----------------------------------------------------------------

func _make_box_glb(path: String) -> int:
	var root := Node3D.new()
	root.name = "BoxRoot"
	var mi := MeshInstance3D.new()
	mi.name = "Box"
	mi.mesh = BoxMesh.new()
	root.add_child(mi)
	mi.owner = root
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_scene(root, state)
	if err == OK:
		err = doc.write_to_filesystem(state, path)
	root.free()
	return err

func _has_camera(n: Node) -> bool:
	if n is Camera3D:
		return true
	for c in n.get_children():
		if _has_camera(c):
			return true
	return false

func _approx_arr(a, b) -> bool:
	if not (a is Array) or (a as Array).size() < 3 or not (b is Array) or (b as Array).size() < 3:
		return false
	return abs(float(a[0]) - float(b[0])) < 1e-4 and abs(float(a[1]) - float(b[1])) < 1e-4 and abs(float(a[2]) - float(b[2])) < 1e-4

func _check(label: String, cond: bool) -> bool:
	print(("PASS " if cond else "FAIL ") + label)
	return cond
