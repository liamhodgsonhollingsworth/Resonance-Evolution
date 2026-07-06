extends SceneTree
## WINDOWED before/after proof that the aperture room hotloads when its node ARRANGEMENT changes.
## Run WINDOWED (needs a display; NOT --headless):
##   <Godot> --path godot -s res://aperture_room_hotload_proof.gd
##
## It (1) mounts the REAL aperture_3d.tscn, frames the room, screenshots BEFORE to docs/, then (2)
## edits the LIVE aperture_room_shell.json on disk (moves the +X wall inward + retints the sky warm-
## orange), waits for the scene's own mtime poll to hotload it, and screenshots AFTER. Finally it
## RESTORES the arrangement file byte-for-byte so the repo copy is unchanged. Both PNGs land in
## godot/docs/ as the artifact evidence.

const SCENE := "res://aperture/aperture_3d.tscn"
const ROOM_JSON := "res://aperture/aperture_room_shell.json"
const BEFORE := "res://docs/aperture_room_before.png"
const AFTER := "res://docs/aperture_room_after.png"

func _initialize() -> void:
	if DisplayServer.get_name() == "headless":
		print("[room-proof] needs a display; run WINDOWED (no --headless). Exit 2.")
		quit(2)
		return
	_run()

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("res://docs"))
	# Snapshot the original arrangement so we can restore it after the proof.
	var original := FileAccess.get_file_as_string(ROOM_JSON)

	var scene: PackedScene = load(SCENE)
	var room = scene.instantiate()
	get_root().add_child(room)

	# Let the room build + settle, then frame it from a corner so several walls + the sky show.
	await _frames(30)
	if room.has_method("_apply_camera_rotation"):
		room._pos = Vector3(6.0, 2.6, 8.5)
		room._cam.position = room._pos
		room._yaw = deg_to_rad(-28.0)
		room._pitch = -0.16
		room._apply_camera_rotation()
	await _frames(6)
	await RenderingServer.frame_post_draw
	get_root().get_viewport().get_texture().get_image().save_png(BEFORE)
	print("[room-proof] BEFORE written: %s" % BEFORE)

	# --- MUTATE the arrangement ON DISK (the exact edit Liam would make in the JSON) ---
	var data = JSON.parse_string(original)
	for n in data["nodes"]:
		if String(n.get("id")) == "wall_px_at":
			n["params"]["position"] = [7.5, 3.0, 0.0]      # pull the +X wall inward (12 -> 7.5)
		if String(n.get("id")) == "wall_px_box":
			n["params"]["value"]["mesh"]["params"]["height"] = 4.0   # and shorten it (6 -> 4)
		if String(n.get("id")) == "sky":
			n["params"]["top_color"] = [0.95, 0.55, 0.25]  # warm-orange sky
			n["params"]["horizon_color"] = [0.98, 0.82, 0.6]
			n["params"]["sun_azimuth_deg"] = 60.0
	var f := FileAccess.open(ROOM_JSON, FileAccess.WRITE)
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	print("[room-proof] arrangement mutated on disk; waiting for the scene's mtime poll to hotload...")

	# The scene polls the JSON mtime every ~0.4s in _process; give it comfortably longer, then settle.
	await _seconds(1.4)
	await _frames(8)
	await RenderingServer.frame_post_draw
	get_root().get_viewport().get_texture().get_image().save_png(AFTER)
	print("[room-proof] AFTER written: %s" % AFTER)

	# --- RESTORE the original arrangement byte-for-byte (repo copy unchanged) ---
	var rf := FileAccess.open(ROOM_JSON, FileAccess.WRITE)
	rf.store_string(original)
	rf.close()
	print("[room-proof] arrangement restored. Done.")
	quit(0)

func _frames(n: int) -> void:
	for _i in n:
		await process_frame

func _seconds(s: float) -> void:
	await create_timer(s).timeout
