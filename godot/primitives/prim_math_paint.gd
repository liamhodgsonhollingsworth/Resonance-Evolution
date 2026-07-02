class_name PrimMathPaint
extends Primitive
## The MATH-PAINT node — renders a mathematical construction (parametric curve / flow-field
## streamlines / harmonic standing waves; see renderers/math_painting.gd) and paints it through the
## existing painterly effect stack (EffectStackCpu, reused verbatim), emitting a JSON-serializable
## descriptor with the on-disk PNG path + a content hash. Deterministic: the same params always
## produce byte-identical pixels (seeded LCG + the shared integer-hash noise family), so the sha256
## in the descriptor is reproducible — an arrangement that names a painting IS the painting.
##
## A generator/source node: no inputs (the math IS the source); one output.
##   params:
##     painting     — the MathPainting descriptor ({generator, width, height, seed, palette, ...}).
##     effect_stack — the painterly layers applied after generation (same {type,params} the evolver
##                    breeds); empty/absent → the raw math image.
##     out_path     — where the PNG is written (default user://math_paintings/<node-id-less> path).
##   output "painted":
##     { "format": "resonance.math_painting/v1", "path", "width", "height", "generator", "sha256",
##       "ok": bool }

func _init() -> void:
	prim_type = "MathPaint"

func input_ports() -> Array:
	return []

func output_ports() -> Array:
	return [{ "name": "painted", "type": "any" }]

func evaluate(_inputs: Dictionary) -> Dictionary:
	var painting: Dictionary = params.get("painting", {})
	var stack: Array = params.get("effect_stack", [])
	var generator := String(painting.get("generator", "parametric_curve"))
	var out_path := String(params.get("out_path", "user://math_paintings/%s.png" % generator))
	var img := MathPainting.generate(painting)
	if not stack.is_empty():
		img = EffectStackCpu.apply({ "stack": stack }, img)
	img.convert(Image.FORMAT_RGBA8)
	var abs := ProjectSettings.globalize_path(out_path)
	DirAccess.make_dir_recursive_absolute(abs.get_base_dir())
	var err := img.save_png(out_path)
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(img.get_data())
	var sha := ctx.finish().hex_encode()
	return { "painted": {
		"format": "resonance.math_painting/v1",
		"path": out_path,
		"width": img.get_width(),
		"height": img.get_height(),
		"generator": generator,
		"sha256": sha,
		"ok": err == OK and FileAccess.file_exists(out_path),
	} }
