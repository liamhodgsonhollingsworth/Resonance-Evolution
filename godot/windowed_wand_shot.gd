extends SceneTree
## WINDOWED proof screenshot of the PRECISE MANIPULATION WAND engaged on an object (Liam item 3 asks
## for "a screenshot"). Boots the real sandbox scene in a window, seeds a few objects, holds the wand,
## RIGHT-click-engages the front object (so the 3-axis gizmo appears), applies a visible precise rotate,
## renders a few frames, and writes docs/sandbox_wand.png. NOT headless (needs a renderer for the gizmo).
##
##   <console_exe> --path godot -s res://windowed_wand_shot.gd
##
## (Uses a small offscreen window; the proof PNG is the deliverable, committed under docs/.)

const SandboxScene := preload("res://examples/sandbox_creative.tscn")
const OUT := "res://docs/sandbox_wand.png"


func _initialize() -> void:
	OS.set_environment("SANDBOX_WORLDS_DIR", ProjectSettings.globalize_path("user://shot_wand_worlds"))
	OS.set_environment("SANDBOX_NOTES_PATH", ProjectSettings.globalize_path("user://shot_wand_notes.jsonl"))
	if DisplayServer.get_name() == "headless":
		print("[wand_shot] needs a display (run WITHOUT --headless). exit 2")
		quit(2)
		return
	var s = SandboxScene.instantiate()
	get_root().add_child(s)
	await process_frame

	# Seed a small scene: three primitive blocks in a row so the manipulated one reads against neighbours.
	s._seed_world({ "blocks": [] }, true)
	s._clear_objects()
	var mid: String = s._place_block_free(s._palette_index("Cube"), Vector3(0, 0.5, 0), 0.0)
	s._place_block_free(s._palette_index("Ball"), Vector3(-2.0, 0.5, 0), 0.0)
	s._place_block_free(s._palette_index("Cylinder"), Vector3(2.0, 0.5, 0), 0.0)

	# Camera surveys the row from the front.
	s._cam.position = Vector3(0, 1.6, 6)
	s._look_toward(Vector3(0, 0.5, 0))

	# Hold the wand + engage the middle block => the 3-axis gizmo appears at it.
	var wand_idx := -1
	for i in s.palette.size():
		var e: Dictionary = s.palette[i]
		if String(e.get("kind", "")) == "tool" and String(e.get("tool", "")) == "wand":
			wand_idx = i
	s._select_slot(0)
	s.hotbar[0] = wand_idx
	s._refresh_held_item()
	s._click_secondary()                    # RIGHT-click grabs the aimed middle block
	# Apply a visible precise rotation on two axes so the manipulated block is clearly tilted.
	var rec: Dictionary = s.objects[mid]
	rec["yaw_deg"] = 25.0
	rec["pitch_deg"] = 15.0
	s._tick_objects(0.016)

	# Wait for lazy loads + let it light/render, then screenshot.
	var deadline := Time.get_ticks_msec() + 8000
	while s.assets.pending_count() > 0 and Time.get_ticks_msec() < deadline:
		await process_frame
	for _i in 8:
		await process_frame
	await RenderingServer.frame_post_draw
	var img := get_root().get_texture().get_image()
	DirAccess.make_dir_recursive_absolute("res://docs")
	img.save_png(OUT)
	print("[wand_shot] proof written: %s (engaged=%s, objects=%d)" % [OUT, s._active_handler.engaged_id(), s.objects.size()])
	quit(0)
