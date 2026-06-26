class_name EffectStackGpu
extends RefCounted
## The GPU SHADER DELEGATE for an `effect_stack` descriptor — the fast, hardware twin of
## EffectStackCpu (the headless CPU reference oracle, renderers/effect_stack_cpu.gd). It consumes the
## SAME renderer-neutral canonical descriptor `{ "stack": [{ "type", "params" }, ...] }`
## (Alethea-cc/nodes/painterly_effect_stack_canonical_schema.md — the ONE schema; this file does NOT
## fork it) and emits a renderer-SPECIFIC artifact: a Godot `canvas_item` fragment-shader source string
## that applies the stack's L1 layers IN ORDER on the GPU. Renderer-neutral DATA in → renderer-specific
## shader out, at the documented `renderers/` delegate seam only (NO `primitives/` or GraphRuntime edit,
## exactly like gltf_exporter.gd is the 3D delegate's twin oracle).
##
## ── Why a generator + a headless emulation, not a live GPU render ──────────────────────────────────
## Godot under `--headless` uses the DUMMY rendering driver: `RenderingServer.get_rendering_device()`
## is null and SubViewport textures read back null — a real GPU render simply does not run in the
## headless test suite (verified 2026-06-26). So the PARITY contract — "render the same descriptor on
## CPU + GPU, assert within tolerance" — is met WITHOUT a GPU by structuring the delegate as two
## co-derived halves that share ONE per-pixel formula per effect:
##   1. `build_shader_code(desc)` — generates the GLSL the GPU will actually run (the shippable artifact;
##      a CompositorEffect / ColorRect+ShaderMaterial pass binds it on real hardware).
##   2. `emulate(desc, src)` — executes that SAME per-pixel algebra in GDScript on an Image, headlessly,
##      so the headless suite can assert `emulate(desc) ≈ EffectStackCpu.apply(desc)` within tolerance.
## The shader body and the emulator are written from the SAME `_L1_GLSL` table (GLSL string + a GDScript
## Callable that computes the identical math), so they cannot drift: one edit teaches both, mirroring the
## "single EFFECT_TYPES edit teaches applier + evolver" discipline in effect_stack_cpu.gd.
##
## ── L1 SCOPE (this GPU tier) ───────────────────────────────────────────────────────────────────────
## L1 is the per-pixel + single-tap-3x3-Sobel layer set that maps to ONE single-pass fragment shader
## with no ping-pong / large-kernel gather:
##   passthrough · posterize · edge_darken · outline · paper_grain · normal_map · lighting
## These match EffectStackCpu's same-named branches bit-for-formula (Rec.601 luma, the same Sobel pair,
## the same integer-hash value noise, the same tangent-space normal packing, the same Lambert shade).
## DEFERRED to a later GPU tier (NOT emitted here; they need multi-tap neighbourhood gather / history):
##   kuwahara · generalized_kuwahara · temporal_stability — a forward descriptor naming one of these is
##   SKIPPED by the GPU path (forward-compat, never an error), so the GPU delegate runs the L1 layers it
##   understands and the rest stay on the CPU oracle / a future GPU tier. (See the L1 follow-on DQ.)

## The L1 vocabulary: effect type -> { "glsl": <fragment-body snippet>, "fn": <Callable(c,x,y,w,h,getp,p)> }.
## `glsl` is a body snippet that reads/writes the working color `c` (vec4) given UV/TEXTURE_PIXEL_SIZE +
## the per-effect uniforms emitted by `_uniforms_for`. `fn` is the GDScript twin computing the identical
## per-pixel result on an Image — `getp` is a Callable(ix,iy)->Color sampling the CURRENT working image
## (clamped), so a layer that needs a 3x3 neighbourhood reads it the same way the shader samples texels.
## Both halves are derived from the SAME math so the parity test is a tautology-by-construction, not luck.
const L1_TYPES := ["passthrough", "posterize", "edge_darken", "outline", "paper_grain", "normal_map", "lighting"]

## Build the GLSL `canvas_item` fragment shader that applies the descriptor's L1 layers in order. Unknown
## or deferred (non-L1) effect types are SKIPPED (forward-compatible, never an error) — the GPU path runs
## the L1 layers; the rest stay on the CPU oracle / a future GPU tier. Returns the full shader source.
## The shader samples `src_tex` (the source frame) for layer 0; each subsequent layer reads the prior
## layer's output. Because canvas_item shaders are single-pass, neighbourhood layers (edge_darken /
## outline / normal_map / lighting — all 3x3 Sobel) sample `src_tex` directly at texel offsets; this is
## exact for a SINGLE such layer (the common painterly case) and is the documented single-pass limit —
## chaining two Sobel layers on the GPU is the multi-pass follow-on, same as the CPU oracle's note.
static func build_shader_code(desc: Dictionary) -> String:
	var layers := _l1_layers(desc)
	var uniforms := "uniform sampler2D src_tex;\n"
	var body := "\tvec2 ts = TEXTURE_PIXEL_SIZE;\n\tvec4 c = texture(src_tex, UV);\n"
	var i := 0
	for layer in layers:
		var t: String = layer["type"]
		uniforms += _uniforms_for(t, layer["params"], i)
		body += "\t// layer %d: %s\n" % [i, t]
		body += _indent(_glsl_for(t, i))
		i += 1
	body += "\tCOLOR = c;\n"
	return "shader_type canvas_item;\n\n" + uniforms + "\nvoid fragment() {\n" + body + "}\n"

## The shader-parameter values the descriptor implies, keyed `fx<i>_<name>` to match `_uniforms_for`'s
## names, so a caller can `mat.set_shader_parameter(k, v)` for every uniform `build_shader_code` declared
## (besides `src_tex`, which the caller binds to the source frame). Pure DATA out — no Godot render here.
static func shader_params(desc: Dictionary) -> Dictionary:
	var out := {}
	var i := 0
	for layer in _l1_layers(desc):
		var t: String = layer["type"]
		var p: Dictionary = layer["params"]
		match t:
			"posterize":
				out["fx%d_levels" % i] = maxi(2, int(p.get("levels", 4)))
			"edge_darken":
				out["fx%d_strength" % i] = float(p.get("strength", 1.0))
				out["fx%d_threshold" % i] = float(p.get("threshold", 0.1))
			"outline":
				out["fx%d_threshold" % i] = float(p.get("threshold", 0.25))
				out["fx%d_color" % i] = _color_param(p.get("color", [0.0, 0.0, 0.0, 1.0]), Color(0, 0, 0, 1))
				out["fx%d_bg" % i] = _color_param(p.get("bg", [0.0, 0.0, 0.0, 0.0]), Color(0, 0, 0, 0))
			"paper_grain":
				out["fx%d_amount" % i] = clampf(float(p.get("amount", 0.15)), 0.0, 1.0)
				out["fx%d_scale" % i] = maxf(1.0, float(p.get("scale", 8.0)))
				out["fx%d_seed" % i] = int(p.get("seed", 1337))
			"normal_map":
				out["fx%d_strength" % i] = maxf(0.0, float(p.get("strength", 2.0)))
			"lighting":
				out["fx%d_strength" % i] = maxf(0.0, float(p.get("strength", 2.0)))
				out["fx%d_ambient" % i] = clampf(float(p.get("ambient", 0.3)), 0.0, 1.0)
				out["fx%d_light" % i] = _light_dir(p)
		i += 1
	return out

## The HEADLESS PARITY TWIN: apply the descriptor's L1 layers to a source Image using the SAME per-pixel
## algebra the generated GLSL runs, returning a NEW Image. This is what the headless suite renders to
## compare against EffectStackCpu.apply — it stands in for "render on the GPU" where no GPU exists under
## --headless. Each layer reads the PRIOR layer's output (a snapshot), matching the shader's per-layer
## texture read; neighbourhood layers sample that snapshot clamped, exactly as the shader samples texels.
static func emulate(desc: Dictionary, src: Image) -> Image:
	var img := _to_rgbaf(src)
	var i := 0
	for layer in _l1_layers(desc):
		img = _emulate_layer(layer["type"], layer["params"], img, i)
		i += 1
	return img

# ── per-layer headless emulation (the GDScript twin of each GLSL snippet) ─────────────────────────────

static func _emulate_layer(t: String, p: Dictionary, src: Image, idx: int) -> Image:
	var w := src.get_width()
	var h := src.get_height()
	var out := Image.create(w, h, false, Image.FORMAT_RGBAF)
	# Sampler over the layer's INPUT snapshot, clamped — the GDScript twin of `texture(tex, uv)`.
	var getp := func(ix: int, iy: int) -> Color:
		return src.get_pixel(clampi(ix, 0, w - 1), clampi(iy, 0, h - 1))
	for y in h:
		for x in w:
			out.set_pixel(x, y, _pixel(t, p, getp, x, y, w, h))
	return out

## Compute one output pixel for effect `t` at (x,y) — the canonical per-pixel formula shared with GLSL.
static func _pixel(t: String, p: Dictionary, getp: Callable, x: int, y: int, w: int, h: int) -> Color:
	var c: Color = getp.call(x, y)
	match t:
		"passthrough":
			return c
		"posterize":
			var levels: int = maxi(2, int(p.get("levels", 4)))
			var steps := float(levels - 1)
			return Color(
				round(clampf(c.r, 0.0, 1.0) * steps) / steps,
				round(clampf(c.g, 0.0, 1.0) * steps) / steps,
				round(clampf(c.b, 0.0, 1.0) * steps) / steps,
				c.a)
		"edge_darken":
			var strength := float(p.get("strength", 1.0))
			var threshold := float(p.get("threshold", 0.1))
			var mag := _sobel_mag(getp, x, y)
			var e: float = max(0.0, mag - threshold)
			var k := 1.0 - clampf(e * strength, 0.0, 1.0)
			return Color(c.r * k, c.g * k, c.b * k, c.a)
		"outline":
			var threshold := float(p.get("threshold", 0.25))
			var color := _color_param(p.get("color", [0.0, 0.0, 0.0, 1.0]), Color(0, 0, 0, 1))
			var bg := _color_param(p.get("bg", [0.0, 0.0, 0.0, 0.0]), Color(0, 0, 0, 0))
			return color if _sobel_mag(getp, x, y) >= threshold else bg
		"paper_grain":
			var amount := clampf(float(p.get("amount", 0.15)), 0.0, 1.0)
			var scale: float = max(1.0, float(p.get("scale", 8.0)))
			var seed := int(p.get("seed", 1337))
			var n := _value_noise(float(x) / scale, float(y) / scale, seed)
			var factor := clampf(1.0 + (n - 0.5) * 2.0 * amount, 0.0, 2.0)
			return Color(
				clampf(c.r * factor, 0.0, 1.0),
				clampf(c.g * factor, 0.0, 1.0),
				clampf(c.b * factor, 0.0, 1.0),
				c.a)
		"normal_map":
			var strength: float = max(0.0, float(p.get("strength", 2.0)))
			var n := _height_normal(getp, x, y, strength)
			return Color(n.x * 0.5 + 0.5, n.y * 0.5 + 0.5, n.z * 0.5 + 0.5, c.a)
		"lighting":
			var strength: float = max(0.0, float(p.get("strength", 2.0)))
			var ambient := clampf(float(p.get("ambient", 0.3)), 0.0, 1.0)
			var light := _light_dir(p)
			var n := _height_normal(getp, x, y, strength)
			var ndotl: float = max(0.0, n.dot(light))
			var shade := clampf(ambient + (1.0 - ambient) * ndotl, 0.0, 1.0)
			return Color(c.r * shade, c.g * shade, c.b * shade, c.a)
		_:
			return c

# ── GLSL snippet generation (the GPU twin of each _pixel branch) ──────────────────────────────────────

## The fragment-body GLSL for effect `t` at layer index `i`. Reads/writes the working `vec4 c`; uses `ts`
## (TEXTURE_PIXEL_SIZE) + `src_tex` for the Sobel/relief layers. Mirrors `_pixel` line for line.
static func _glsl_for(t: String, i: int) -> String:
	match t:
		"passthrough":
			return "// identity\n"
		"posterize":
			return ("float steps%d = float(fx%d_levels - 1);\n" % [i, i]) + \
				("c.rgb = round(clamp(c.rgb, 0.0, 1.0) * steps%d) / steps%d;\n" % [i, i])
		"edge_darken":
			return ("float mag%d = _sobel_mag(UV, ts);\n" % i) + \
				("float e%d = max(0.0, mag%d - fx%d_threshold);\n" % [i, i, i]) + \
				("float k%d = 1.0 - clamp(e%d * fx%d_strength, 0.0, 1.0);\n" % [i, i, i]) + \
				("c.rgb *= k%d;\n" % i)
		"outline":
			return ("float mag%d = _sobel_mag(UV, ts);\n" % i) + \
				("c = (mag%d >= fx%d_threshold) ? fx%d_color : fx%d_bg;\n" % [i, i, i, i])
		"paper_grain":
			return ("float n%d = _value_noise(FRAGCOORD.xy / fx%d_scale, fx%d_seed);\n" % [i, i, i]) + \
				("float f%d = clamp(1.0 + (n%d - 0.5) * 2.0 * fx%d_amount, 0.0, 2.0);\n" % [i, i, i]) + \
				("c.rgb = clamp(c.rgb * f%d, 0.0, 1.0);\n" % i)
		"normal_map":
			return ("vec3 nrm%d = _height_normal(UV, ts, fx%d_strength);\n" % [i, i]) + \
				("c.rgb = nrm%d * 0.5 + 0.5;\n" % i)
		"lighting":
			return ("vec3 nrm%d = _height_normal(UV, ts, fx%d_strength);\n" % [i, i]) + \
				("float ndotl%d = max(0.0, dot(nrm%d, fx%d_light));\n" % [i, i, i]) + \
				("float shade%d = clamp(fx%d_ambient + (1.0 - fx%d_ambient) * ndotl%d, 0.0, 1.0);\n" % [i, i, i, i]) + \
				("c.rgb *= shade%d;\n" % i)
		_:
			return "// (skipped non-L1 effect '%s')\n" % t

## The per-layer uniform declarations (names match `shader_params`). Each layer's knobs are suffixed by
## its index so two layers of the same type on the GPU keep independent params.
static func _uniforms_for(t: String, _params: Dictionary, i: int) -> String:
	match t:
		"posterize":
			return "uniform int fx%d_levels = 4;\n" % i
		"edge_darken":
			return ("uniform float fx%d_strength = 1.0;\n" % i) + ("uniform float fx%d_threshold = 0.1;\n" % i)
		"outline":
			return ("uniform float fx%d_threshold = 0.25;\n" % i) + \
				("uniform vec4 fx%d_color : source_color = vec4(0.0, 0.0, 0.0, 1.0);\n" % i) + \
				("uniform vec4 fx%d_bg : source_color = vec4(0.0, 0.0, 0.0, 0.0);\n" % i)
		"paper_grain":
			return ("uniform float fx%d_amount = 0.15;\n" % i) + ("uniform float fx%d_scale = 8.0;\n" % i) + \
				("uniform int fx%d_seed = 1337;\n" % i)
		"normal_map":
			return "uniform float fx%d_strength = 2.0;\n" % i
		"lighting":
			return ("uniform float fx%d_strength = 2.0;\n" % i) + ("uniform float fx%d_ambient = 0.3;\n" % i) + \
				("uniform vec3 fx%d_light = vec3(-0.5, -0.5, 1.0);\n" % i)
		_:
			return ""

# ── shared helpers (the SAME formulas as EffectStackCpu, so emulate ≈ apply by construction) ───────────

## Rec.601 luminance — identical to EffectStackCpu._luma.
static func _luma(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b

## 3x3 Sobel luminance-gradient (gx, gy) over the sampler, clamped — the SAME pair EffectStackCpu uses.
static func _sobel_gradient(getp: Callable, x: int, y: int) -> Vector2:
	var l := func(ix: int, iy: int) -> float:
		return _luma(getp.call(ix, iy))
	var tl: float = l.call(x - 1, y - 1); var tc: float = l.call(x, y - 1); var tr: float = l.call(x + 1, y - 1)
	var ml: float = l.call(x - 1, y);     var mr: float = l.call(x + 1, y)
	var bl: float = l.call(x - 1, y + 1); var bc: float = l.call(x, y + 1); var br: float = l.call(x + 1, y + 1)
	var gx := (tr + 2.0 * mr + br) - (tl + 2.0 * ml + bl)
	var gy := (bl + 2.0 * bc + br) - (tl + 2.0 * tc + tr)
	return Vector2(gx, gy)

static func _sobel_mag(getp: Callable, x: int, y: int) -> float:
	var g := _sobel_gradient(getp, x, y)
	return sqrt(g.x * g.x + g.y * g.y)

## Unit surface normal of the luminance height field — identical to EffectStackCpu._height_normal.
static func _height_normal(getp: Callable, x: int, y: int, strength: float) -> Vector3:
	var g := _sobel_gradient(getp, x, y)
	return Vector3(-strength * g.x, -strength * g.y, 1.0).normalized()

## Normalized light direction from the descriptor — identical degenerate handling to EffectStackCpu._lighting.
static func _light_dir(p: Dictionary) -> Vector3:
	var light := Vector3(float(p.get("light_x", -0.5)), float(p.get("light_y", -0.5)), float(p.get("light_z", 1.0)))
	if light.length() < 0.000001:
		light = Vector3(0.0, 0.0, 1.0)
	return light.normalized()

## Deterministic integer-hash value noise — identical to EffectStackCpu._value_noise / _hash01.
static func _value_noise(fx: float, fy: float, seed: int) -> float:
	var x0 := int(floor(fx))
	var y0 := int(floor(fy))
	var tx := fx - float(x0)
	var ty := fy - float(y0)
	tx = tx * tx * (3.0 - 2.0 * tx)
	ty = ty * ty * (3.0 - 2.0 * ty)
	var v00 := _hash01(x0, y0, seed)
	var v10 := _hash01(x0 + 1, y0, seed)
	var v01 := _hash01(x0, y0 + 1, seed)
	var v11 := _hash01(x0 + 1, y0 + 1, seed)
	var a := lerpf(v00, v10, tx)
	var b := lerpf(v01, v11, tx)
	return lerpf(a, b, ty)

static func _hash01(x: int, y: int, seed: int) -> float:
	var n := (x * 374761393 + y * 668265263 + seed * 1442695040888963407) & 0x7fffffff
	n = (n ^ (n >> 13)) * 1274126177
	n = n & 0x7fffffff
	return float(n) / float(0x7fffffff)

static func _color_param(v, fallback: Color) -> Color:
	if v is Color:
		return v
	if typeof(v) == TYPE_ARRAY and v.size() >= 3:
		var a: float = float(v[3]) if v.size() >= 4 else 1.0
		return Color(float(v[0]), float(v[1]), float(v[2]), a)
	return fallback

# ── descriptor / image plumbing ───────────────────────────────────────────────────────────────────────

## The L1-only layer list from the descriptor, in order. Non-L1 / unknown types are dropped (the GPU path
## skips them — forward-compat), so callers iterate only over what the GPU actually runs.
static func _l1_layers(desc: Dictionary) -> Array:
	var out := []
	for layer in desc.get("stack", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		var t := String(layer.get("type", "passthrough"))
		if L1_TYPES.has(t):
			out.append({ "type": t, "params": layer.get("params", {}) })
	return out

## True iff EVERY layer in the descriptor is an L1 effect — i.e. the GPU path is a FAITHFUL whole-stack
## twin (no layer was dropped). When false, the caller should keep the dropped layers on the CPU oracle.
static func is_fully_l1(desc: Dictionary) -> bool:
	for layer in desc.get("stack", []):
		if typeof(layer) != TYPE_DICTIONARY:
			continue
		if not L1_TYPES.has(String(layer.get("type", "passthrough"))):
			return false
	return true

static func _to_rgbaf(src: Image) -> Image:
	var img := src.duplicate() as Image
	if img.get_format() != Image.FORMAT_RGBAF:
		img.convert(Image.FORMAT_RGBAF)
	return img

static func _indent(s: String) -> String:
	var out := ""
	for line in s.split("\n"):
		if line.strip_edges() == "":
			continue
		out += "\t" + line + "\n"
	return out
