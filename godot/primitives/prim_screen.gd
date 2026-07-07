class_name PrimScreen
extends Primitive
## The SCREEN node (Visi-sonor Wave 1D, item 10 core) — a TV/screen in the room: a flat QUAD whose
## material albedo texture is a moving image. NO projection mapping (item 10: "TV/screen, NO projection
## mapping"). Two sources, selected by params.source:
##   music_video  — the quad shows the reacted song's music video: it takes a `video_frame` (from a
##                  PrimVideoSource wired to the mp3 playhead) and puts that frame's texture on the quad.
##   classic_viz  — the quad shows a classic generative visualization driven by the audio LEVEL (read
##                  off the same set_input_frame band seam the lights use), so it reacts to the music
##                  with no video file at all.
##
## RENDERER-NEUTRAL like PrimLight/PrimView: it emits a `screen` DESCRIPTOR dict (quad mesh + a glTF-
## aligned transform + a material whose albedo_texture is a PNG PATH), never a live MeshInstance3D. The
## renderer delegate builds the quad; a glTF/three.js delegate reads the same descriptor. The albedo_texture
## PATH follows the EXISTING material-descriptor convention (see prim_texture_apply.gd's albedo_texture).
##
## NON-BLANK IN HEADLESS + NO-CRASH-WITHOUT-MEDIA (C-ideal): the texture is always a real on-disk PNG.
## For music_video with no wired frame (or a frame that failed) it FALLS BACK to a synthetic animated
## pattern; for classic_viz it renders a spectrum-bar frame from the audio level (synthetic pulse when no
## audio). Either way the emitted texture has variance > 0 and nothing crashes when a media file is absent.
##
## REUSE (R-ideal): the fallback / classic-viz texture is generated with PrimRender2D's synthetic-source
## machinery style + PrimVideoSource.synthetic_frame — the screen is JUST a quad + a texture provider; no
## new pixel engine.
##
## params:
##   source     "classic_viz" | "music_video"          (default "classic_viz")
##   size       [w,h] quad size in meters               (default [1.6, 0.9] — 16:9)
##   position   [x,y,z] meters (quad placement)         (default [0,1.5,-2])
##   rotation   [x,y,z] degrees (quad aim)              (default [0,0,0])
##   width/height  generated-texture pixel size          (default 64×48) — classic_viz + fallback frames
##   band_keys  the 3 frame keys read for classic_viz    (default signal.band.low/mid/high)
##   out_dir    where a generated texture PNG is written  (default a gitignored state dir)
##
## input ports:
##   video_frame  a PrimVideoSource `video_frame` descriptor (used when source=="music_video").
## output ports:
##   screen  { kind:"screen", source, mesh:"quad", size:[w,h], transform:{translation,rotation,scale},
##            material:{ albedo:[r,g,b], albedo_texture:String },
##            texture:{ image_path:String, width, height, stats:{mean,variance} } }

const DEFAULT_OUT := "user://visisonor/screen_frames"
const DEFAULT_SIZE := [1.6, 0.9]
const DEFAULT_POS := [0.0, 1.5, -2.0]
const DEFAULT_W := 64
const DEFAULT_H := 48
const DEFAULT_BAND_KEYS := ["signal.band.low", "signal.band.mid", "signal.band.high"]

# Self-advancing phase for the classic viz animation when time is otherwise static.
var _phase := 0

func _init() -> void:
	prim_type = "Screen"

func input_ports() -> Array:
	return [{ "name": "video_frame", "type": "any" }]

func output_ports() -> Array:
	return [{ "name": "screen", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var source := String(params.get("source", "classic_viz"))
	var w := maxi(2, int(params.get("width", DEFAULT_W)))
	var h := maxi(2, int(params.get("height", DEFAULT_H)))
	var out_dir := String(params.get("out_dir", DEFAULT_OUT))
	_ensure_dir(out_dir)

	var tex_path := ""
	var tex_stats := { "mean": 0.0, "variance": 0.0 }
	var tex_w := w
	var tex_h := h

	if source == "music_video":
		# Show the wired VideoSource frame. If it carries a usable image_path, reference it DIRECTLY
		# (renderer-neutral, no re-encode). If absent/failed (no wire, missing media), fall back to a
		# synthetic animated pattern so the quad is never blank and nothing crashes (C-ideal).
		var vf = inputs.get("video_frame")
		var vf_path := ""
		if typeof(vf) == TYPE_DICTIONARY:
			vf_path = String(vf.get("image_path", ""))
		if vf_path != "" and FileAccess.file_exists(vf_path):
			tex_path = vf_path
			tex_stats = vf.get("stats", tex_stats)
			tex_w = int(vf.get("width", w))
			tex_h = int(vf.get("height", h))
		else:
			var img := PrimVideoSource.synthetic_frame(w, h, _phase)
			_phase += 1
			tex_path = out_dir.path_join("screen_mv_fallback_%06d.png" % _phase)
			img.save_png(tex_path)
			tex_stats = PrimVideoSource.image_stats(img)
	else:
		# classic_viz — an audio-driven spectrum-bar visualization. Read the 3 band levels off the SAME
		# set_input_frame seam the lights read (reach the runtime through the parent, exactly like
		# PrimInput). No audio -> a synthetic pulse so it is never blank.
		var bands := _read_bands()
		var img := PrimScreen.classic_viz_frame(w, h, bands, _phase)
		_phase += 1
		tex_path = out_dir.path_join("screen_viz_%06d.png" % _phase)
		img.save_png(tex_path)
		tex_stats = PrimVideoSource.image_stats(img)

	var ok := tex_path != "" and FileAccess.file_exists(tex_path)
	return { "screen": {
		"kind": "screen",
		"source": source,
		"mesh": "quad",
		"size": _v2(params.get("size", DEFAULT_SIZE), DEFAULT_SIZE),
		"transform": {
			"translation": _v3(params.get("position", DEFAULT_POS), DEFAULT_POS),
			"rotation": _euler_deg_to_quat(params.get("rotation", [0.0, 0.0, 0.0])),
			"scale": [1.0, 1.0, 1.0],
		},
		"material": {
			"albedo": [1.0, 1.0, 1.0],
			"albedo_texture": tex_path if ok else "",
		},
		"texture": {
			"image_path": tex_path if ok else "",
			"width": tex_w,
			"height": tex_h,
			"stats": tex_stats,
		},
	} }

## Read the 3 audio band levels from the runtime's per-frame FRAME (the same seam the lights read),
## reached through the parent runtime exactly like PrimInput. Absent keys / no frame -> 0.0 (harmless).
func _read_bands() -> Array:
	var keys = params.get("band_keys", DEFAULT_BAND_KEYS)
	if not (keys is Array) or (keys as Array).size() < 3:
		keys = DEFAULT_BAND_KEYS
	var out := [0.0, 0.0, 0.0]
	var rt := get_parent()
	if rt != null and rt.has_method("get_input_frame"):
		var frame: Dictionary = rt.call("get_input_frame")
		for i in 3:
			var k := str(keys[i])
			if frame.has(k):
				out[i] = clampf(Primitive.as_num(frame[k]), 0.0, 1.0)
	return out

## A classic spectrum-bar visualization frame: N vertical bars whose heights come from the (low,mid,high)
## band levels, on a dark background, with a subtle scrolling tint so consecutive frames differ even when
## the audio is static. If all bands are ~0 (no audio) a synthetic pulse keeps it non-blank (never blank
## => variance > 0). Static + headless; exposed static so the test can reason about it.
static func classic_viz_frame(w: int, h: int, bands: Array, phase: int) -> Image:
	w = maxi(2, w)
	h = maxi(2, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	var lo := 0.0
	var mid := 0.0
	var hi := 0.0
	if bands is Array and bands.size() >= 3:
		lo = clampf(float(bands[0]), 0.0, 1.0)
		mid = clampf(float(bands[1]), 0.0, 1.0)
		hi = clampf(float(bands[2]), 0.0, 1.0)
	# No-audio pulse: if all bands are ~0, synthesize a moving level so the viz is never blank.
	if lo + mid + hi < 0.001:
		var p := 0.5 + 0.5 * sin(float(phase) * 0.3)
		lo = p; mid = 0.6 * p; hi = 0.3 * p
	var n_bars := 16
	for x in w:
		var fx := float(x) / float(w - 1)
		# Pick which band this column belongs to (low third, mid third, high third).
		var band_level := lo
		var bar_color := Color(1.0, 0.55, 0.2)   # warm for low (bass)
		if fx > 0.6667:
			band_level = hi
			bar_color = Color(0.3, 0.7, 1.0)     # cool for high (treble)
		elif fx > 0.3333:
			band_level = mid
			bar_color = Color(0.6, 1.0, 0.5)     # green-ish mid
		# Bar height with a small per-bar variation so bars are distinct (spectrum look).
		var bar_i := int(fx * float(n_bars))
		var jitter := 0.15 * sin(float(bar_i) * 1.7 + float(phase) * 0.2)
		var bar_h := clampf(band_level + jitter, 0.0, 1.0)
		for y in h:
			var fy := 1.0 - float(y) / float(h - 1)   # 0 at bottom, 1 at top
			var c: Color
			if fy <= bar_h:
				# inside the bar — brighten toward the top edge
				var edge := 1.0 - (bar_h - fy) * 2.0
				c = bar_color * (0.6 + 0.4 * clampf(edge, 0.0, 1.0))
			else:
				# background — a faint scrolling gradient so it is never a flat solid
				var bg := 0.06 + 0.04 * sin((fx + float(phase) * 0.02) * TAU)
				c = Color(bg, bg, bg * 1.2)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, 1.0))
	return img

# --- helpers (renderer-neutral, JSON-serializable arrays like prim_view/prim_light) -----------------

func _v2(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 2:
		return [float(a[0]), float(a[1])]
	return fallback

func _v3(a, fallback: Array) -> Array:
	if a is Array and (a as Array).size() >= 3:
		return [float(a[0]), float(a[1]), float(a[2])]
	return fallback

func _euler_deg_to_quat(a) -> Array:
	var e := _v3(a, [0.0, 0.0, 0.0])
	var q := Quaternion.from_euler(Vector3(deg_to_rad(e[0]), deg_to_rad(e[1]), deg_to_rad(e[2])))
	return [q.x, q.y, q.z, q.w]

func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs)
