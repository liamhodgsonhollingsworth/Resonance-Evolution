extends Control
## STEREOGRAM DEMO — a minimal openable wrapper around the stereogram/VR-viewer foundation
## (examples/stereogram_demo.json → the StereoRender primitive). Until now the arrangement ran
## only inside headless_stereo_test.gd; this scene evaluates the SAME arrangement through the
## real GraphRuntime and shows all four outputs it writes: the depth map, the autostereogram
## (cross-eyed free-viewing), the side-by-side stereo pair, and the red/cyan anaglyph.
##
##   <Godot> --path godot res://examples/stereogram_scene.tscn
##
## Wrapper only: ONE viewing-geometry dict in the arrangement drives every output. Iterate by
## editing examples/stereogram_demo.json and reopening. Preloads are path-based (no class_name
## dependence) per the class-cache gotcha.

const GraphRuntimeScript := preload("res://runtime/graph_runtime.gd")
const ARRANGEMENT := "res://examples/stereogram_demo.json"

const PANELS := [
	["depth", "depth map (viewer-space Z)"],
	["stereogram", "autostereogram — view CROSS-EYED"],
	["pair", "stereo pair (side by side)"],
	["anaglyph", "anaglyph (red/cyan glasses)"],
]


func _ready() -> void:
	get_window().title = "Stereogram demo"
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color(0.09, 0.09, 0.11)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 16
	col.offset_top = 12
	col.offset_right = -16
	col.offset_bottom = -12
	col.add_theme_constant_override("separation", 8)
	add_child(col)

	var title := Label.new()
	title.text = "Stereogram — one viewing-geometry dict drives depth, SIRDS, stereo pair and anaglyph (edit stereogram_demo.json, reopen)"
	col.add_child(title)

	var rt: Node = GraphRuntimeScript.new()
	add_child(rt)
	rt.load_json(ARRANGEMENT)
	var outputs: Dictionary = rt.evaluate()
	rt.queue_free()

	var desc: Dictionary = outputs.get("stereo", {}).get("stereo", {})
	if not bool(desc.get("ok", false)):
		var err := Label.new()
		err.text = "FAILED to evaluate " + ARRANGEMENT + " — see console"
		col.add_child(err)
		push_warning("[stereogram_scene] arrangement failed")
		return

	var grid := GridContainer.new()
	grid.columns = 2
	grid.size_flags_vertical = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 8)
	col.add_child(grid)

	var paths: Dictionary = desc.get("paths", {})
	for spec in PANELS:
		var key := String(spec[0])
		var panel := VBoxContainer.new()
		panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
		grid.add_child(panel)

		var caption := Label.new()
		caption.text = String(spec[1])
		panel.add_child(caption)

		var img: Image = null
		if paths.has(key):
			img = Image.load_from_file(ProjectSettings.globalize_path(String(paths[key])))
		if img == null:
			caption.text += "  [missing]"
			continue
		var rect := TextureRect.new()
		rect.texture = ImageTexture.create_from_image(img)
		rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
		panel.add_child(rect)
