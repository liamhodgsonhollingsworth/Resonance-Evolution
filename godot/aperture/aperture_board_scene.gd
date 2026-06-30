extends Control
## Boots the read-only Godot Aperture board: mount an ApertureBoard, load a {nodes,edges} graph
## (the bundled sample by default, or a `--graph <path>` user-arg), render it, and — when launched
## with `-- --shot` — capture one frame to godot/live/aperture_board.png and quit. Mirrors
## live_demo.gd's capture pattern (await RenderingServer.frame_post_draw -> save_png).
##
## Windowed one-shot:  godot --path godot res://aperture/aperture_board.tscn -- --shot
## Windowed (stay up):  godot --path godot res://aperture/aperture_board.tscn

const SHOT_OUT := "res://live/aperture_board.png"
const DEFAULT_GRAPH := "res://aperture/sample_graph.json"

var board: ApertureBoard

func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	board = ApertureBoard.new()
	board.set_anchors_preset(Control.PRESET_FULL_RECT)
	board.graph_path = _graph_arg()
	add_child(board)
	board.load_graph_file(board.graph_path)
	print("[aperture_board] loaded %s (%d node(s), %d wire(s))" % [
		board.graph_path, board._arr.get("nodes", []).size(), board._arr.get("wires", []).size()])
	if _has_shot_flag():
		await _capture(SHOT_OUT)
		print("[aperture_board] --shot -> ", SHOT_OUT)
		get_tree().quit()

func _capture(path: String) -> void:
	# Let the GraphEdit lay out + paint before grabbing the frame.
	for i in 10:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png(path)

func _has_shot_flag() -> bool:
	return "--shot" in OS.get_cmdline_user_args() or "--shot" in OS.get_cmdline_args()

## `--graph <path>` user-arg selects the graph; otherwise the bundled sample.
func _graph_arg() -> String:
	var args := OS.get_cmdline_user_args()
	for i in args.size():
		if args[i] == "--graph" and i + 1 < args.size():
			return args[i + 1]
	return DEFAULT_GRAPH
