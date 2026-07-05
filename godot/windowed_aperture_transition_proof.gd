extends SceneTree
## WINDOWED WALK-THROUGH PROOF (Liam 2026-07-05 defect verification; CENTRAL LESSON: a door that
## RENDERS is not a door that WORKS — you must walk THROUGH each portal in a real window and confirm
## the destination scene is LIVE + INTERACTIVE, not a frozen/black frame). This runs the REAL room,
## fires each door the way the room's walk-in does (SceneTransition.enter with the room's own door
## spec), then asserts the destination scene is up AND the transition cover has SELF-CLEANED (no stuck
## opaque black cover = the exact defect-#5 bug), captures a PNG of the live destination, and simulates
## ESC to confirm the destination is LEAVEABLE back to the room.
##
## Run WINDOWED (real renderer required — a black cover only shows in a live viewport):
##   <Godot(gui)> --path godot -s res://windowed_aperture_transition_proof.gd
## Writes docs/proof_dest_<label>.png per door + docs/proof_back_in_room.png. Exit 0 = all walk-throughs
## live + leaveable; nonzero = a portal is dead/black or not leaveable.

const SceneTransition := preload("res://aperture/scene_transition.gd")
const ROOM := "res://aperture/aperture_3d.tscn"

var _fail := 0

func _init() -> void:
	root.call_deferred("set_content_scale_size", Vector2i(1280, 720))
	_run.call_deferred()

func _run() -> void:
	if DisplayServer.get_name() == "headless":
		print("PROOF NEEDS A DISPLAY (windowed). Exit 2.")
		quit(2)
		return
	# Each door spec mirrors the room's door_specs exactly (same target the walk-in hands the transition).
	var doors := [
		{ "label": "dungeons", "scene": "res://examples/explore/explore_scene_demo.tscn", "same_window": true },
		{ "label": "gallery",  "scene": "res://gallery/gallery.tscn",                      "same_window": true },
		{ "label": "sandbox",  "scene": "res://examples/sandbox_creative.tscn",            "same_window": true },
	]
	for spec in doors:
		await _walk_through(spec)
	print("RESULT: ", "ALL PORTALS LIVE + LEAVEABLE" if _fail == 0 else ("%d PORTAL FAILURE(S)" % _fail))
	quit(0 if _fail == 0 else 1)

func _walk_through(spec: Dictionary) -> void:
	var label := String(spec["label"])
	var target_scene := String(spec["scene"])
	# 1) Enter the ROOM as the live scene.
	change_scene_to_file(ROOM)
	await _settle(20)
	var room := current_scene
	if room == null or room.scene_file_path != ROOM:
		_bad("[%s] room did not mount as current scene" % label)
		return
	# 2) WALK THROUGH the door: exactly what the room does when the player crosses the threshold.
	SceneTransition.enter(room, spec)
	# 3) Wait for the fade-to-black, the swap, and the overlay to SELF-CLEAN. Poll the overlay's own
	#    phase until it reports "live" (cover fully cleared) rather than guessing a frame count — heavy
	#    destination scenes (sandbox/explore) take longer, and a fixed wait would sample mid-fade.
	var waited := 0
	while waited < 600:
		await process_frame
		waited += 1
		var ov := root.get_node_or_null("__aperture_transition_overlay")
		if ov == null:
			break
		if String(ov.get("_phase")) == "live":
			break
	# 4) DESTINATION must be the target scene AND actually up.
	var dest := current_scene
	if dest == null or dest.scene_file_path != target_scene:
		_bad("[%s] destination is NOT %s (got %s) — portal dead" % [label, target_scene,
			"null" if dest == null else dest.scene_file_path])
		return
	# 5) The self-cleaning cover must NOT be a stuck opaque black frame (defect #5). Find the overlay's
	#    ColorRect and assert its alpha faded to ~0 AND it no longer blocks input.
	var overlay := root.get_node_or_null("__aperture_transition_overlay")
	var cover_ok := true
	var alpha := 0.0
	if overlay != null and overlay.get_child_count() > 0:
		var rect := overlay.get_child(0)
		if rect is ColorRect:
			alpha = (rect as ColorRect).color.a
			cover_ok = alpha < 0.05 and (rect as ColorRect).mouse_filter == Control.MOUSE_FILTER_IGNORE
	if not cover_ok:
		_bad("[%s] TRANSITION COVER STUCK (alpha=%.2f) — this IS the black-frozen-screen defect" % [label, alpha])
	else:
		print("PASS  [%s] destination LIVE: %s (cover cleared, alpha=%.2f)" % [label, target_scene, alpha])
	# 6) Capture the live destination frame (proves it renders content, not a black void).
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	var out := "res://docs/proof_dest_%s.png" % label
	img.save_png(out)
	print("      [%s] destination frame -> %s (%dx%d)" % [label, out, img.get_width(), img.get_height()])
	# 7) LEAVE = ESC: simulate the ESC keypress the overlay listens for; must return to the ROOM.
	var ev := InputEventKey.new()
	ev.keycode = KEY_ESCAPE
	ev.pressed = true
	Input.parse_input_event(ev)
	await _settle(60)
	if current_scene != null and current_scene.scene_file_path == ROOM:
		print("PASS  [%s] ESC returned to the aperture room" % label)
	else:
		_bad("[%s] ESC did NOT return to the room (got %s)" % [label,
			"null" if current_scene == null else current_scene.scene_file_path])

func _settle(frames: int) -> void:
	for _i in frames:
		await process_frame

func _bad(msg: String) -> void:
	_fail += 1
	print("FAIL  ", msg)
