class_name BuildHud
extends CanvasLayer
## The on-screen INVENTORY HUD for the walkabout build loop (DQ-4f47fab6). Pure presentation: it
## reads the PickupInteractor's type-grouped inventory and renders a small panel listing each held
## object type, its count, and which type is currently SELECTED (the one place-down will spawn). It
## owns no game state — pick-up / place-down / selection all live in the interactor; the HUD just
## reflects them and refreshes on the interactor's `inventory_changed` signal (no per-frame polling).
##
## Layout: a translucent panel pinned to the bottom-left, a title, a controls hint, and one row per
## held type ("> bed   x3" with the selected row brightened). Empty inventory shows a "walk up + E"
## prompt so the loop is discoverable. It is additive UI over the renderer-neutral seam — it touches
## no primitive / Context / runtime code, only the interactor's public read API.

const PANEL_BG := Color(0.06, 0.07, 0.10, 0.82)
const TEXT_DIM := Color(0.70, 0.74, 0.80)
const TEXT_SEL := Color(1.0, 0.92, 0.55)      # the selected type stands out (warm)
const TEXT_ROW := Color(0.86, 0.90, 0.95)

var _interactor: PickupInteractor = null
var _panel: PanelContainer
var _rows_box: VBoxContainer
var _title: Label
var _hint: Label

func _ready() -> void:
	layer = 10   # above the 3D viewport
	_build_ui()
	_refresh()

## Bind to a live PickupInteractor: refresh now and on every inventory/selection change.
func bind(interactor: PickupInteractor) -> void:
	_interactor = interactor
	if _interactor != null and not _interactor.inventory_changed.is_connected(_refresh):
		_interactor.inventory_changed.connect(_refresh)
	if is_node_ready():
		_refresh()

func _build_ui() -> void:
	# Anchor a margin container to the bottom-left so the panel hugs the corner at any resolution.
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_bottom", 16)
	margin.grow_horizontal = Control.GROW_DIRECTION_END
	margin.grow_vertical = Control.GROW_DIRECTION_BEGIN
	add_child(margin)

	_panel = PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = PANEL_BG
	style.set_corner_radius_all(8)
	style.set_content_margin_all(12)
	_panel.add_theme_stylebox_override("panel", style)
	_panel.custom_minimum_size = Vector2(240, 0)
	margin.add_child(_panel)

	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 4)
	_panel.add_child(col)

	_title = Label.new()
	_title.text = "INVENTORY"
	_title.add_theme_color_override("font_color", Color(0.62, 0.78, 0.95))
	_title.add_theme_font_size_override("font_size", 14)
	col.add_child(_title)

	_rows_box = VBoxContainer.new()
	_rows_box.add_theme_constant_override("separation", 2)
	col.add_child(_rows_box)

	_hint = Label.new()
	_hint.text = "E pick up · Q place · Tab cycle"
	_hint.add_theme_color_override("font_color", TEXT_DIM)
	_hint.add_theme_font_size_override("font_size", 11)
	col.add_child(_hint)

## Re-read the interactor and rebuild the row list. Cheap (a handful of labels) and only fires on
## change, so rebuilding wholesale is simpler than diffing and has no perceptible cost.
func _refresh() -> void:
	if _rows_box == null:
		return
	for c in _rows_box.get_children():
		c.queue_free()
	if _interactor == null:
		return
	var rows: Array = _interactor.held_rows()
	if rows.is_empty():
		var empty := Label.new()
		empty.text = "(empty — walk up to an object and press E)"
		empty.add_theme_color_override("font_color", TEXT_DIM)
		empty.add_theme_font_size_override("font_size", 12)
		_rows_box.add_child(empty)
		_title.text = "INVENTORY"
		return
	_title.text = "INVENTORY  (%d)" % _interactor.held_total()
	for row in rows:
		var lbl := Label.new()
		var marker := "▸ " if row["selected"] else "   "
		lbl.text = "%s%s   x%d" % [marker, _short(String(row["name"])), int(row["count"])]
		lbl.add_theme_color_override("font_color", TEXT_SEL if row["selected"] else TEXT_ROW)
		lbl.add_theme_font_size_override("font_size", 13)
		_rows_box.add_child(lbl)

## Trim a long model name to keep rows tidy.
func _short(name: String) -> String:
	# Kit member names look like "kenney_nature__bed" — show the part after the "__".
	var n := name
	var sep := n.rfind("__")
	if sep >= 0:
		n = n.substr(sep + 2)
	if n.length() > 22:
		n = n.substr(0, 21) + "…"
	return n
