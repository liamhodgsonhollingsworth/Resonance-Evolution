class_name TunablePanel
extends Control
## TunablePanel -- a generic, general-purpose (NOT underground-scene-specific) runtime
## tunable-parameter panel. Any scene wires this in with ONE call, `configure(param_specs,
## on_change)`, and gets a live slider/checkbox/dropdown panel for free. Satisfies Liam's 2026-07-15
## standing ideal (DISPATCH claim underground-railing-iteration-2026-07-15): "give me the ability in
## this scene to change and resize everything... any mistakes you make I can fix easily by changing
## the free variables to make it exactly what I want... that is what it means for this to all be
## node based, is that you can plug those nodes into UI knobs and controls for me to change them."
##
## `param_specs`: Array[Dictionary], one entry per control:
##   {"key": String, "label": String, "type": "float"|"int"|"bool"|"enum",
##    "min": float, "max": float, "step": float, "default": Variant, "options": Array (enum only)}
## This is the SAME shape `Alethea-cc/tools/param_artifacts.py`'s `ParamSpec`/`@tunable` convention
## already uses server-side (name/min/max/default/options) -- a documented follow-up (not built
## here) is wiring `configure()` directly from an AST-walked `@tunable` digest
## (`param_ui_autogen.py`, PR #910) instead of a scene hand-writing its own `param_specs` Array; the
## shape already matches so that wiring is thin when it happens, and the SAME follow-up would also
## carry this panel's live edits out over the existing `param_channel`/`ws://` transport for
## cross-window/cross-device tuning (Liam's Q4, already resolved as "transport-agnostic by design"
## per `crosscutting_systems_plan_2026_07_14.md` §10.2) -- NOT built in this pass, enqueued.
##
## `on_change: Callable(key: String, value: Variant) -> void` fires live on every edit (slider drag,
## checkbox toggle, dropdown pick) -- a caller typically rebuilds (part of) its scene from this.
##
## API:
##   configure(param_specs: Array, on_change: Callable) -> void
##   get_values() -> Dictionary        -- key -> current value, for a caller that wants a snapshot
##                                        rather than reacting live to every `on_change` call.
##   set_value(key: String, value: Variant) -> void   -- programmatically move a control (e.g. when
##                                                        loading a saved preset).
##
## schema-version: 1.0.0

var _on_change: Callable
var _values: Dictionary = {}
var _controls: Dictionary = {}  # key -> the Control instance (for set_value)
var _vbox: VBoxContainer


func _ready() -> void:
	_vbox = VBoxContainer.new()
	add_child(_vbox)
	custom_minimum_size = Vector2(260, 0)


func configure(param_specs: Array, on_change: Callable) -> void:
	_on_change = on_change
	_values.clear()
	_controls.clear()
	for child in _vbox.get_children():
		child.queue_free()

	for spec_v in param_specs:
		var spec: Dictionary = spec_v
		var key: String = String(spec.get("key", ""))
		if key == "":
			continue
		var label_text: String = String(spec.get("label", key))
		var kind: String = String(spec.get("type", "float"))
		var default_v = spec.get("default", 0.0)
		_values[key] = default_v

		var row := HBoxContainer.new()
		var lbl := Label.new()
		lbl.text = label_text
		lbl.custom_minimum_size = Vector2(120, 0)
		row.add_child(lbl)

		match kind:
			"bool":
				var cb := CheckBox.new()
				cb.button_pressed = bool(default_v)
				cb.toggled.connect(func(pressed: bool): _emit(key, pressed))
				row.add_child(cb)
				_controls[key] = cb
			"enum":
				var options: Array = spec.get("options", [])
				var ob := OptionButton.new()
				for i in options.size():
					ob.add_item(String(options[i]), i)
				var default_idx: int = maxi(0, options.find(default_v))
				ob.select(default_idx)
				ob.item_selected.connect(func(idx: int): _emit(key, options[idx]))
				row.add_child(ob)
				_controls[key] = ob
			"int", "float":
				var lo: float = float(spec.get("min", 0.0))
				var hi: float = float(spec.get("max", 1.0))
				var step: float = float(spec.get("step", 0.01 if kind == "float" else 1.0))
				var hs := HSlider.new()
				hs.min_value = lo
				hs.max_value = hi
				hs.step = step
				hs.value = float(default_v)
				hs.custom_minimum_size = Vector2(120, 0)
				var value_lbl := Label.new()
				value_lbl.text = str(default_v)
				value_lbl.custom_minimum_size = Vector2(48, 0)
				hs.value_changed.connect(func(v: float):
					var out_v = int(round(v)) if kind == "int" else v
					value_lbl.text = str(out_v)
					_emit(key, out_v))
				row.add_child(hs)
				row.add_child(value_lbl)
				_controls[key] = hs
			_:
				continue

		_vbox.add_child(row)


func _emit(key: String, value: Variant) -> void:
	_values[key] = value
	if _on_change.is_valid():
		_on_change.call(key, value)


func get_values() -> Dictionary:
	return _values.duplicate()


func set_value(key: String, value: Variant) -> void:
	if not _controls.has(key):
		return
	_values[key] = value
	var ctrl = _controls[key]
	if ctrl is CheckBox:
		ctrl.button_pressed = bool(value)
	elif ctrl is HSlider:
		ctrl.value = float(value)
	elif ctrl is OptionButton:
		for i in ctrl.item_count:
			if ctrl.get_item_text(i) == String(value):
				ctrl.select(i)
				break
