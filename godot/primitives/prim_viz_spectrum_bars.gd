class_name PrimVizSpectrumBars
extends Primitive
## SPECTRUM BARS (visi-sonor light-show Slice 2A, items 7+8) — the classic audio-visualizer: one
## vertical bar per frequency band, each bar's HEIGHT driven by that band's energy. This is the
## DEMO-CRITICAL viz (the item-10 on-screen visualization the near-term demo shows).
##
## RENDERER-NEUTRAL DATA (T ideal): the node does NOT draw pixels. It emits a DRAW-LIST descriptor —
## a plain serializable dict { "viz":[ {kind:"bar", x,y,w,h, r,g,b}, ... ], "width","height",
## "kind":"spectrum_bars" } — so ANY consumer subscribes: a 2D screen delegate, prim_render2d as an
## effect SOURCE, or a light array reading each bar's height as a brightness. Pixel realization lives
## in the swappable static `rasterize()` (used by prim_render2d's source path / EffectStackCpu), so the
## look renders through the EXISTING render seam (R ideal) without this node ever holding a Godot Image.
##
## ITEM-8 REWIREABLE: each bar's value arrives on a WIRE (b0,b1,...,bN OR a single `bands` array), fed
## by prim_feature_pick from ANY part of the music. Repoint a pick from bass to treble and the SAME bar
## follows — a re-param, never an engine edit. NEVER hardwired to a band.
##
## COLOR: color_source="freq_to_color" (default) tints each bar warm->cool across the band index (low
## index = warm = bass, high = cool = treble — the item-6 mapping), referencing prim_freq_to_color's
## default palette endpoints so the demo is visually continuous. color_source="mono" uses params.color.
##
## params:
##   count       number of bars (default read from the wired bands / bN inputs, else 8).
##   layout      "linear" (bars left->right) | "radial" (bars around a circle). Default "linear".
##   mirror      bool — mirror the bars about the centre (a symmetric spectrum). Default false.
##   width,height  draw-list canvas size (default 128x64). Bars scale to this.
##   color_source  "freq_to_color" | "mono". Default "freq_to_color".
##   color       [r,g,b] for mono mode (default [0.2,0.8,1.0]).
##   palette     freq_to_color palette handle (default "default").
##   gap         0..1 fraction of each bar cell left as a gap (default 0.15).
##
## inputs:  bands — optional array of band values (0..1). OR b0,b1,...b31 scalar wires (one per bar).
## output:  out — the draw-list descriptor (renderer-neutral DATA).

const MAX_BARS := 32
const FreqToColorRef := preload("res://primitives/prim_freq_to_color.gd")

func _init() -> void:
	prim_type = "VizSpectrumBars"

func input_ports() -> Array:
	var ports: Array = [{ "name": "bands", "type": "any" }]
	for i in MAX_BARS:
		ports.append({ "name": "b%d" % i, "type": "number" })
	return ports

func output_ports() -> Array:
	return [{ "name": "out", "type": "image" }]

# Collect the band values: a wired `bands` array first, else the scalar bN wires up to `count`.
func _collect_bands(inputs: Dictionary) -> Array:
	var bands: Array = []
	var wired = inputs.get("bands")
	if typeof(wired) == TYPE_ARRAY:
		for v in wired:
			bands.append(as_num(v))
		return bands
	# Scalar wires b0..bN. count param, else the highest connected index + 1, else default 8.
	var count := int(params.get("count", 0))
	if count <= 0:
		# infer from connected wires
		for i in range(MAX_BARS - 1, -1, -1):
			if inputs.get("b%d" % i) != null:
				count = i + 1
				break
		if count <= 0:
			count = 8
	count = clampi(count, 1, MAX_BARS)
	for i in count:
		bands.append(as_num(inputs.get("b%d" % i)))
	return bands

func evaluate(inputs: Dictionary) -> Dictionary:
	var bands := _collect_bands(inputs)
	var w := int(params.get("width", 128))
	var h := int(params.get("height", 64))
	var layout := str(params.get("layout", "linear"))
	var mirror := bool(params.get("mirror", false))
	var gap: float = clamp(float(params.get("gap", 0.15)), 0.0, 0.9)
	var color_source := str(params.get("color_source", "freq_to_color"))
	var mono: Array = params.get("color", [0.2, 0.8, 1.0])
	var palette := str(params.get("palette", "default"))

	var viz: Array = []
	var n := bands.size()
	if n > 0:
		var pal := _palette_endpoints(palette)
		if layout == "radial":
			viz = _radial_bars(bands, w, h, pal, color_source, mono)
		else:
			viz = _linear_bars(bands, w, h, gap, mirror, pal, color_source, mono)

	return { "out": {
		"kind": "spectrum_bars",
		"viz": viz,
		"width": w,
		"height": h,
	} }

func _linear_bars(bands: Array, w: int, h: int, gap: float, mirror: bool, pal: Dictionary, color_source: String, mono: Array) -> Array:
	var out: Array = []
	var n := bands.size()
	var cell := float(w) / float(n)
	var bw := cell * (1.0 - gap)
	for i in n:
		var v: float = clampf(bands[i], 0.0, 1.0)
		var bh := v * float(h)
		var x := float(i) * cell + (cell - bw) * 0.5
		var y := float(h) - bh   # bars grow up from the bottom
		var col := _bar_color(i, n, v, pal, color_source, mono)
		out.append({ "kind": "bar", "x": x, "y": y, "w": bw, "h": bh, "r": col[0], "g": col[1], "b": col[2] })
	if mirror:
		# Reflect the bars about the horizontal centre for a symmetric look (grow up AND down).
		var mirrored: Array = []
		for b in out:
			var m := (b as Dictionary).duplicate()
			m["y"] = float(h) - float(b.get("y")) - float(b.get("h"))  # naive reflection placeholder
			mirrored.append(b)
			mirrored.append(m)
		return mirrored
	return out

func _radial_bars(bands: Array, w: int, h: int, pal: Dictionary, color_source: String, mono: Array) -> Array:
	var out: Array = []
	var n := bands.size()
	var cx := float(w) * 0.5
	var cy := float(h) * 0.5
	var r0 := minf(cx, cy) * 0.3
	var r_max := minf(cx, cy) * 0.95
	for i in n:
		var v: float = clampf(bands[i], 0.0, 1.0)
		var ang := TAU * float(i) / float(n) - PI * 0.5
		var r1 := r0 + v * (r_max - r0)
		var col := _bar_color(i, n, v, pal, color_source, mono)
		out.append({
			"kind": "line",
			"x0": cx + cos(ang) * r0, "y0": cy + sin(ang) * r0,
			"x1": cx + cos(ang) * r1, "y1": cy + sin(ang) * r1,
			"r": col[0], "g": col[1], "b": col[2],
		})
	return out

# Per-bar color: warm(low index)->cool(high index) across the spectrum, brightness from the value.
func _bar_color(i: int, n: int, v: float, pal: Dictionary, color_source: String, mono: Array) -> Array:
	if color_source != "freq_to_color":
		var b: float = clampf(v + 0.2, 0.0, 1.0)
		return [float(mono[0]) * b, float(mono[1]) * b, float(mono[2]) * b]
	var t := 0.0 if n <= 1 else float(i) / float(n - 1)   # 0=bass(warm), 1=treble(cool)
	var warm: Array = pal.get("warm", [1.0, 0.2, 0.0])
	var cool: Array = pal.get("cool", [0.0, 0.2, 1.0])
	var bright: float = clampf(0.35 + 0.65 * v, 0.0, 1.0)
	return [
		lerpf(float(warm[0]), float(cool[0]), t) * bright,
		lerpf(float(warm[1]), float(cool[1]), t) * bright,
		lerpf(float(warm[2]), float(cool[2]), t) * bright,
	]

# Resolve a palette handle -> { warm, cool } reusing prim_freq_to_color's default table (R ideal).
func _palette_endpoints(handle: String) -> Dictionary:
	if FreqToColorRef.PALETTES.has(handle):
		return FreqToColorRef.PALETTES[handle]
	return FreqToColorRef.PALETTES["default"]

## STATIC RASTERIZER — turns a renderer-neutral draw-list into an Image the EXISTING render seam
## consumes (prim_render2d source / EffectStackCpu). This is the swappable pixel delegate; a GPU or
## three.js delegate would rasterize the SAME draw-list differently. Kept generic: it handles the
## draw-list `kind`s ANY viz node emits (bar / line / polyline / polygon / point / fill), so ALL five
## viz nodes reuse this one rasterizer (R + reuse). A malformed / empty draw-list -> a blank image (C).
static func rasterize(drawlist, bg: Color = Color(0, 0, 0, 1.0)) -> Image:
	var w := 128
	var h := 64
	if typeof(drawlist) == TYPE_DICTIONARY:
		w = int(drawlist.get("width", 128))
		h = int(drawlist.get("height", 64))
	w = maxi(1, w)
	h = maxi(1, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	img.fill(bg)
	if typeof(drawlist) != TYPE_DICTIONARY:
		return img
	for item in drawlist.get("viz", []):
		if typeof(item) != TYPE_DICTIONARY:
			continue
		var col := Color(float(item.get("r", 1.0)), float(item.get("g", 1.0)), float(item.get("b", 1.0)), float(item.get("a", 1.0)))
		match String(item.get("kind", "")):
			"fill":
				# a full-canvas tint at alpha a (the flash node); alpha-composite over bg.
				var a := float(item.get("a", 1.0))
				for y in h:
					for x in w:
						var base := img.get_pixel(x, y)
						img.set_pixel(x, y, base.lerp(Color(col.r, col.g, col.b, 1.0), a))
			"bar":
				_fill_rect(img, float(item.get("x", 0)), float(item.get("y", 0)), float(item.get("w", 1)), float(item.get("h", 1)), col)
			"line":
				_draw_line(img, float(item.get("x0", 0)), float(item.get("y0", 0)), float(item.get("x1", 0)), float(item.get("y1", 0)), col)
			"point":
				_set_px(img, int(round(float(item.get("x", 0)))), int(round(float(item.get("y", 0)))), col)
	# polyline / polygon come as an ordered vertex list under the item-less top level for the shape /
	# waveform nodes: they emit their vertices directly into `viz` as {x,y} points with a `poly` flag.
	_rasterize_polys(img, drawlist)
	return img

# waveform / shape nodes put their ordered vertices in `viz` as {kind:"vertex", x,y, poly:bool}; connect
# consecutive vertices (closing the loop if `closed`).
static func _rasterize_polys(img: Image, drawlist: Dictionary) -> void:
	var verts: Array = []
	var col := Color(1, 1, 1, 1)
	var closed := bool(drawlist.get("closed", false))
	for item in drawlist.get("viz", []):
		if typeof(item) == TYPE_DICTIONARY and String(item.get("kind", "")) == "vertex":
			verts.append(Vector2(float(item.get("x", 0)), float(item.get("y", 0))))
			col = Color(float(item.get("r", 1.0)), float(item.get("g", 1.0)), float(item.get("b", 1.0)), 1.0)
	if verts.size() < 2:
		return
	for i in range(1, verts.size()):
		_draw_line(img, verts[i - 1].x, verts[i - 1].y, verts[i].x, verts[i].y, col)
	if closed:
		_draw_line(img, verts[verts.size() - 1].x, verts[verts.size() - 1].y, verts[0].x, verts[0].y, col)

static func _fill_rect(img: Image, x: float, y: float, w: float, hh: float, col: Color) -> void:
	var x0 := maxi(0, int(floor(x)))
	var y0 := maxi(0, int(floor(y)))
	var x1 := mini(img.get_width(), int(ceil(x + w)))
	var y1 := mini(img.get_height(), int(ceil(y + hh)))
	for py in range(y0, y1):
		for px in range(x0, x1):
			img.set_pixel(px, py, col)

static func _draw_line(img: Image, x0: float, y0: float, x1: float, y1: float, col: Color) -> void:
	# Integer Bresenham over the image bounds.
	var ix0 := int(round(x0)); var iy0 := int(round(y0))
	var ix1 := int(round(x1)); var iy1 := int(round(y1))
	var dx := absi(ix1 - ix0); var dy := -absi(iy1 - iy0)
	var sx := 1 if ix0 < ix1 else -1
	var sy := 1 if iy0 < iy1 else -1
	var err := dx + dy
	var guard := 0
	while true:
		_set_px(img, ix0, iy0, col)
		if ix0 == ix1 and iy0 == iy1:
			break
		var e2 := 2 * err
		if e2 >= dy:
			err += dy; ix0 += sx
		if e2 <= dx:
			err += dx; iy0 += sy
		guard += 1
		if guard > img.get_width() + img.get_height() + 4:
			break

static func _set_px(img: Image, x: int, y: int, col: Color) -> void:
	if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
		img.set_pixel(x, y, col)

## Pure: the draw-list is a deterministic function of inputs + params. Safe to memoize per-frame.
func is_cacheable() -> bool:
	return true
