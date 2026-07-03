extends Control
## MATH PAINTINGS DEMO — a minimal openable wrapper around the three committed math-painting
## ARRANGEMENTS (pure DATA: one MathPaint node each; RE math-painting arc). Until now they ran
## only through the headless SceneTree runner (examples/math_painting_demo.gd); this scene puts
## the SAME evaluation in a window so the paintings are clickable from the Aperture board.
##
##   <Godot> --path godot res://examples/math_paintings_scene.tscn
##
## Wrapper only: each arrangement is evaluated through the real GraphRuntime (the exact path
## the headless runner proves), the painted PNG named by the descriptor is loaded back and
## shown. Iterate a painting by editing ITS arrangement JSON and reopening — same DATA in,
## same painting out (deterministic sha256 in the descriptor).
## Preloads are path-based (no class_name dependence) per the class-cache gotcha.

const GraphRuntimeScript := preload("res://runtime/graph_runtime.gd")

const ARRANGEMENTS := [
	"res://examples/math_lissajous.arrangement.json",
	"res://examples/math_flow_field.arrangement.json",
	"res://examples/math_harmonic.arrangement.json",
]

@onready var _status := Label.new()


func _ready() -> void:
	get_window().title = "Math paintings demo"
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
	title.text = "Math paintings — three MathPaint arrangements through GraphRuntime (edit an arrangement JSON, reopen to repaint)"
	col.add_child(title)

	var row := HBoxContainer.new()
	row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_theme_constant_override("separation", 12)
	col.add_child(row)

	_status.text = ""
	col.add_child(_status)

	var failures := 0
	for path in ARRANGEMENTS:
		if not _add_painting_panel(row, String(path)):
			failures += 1
	_status.text = ("all %d paintings evaluated OK" % ARRANGEMENTS.size()) if failures == 0 \
		else ("%d of %d paintings FAILED — see console" % [failures, ARRANGEMENTS.size()])


## Evaluate one arrangement and append a labelled panel showing its painted PNG.
## Returns true when the painting evaluated + loaded cleanly.
func _add_painting_panel(row: HBoxContainer, path: String) -> bool:
	var panel := VBoxContainer.new()
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	row.add_child(panel)

	var caption := Label.new()
	caption.text = path.get_file()
	panel.add_child(caption)

	var rt: Node = GraphRuntimeScript.new()
	add_child(rt)
	rt.load_json(path)
	var outputs: Dictionary = rt.evaluate()
	rt.queue_free()

	var painted: Dictionary = outputs.get("paint", {}).get("painted", {})
	if not bool(painted.get("ok", false)):
		caption.text += "  [FAILED to evaluate]"
		push_warning("[math_paintings_scene] arrangement failed: " + path)
		return false

	var img := Image.load_from_file(ProjectSettings.globalize_path(String(painted.get("path", ""))))
	if img == null:
		caption.text += "  [painted PNG missing]"
		return false

	caption.text = "%s  (%s, %dx%d)" % [path.get_file(), String(painted.get("generator", "?")),
		img.get_width(), img.get_height()]
	var rect := TextureRect.new()
	rect.texture = ImageTexture.create_from_image(img)
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rect.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_child(rect)
	return true
