extends SceneTree
## MATH-PAINTING DEMO RUNNER — evaluates the three committed math-painting ARRANGEMENTS (pure DATA:
## one MathPaint node each) through the real GraphRuntime and reports the PNGs they painted. Fully
## headless (the generators + the painterly stack are CPU Image math — no GPU, no window).
##
##   godot --headless --path godot -s res://examples/math_painting_demo.gd
##
## Each arrangement is the ONE file to iterate for its painting: edit the math knobs (curve a/b/k,
## flow seed/scale, harmonic modes), the palette, or the effect_stack and re-run — same DATA in,
## same painting out (deterministic; the descriptor carries a reproducible sha256).

const ARRANGEMENTS := [
	"res://examples/math_lissajous.arrangement.json",
	"res://examples/math_flow_field.arrangement.json",
	"res://examples/math_harmonic.arrangement.json",
]

func _initialize() -> void:
	var all_ok := true
	for path in ARRANGEMENTS:
		var data = JSON.parse_string(FileAccess.get_file_as_string(path))
		if typeof(data) != TYPE_DICTIONARY:
			print("[math_painting_demo] BAD arrangement %s" % path)
			all_ok = false
			continue
		var rt := GraphRuntime.new()
		get_root().add_child(rt)
		rt.load_arrangement(data)
		var outputs := rt.evaluate()
		var painted: Dictionary = outputs.get("paint", {}).get("painted", {})
		var ok := bool(painted.get("ok", false))
		all_ok = all_ok and ok
		print("[math_painting_demo] %-38s -> %s  (%dx%d, %s, sha %s…)" % [
			path.get_file(), painted.get("path", "?"),
			int(painted.get("width", 0)), int(painted.get("height", 0)),
			painted.get("generator", "?"), String(painted.get("sha256", "")).substr(0, 12)])
		rt.queue_free()
	print("[math_painting_demo] RESULT: %s" % ("ALL OK" if all_ok else "FAILURES"))
	quit(0 if all_ok else 1)
