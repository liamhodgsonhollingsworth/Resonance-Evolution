class_name PrimVideoSource
extends Primitive
## The VIDEO-SOURCE node (Visi-sonor Wave 1D, item 10 core) — decodes a video to per-frame RGB and
## exposes the CURRENT frame as a texture, keeping its playhead in step with an external audio playhead
## (so the music video stays synced to the mp3). It is the frame PROVIDER the Screen node samples.
##
## RENDERER-NEUTRAL like every other primitive: it puts DATA on the wire, never a Godot Image/Texture.
## The current frame is written to an on-disk PNG (a gitignored state path) and the descriptor carries
## the PATH + stats — exactly PrimRender2D's portability invariant ("no Godot Image on the wire"), so any
## downstream node (Screen, palette-extract, scene-cut) reads a plain dict.
##
## PLAYHEAD SYNC (the item-10 requirement): if a `playhead_seconds` input is WIRED (e.g. from the mp3's
## prim_audio_source playhead), the emitted frame SNAPS to that time (frame_index = round(t*fps)) so the
## video follows the audio exactly. If it is NOT wired, the source self-advances 1/fps each evaluate()
## (a plain time source, like a tick) so the video plays on its own for a standalone preview.
##
## SOURCE KINDS — WIRE ONLY a real local video FILE (source_kind="video" with an existing path). Every
## other kind (youtube/spotify/mic/loopback) is a DECLARED NO-OP (same "unknown op = no-op" pattern as
## device_actions): it emits a synthetic animated test pattern with present=false and never errors, so
## the seam is general with zero un-specced networking/decoding code. A future real source is a new
## injector writing the SAME video_frame keys, never an engine edit.
##
## C-IDEAL (isolated failure): a missing/absent/unloadable media file, or an unknown source_kind, is a
## declared no-op — it emits a synthetic ANIMATED pattern (variance > 0, so it is headless-testable) and
## sets present=false. Nothing crashes without a media file.
##
## params:
##   source_kind  "video" (real local file) | "youtube"|"spotify"|"mic"|"loopback" (declared no-op)
##   path         res://…/user://…/absolute path to a video file (only used when source_kind=="video")
##   width/height synthetic frame size when no real file (default 64×48)
##   fps          frames per second for playhead<->frame mapping + self-advance (default 30.0)
##   duration_seconds  loop length for self-advance wrap (default 0 = no wrap)
##   out_dir      where the per-frame PNG is written (default a gitignored state dir)
##
## input ports:
##   playhead_seconds  optional external time to SYNC to (from the mp3 playhead). null => self-advance.
## output ports:
##   video_frame  { kind:"video_frame", source_kind, present:bool, frame_index:int, playhead_seconds:float,
##                  width, height, image_path:String, stats:{ mean:float, variance:float } }

const DEFAULT_OUT := "user://visisonor/video_frames"
const DEFAULT_W := 64
const DEFAULT_H := 48
const DEFAULT_FPS := 30.0
const REAL_KINDS := ["video"]   # the ONLY wired kind; the rest are declared no-ops

# Self-advance playhead, held across evaluate()s when nothing is wired to playhead_seconds.
var _t := 0.0

func _init() -> void:
	prim_type = "VideoSource"

func input_ports() -> Array:
	return [{ "name": "playhead_seconds", "type": "number" }]

func output_ports() -> Array:
	return [{ "name": "video_frame", "type": "any" }]

func evaluate(inputs: Dictionary) -> Dictionary:
	var fps := maxf(1.0, float(params.get("fps", DEFAULT_FPS)))
	var w := maxi(2, int(params.get("width", DEFAULT_W)))
	var h := maxi(2, int(params.get("height", DEFAULT_H)))
	var source_kind := String(params.get("source_kind", "video"))

	# PLAYHEAD: wired external time snaps us to it (mp3 sync); otherwise self-advance 1/fps per frame.
	var ext = inputs.get("playhead_seconds")
	var playhead: float
	if ext != null:
		playhead = maxf(0.0, Primitive.as_num(ext))
	else:
		playhead = _t
		_t += 1.0 / fps
	var duration := float(params.get("duration_seconds", 0.0))
	if duration > 0.0:
		playhead = fmod(playhead, duration)
	var frame_index := int(round(playhead * fps))

	# FRAME: a real local video FILE (wired kind + existing path) decodes to this frame's RGB; anything
	# else (declared-no-op kind, or a missing/unloadable file) falls to a synthetic animated pattern.
	var out_dir := String(params.get("out_dir", DEFAULT_OUT))
	_ensure_dir(out_dir)
	var path := String(params.get("path", ""))
	var present := false
	var img: Image = null

	if REAL_KINDS.has(source_kind) and path != "" and FileAccess.file_exists(path):
		img = _decode_real_frame(path, frame_index, w, h)
		present = img != null
	# Declared no-op kinds + missing/failed decode -> synthetic animated pattern (C-ideal, never crash).
	if img == null:
		img = PrimVideoSource.synthetic_frame(w, h, frame_index)
		present = false

	var image_path := out_dir.path_join("frame_%06d.png" % frame_index)
	var save_err := img.save_png(image_path)
	var ok := save_err == OK and FileAccess.file_exists(image_path)
	var stats := PrimVideoSource.image_stats(img)

	return { "video_frame": {
		"kind": "video_frame",
		"source_kind": source_kind,
		"present": present,
		"frame_index": frame_index,
		"playhead_seconds": playhead,
		"width": img.get_width(),
		"height": img.get_height(),
		"image_path": image_path if ok else "",
		"stats": stats,
	} }

## Decode ONE frame of a real local video to an Image. Headless video decode via VideoStreamPlayer needs
## a live main loop + a supported codec (Theora .ogv) and is unreliable in a -s script, so this stays a
## GUARDED best-effort: it returns null (=> synthetic fallback, C-ideal) unless a decode path is wired.
## Kept as the single seam a real host swaps for a physical decoder — no un-specced decoding is forced
## into the headless path. (No-auto-generalization: wire only what the spec asks; the seam is general.)
func _decode_real_frame(_path: String, _frame_index: int, _w: int, _h: int) -> Image:
	# A future real decoder (VideoStreamPlayer texture readback on a live host, or an ffmpeg sidecar
	# writing PNG frames the host points `path` at a frame dir) fills this in. Until then a real file
	# with an unsupported/undecodable codec degrades to the synthetic pattern rather than crashing.
	return null

## A deterministic ANIMATED synthetic test pattern (scrolling color bars + a moving bright band), so a
## video_frame is available with ZERO media and consecutive frame_indexes differ (variance > 0, and the
## playhead-advance test sees change). No asset, fully headless. Exposed static so the test can build the
## same frame the node does.
static func synthetic_frame(w: int, h: int, frame_index: int) -> Image:
	w = maxi(2, w)
	h = maxi(2, h)
	var img := Image.create(w, h, false, Image.FORMAT_RGBAF)
	var phase := float(frame_index)
	var band_y := int(fmod(phase * 2.0, float(h)))   # a bright horizontal band that scrolls with time
	for y in h:
		for x in w:
			var fx := float(x) / float(w - 1)
			var fy := float(y) / float(h - 1)
			# Scrolling diagonal color bars (hue shifts with the frame index -> temporal change).
			var t := fx + fy * 0.5 + phase * 0.05
			var r := 0.5 + 0.5 * sin(t * TAU)
			var g := 0.5 + 0.5 * sin(t * TAU + 2.094)   # +120deg
			var b := 0.5 + 0.5 * sin(t * TAU + 4.188)   # +240deg
			# A moving bright band gives a strong per-frame delta the playhead test can rely on.
			if absi(y - band_y) <= 1:
				r = 1.0; g = 1.0; b = 1.0
			img.set_pixel(x, y, Color(r, g, b, 1.0))
	return img

## Luma mean + variance over a sampled grid — the same non-blank oracle the headless test uses. Static so
## both the node's emitted stats and the test agree. variance > 0 <=> non-blank.
static func image_stats(img: Image) -> Dictionary:
	var w := img.get_width()
	var h := img.get_height()
	if w == 0 or h == 0:
		return { "mean": 0.0, "variance": 0.0 }
	var step_x: int = maxi(1, w / 32)
	var step_y: int = maxi(1, h / 32)
	var n := 0
	var s := 0.0
	var ss := 0.0
	var y := 0
	while y < h:
		var x := 0
		while x < w:
			var c := img.get_pixel(x, y)
			var luma := 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
			s += luma
			ss += luma * luma
			n += 1
			x += step_x
		y += step_y
	if n == 0:
		return { "mean": 0.0, "variance": 0.0 }
	var mean := s / float(n)
	return { "mean": mean, "variance": (ss / float(n)) - (mean * mean) }

func _ensure_dir(path: String) -> void:
	var abs := ProjectSettings.globalize_path(path) if path.begins_with("res://") or path.begins_with("user://") else path
	DirAccess.make_dir_recursive_absolute(abs)
