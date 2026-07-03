class_name StereoMode
extends Node
## STEREO as a PORTABLE RENDERER MODE — the perspective-logic morph that turns ONE image on the
## screen into TWO images of the EXACT same scene, continuously, with the same math continuing
## into VR. The third instantiation of the "portable renderer feature" pattern (after the detail
## knob and FocusField): it wraps ANY scene/View **without modifying it** — hand it the active
## Camera3D + a `stereo` DATA block and it renders the scene through one-or-two eye SubViewports
## that SHARE the host camera's World3D (no reparenting, no scene edits).
##
## THE ONE→TWO TRANSITION (all closed-form, decoder-tested in headless_stereo_mode_test.gd):
##   t ∈ [0,1] is the single morph parameter.
##     ipd_eff(t)   = t · ipd_m                      (eyes separate linearly from the cyclopean point)
##     rect_e(t)    = lerp([0,0,1,1], target_e, t)   (each eye's screen rect morphs full-frame → target)
##   Because pair disparity is linear in eye separation,   d_t(Z) = t · d_1(Z)  — depth "turns on"
##   linearly with the slider. At t = 0 both eyes coincide (offset 0 → symmetric frustum): the display
##   IS the mono frame, pixel-exact. At t = 1 the per-eye descriptors are EXACTLY
##   StereoRig.eye_descriptors(geometry) — the same numbers a headset adapter reads (the OpenXR seam
##   documented in stereo_rig.gd) — so screen pair ⇄ VR per-eye is the SAME geometry dict, and the
##   morph is a continuous path from flat screen to VR.
##
## REPOSITIONABLE: where the two images sit on the screen is DATA (`layout.rects`, normalized
## [x,y,w,h] per EYE). Default `"cross"` layout puts the LEFT eye's image on the RIGHT half so
## crossing your eyes fuses the actual scene in depth; `"parallel"` keeps L|R for wall-eyed
## viewing / phone-in-cardboard. Any placement works — the rects are yours.
##
## NOT the SIRDS path: this renders the scene itself (the pictures you fuse ARE the scene), per
## Liam's 2026-07-03 correction — the "periodic mess of colors" generator stays (append-only) in
## prim_stereo_render.gd; the geometry model (PrimStereoRender.derive + stereo_rig.gd) is shared.
##
## Reference oracle discipline (same as FocusField/EffectStackCpu): the pure statics below
## (`morph`, `eye_rects`, `compose_display`, `fit_geometry_to_camera`) are the closed-form model;
## the live node consumes the SAME descriptors, so the headless CPU proof covers the live path.

const FULL_RECT := [0.0, 0.0, 1.0, 1.0]

## Default t=1 target rects, keyed by EYE (not by screen side — the cross eye-swap is explicit
## data): cross puts the LEFT eye's image on the RIGHT half. Half-size, vertically centred, so a
## window whose aspect matches the eye image keeps each half undistorted.
const DEFAULT_RECTS := {
	"cross": { "left": [0.5, 0.25, 0.5, 0.5], "right": [0.0, 0.25, 0.5, 0.5] },
	"parallel": { "left": [0.0, 0.25, 0.5, 0.5], "right": [0.5, 0.25, 0.5, 0.5] },
}
const DEFAULT_BACKGROUND := [0.02, 0.02, 0.02]

# =============================== the pure model (statics) ===============================

## Merge a layout block over defaults: { "mode": "cross"|"parallel", "rects": { left, right } }.
## Explicit per-eye rects win; missing eyes fall back to the mode's default.
static func default_layout(layout_in: Dictionary = {}) -> Dictionary:
	var mode := String(layout_in.get("mode", "cross"))
	if not DEFAULT_RECTS.has(mode):
		mode = "cross"
	var base: Dictionary = DEFAULT_RECTS[mode]
	var given: Dictionary = layout_in.get("rects", {}) if typeof(layout_in.get("rects")) == TYPE_DICTIONARY else {}
	var rects := {}
	for side in ["left", "right"]:
		var r = given.get(side)
		rects[side] = (r as Array).duplicate() if (r is Array and (r as Array).size() >= 4) else (base[side] as Array).duplicate()
	return { "mode": mode, "rects": rects }

static func _lerp_rect(a: Array, b: Array, t: float) -> Array:
	var out := []
	for k in 4:
		out.append(lerpf(float(a[k]), float(b[k]), t))
	return out

## Per-eye normalized screen rects at morph position t: full-frame at 0, the layout targets at 1.
static func eye_rects(layout_in: Dictionary, t: float) -> Dictionary:
	var lay := default_layout(layout_in)
	var tc := clampf(t, 0.0, 1.0)
	return {
		"left": _lerp_rect(FULL_RECT, lay["rects"]["left"], tc),
		"right": _lerp_rect(FULL_RECT, lay["rects"]["right"], tc),
	}

## THE MORPH: geometry dict + t → everything the display needs, as one JSON-able descriptor:
##   { t, ipd_eff_m, geometry (derived, ipd scaled), eyes { left, right } (StereoRig descriptors —
##     at t=1 EXACTLY StereoRig.eye_descriptors(geo)), rects { left, right }, layout }
static func morph(geo_in: Dictionary, t: float, layout_in: Dictionary = {}) -> Dictionary:
	var tc := clampf(t, 0.0, 1.0)
	var geo_eff := geo_in.duplicate(true)
	geo_eff["ipd_m"] = float(geo_in.get("ipd_m", PrimStereoRender.DEFAULT_GEOMETRY["ipd_m"])) * tc
	var eyes := StereoRig.eye_descriptors(geo_eff)
	return {
		"t": tc,
		"ipd_eff_m": float(geo_eff["ipd_m"]),
		"geometry": eyes["geometry"],
		"eyes": { "left": eyes["left"], "right": eyes["right"] },
		"rects": eye_rects(layout_in, tc),
		"layout": default_layout(layout_in),
	}

## Signed pair disparity (px) of a point at viewer-distance z_m, at morph position t.
## Linear in t by construction: disparity_px(geo, t, z) == t · disparity_px(geo, 1, z).
static func disparity_px(geo_in: Dictionary, t: float, z_m: float) -> float:
	var geo := PrimStereoRender.derive(geo_in)
	return clampf(t, 0.0, 1.0) * PrimStereoRender.pair_disparity_px(geo, z_m)

## Derive the screen-geometry fields FROM a wrapped camera so t=0 reproduces the host camera's
## exact framing: H_m = 2·D·tan(fov/2) ⇒ the t=0 symmetric frustum's near-plane height
## (H_m·zn/D = 2·zn·tan(fov/2)) equals the perspective camera's own — the mono frame IS the
## host's view. fov is the VERTICAL fov (Godot keep_aspect KEEP_HEIGHT default); width follows
## the image aspect. Explicit znear_m/zfar_m in geo_in win over the camera's clips.
static func fit_geometry_to_camera(geo_in: Dictionary, cam: Camera3D) -> Dictionary:
	var g := geo_in.duplicate(true)
	var d := float(g.get("screen_distance_m", PrimStereoRender.DEFAULT_GEOMETRY["screen_distance_m"]))
	var w_px := int(g.get("image_width_px", PrimStereoRender.DEFAULT_GEOMETRY["image_width_px"]))
	var h_px := int(g.get("image_height_px", PrimStereoRender.DEFAULT_GEOMETRY["image_height_px"]))
	var h_m := 2.0 * d * tan(deg_to_rad(cam.fov) / 2.0)
	g["screen_width_m"] = h_m * float(w_px) / maxf(1.0, float(h_px))
	if not g.has("znear_m"):
		g["znear_m"] = cam.near
	if not g.has("zfar_m"):
		g["zfar_m"] = cam.far
	return g

## CPU reference compositor — the EXACT display semantics the live TextureRects implement
## (normalized rects → pixel rects, stretch-to-rect, right drawn first / left on top, dark
## background). Deterministic (nearest-neighbour resize). This is what the decoder test proves;
## at t=0 (both rects full-frame, identical images) the output is byte-identical to the mono frame.
static func compose_display(left: Image, right: Image, rects: Dictionary, out_w: int, out_h: int,
		background: Array = DEFAULT_BACKGROUND) -> Image:
	var img := Image.create(out_w, out_h, false, Image.FORMAT_RGB8)
	img.fill(Color(float(background[0]), float(background[1]), float(background[2])))
	for side in ["right", "left"]:  # fixed draw order: left eye on top
		var r: Array = rects[side]
		var px := Rect2i(roundi(float(r[0]) * out_w), roundi(float(r[1]) * out_h),
			roundi(float(r[2]) * out_w), roundi(float(r[3]) * out_h))
		if px.size.x <= 0 or px.size.y <= 0:
			continue
		var src := (left if side == "left" else right)
		if src.get_width() != px.size.x or src.get_height() != px.size.y:
			src = src.duplicate()
			src.resize(px.size.x, px.size.y, Image.INTERPOLATE_NEAREST)
		img.blit_rect(src, Rect2i(0, 0, px.size.x, px.size.y), px.position)
	return img

# =============================== the live wrapper (portable) ===============================

var params: Dictionary = {}
var source_camera: Camera3D = null
var eye_views := {}   # side -> SubViewport (shares the host camera's World3D)
var eye_cams := {}    # side -> Camera3D (off-axis frustum, follows source_camera every frame)
var eye_ui := {}      # side -> TextureRect (position/size = the rect DATA)
var _layer: CanvasLayer = null
var _backdrop: ColorRect = null
var _ui_host: Node = null
var _last: Dictionary = {}

## Wrap the active camera of ANY scene. `stereo` block (all DATA, hotload-safe):
##   { "t": 0..1, "geometry": {…}, "layout": { "mode", "rects" }, "fit_camera": true,
##     "background": [r,g,b] }
## `ui_parent` (optional Control/CanvasLayer) hosts the display rects; defaults to an own
## CanvasLayer, so wrapping is a 2-liner in any host scene. Returns the morph descriptor.
func wrap(cam: Camera3D, stereo: Dictionary = {}, ui_parent: Node = null) -> Dictionary:
	source_camera = cam
	if _ui_host == null:
		if ui_parent != null:
			_ui_host = ui_parent
		else:
			_layer = CanvasLayer.new()
			_layer.name = "StereoModeLayer"
			add_child(_layer)
			_ui_host = _layer
	if _backdrop == null:
		_backdrop = ColorRect.new()
		_backdrop.name = "StereoBackdrop"
		_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
		_ui_host.add_child(_backdrop)
	for side in ["right", "left"]:  # right first ⇒ left's TextureRect draws on top (compositor order)
		if not eye_views.has(side):
			var sub := SubViewport.new()
			sub.name = "Eye" + side.capitalize()
			sub.own_world_3d = false
			sub.render_target_update_mode = SubViewport.UPDATE_ALWAYS
			add_child(sub)
			var ecam := Camera3D.new()
			ecam.name = "Cam" + side.capitalize()
			sub.add_child(ecam)
			ecam.current = true
			var rect := TextureRect.new()
			rect.name = "View" + side.capitalize()
			rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			rect.stretch_mode = TextureRect.STRETCH_SCALE
			rect.texture = sub.get_texture()
			_ui_host.add_child(rect)
			eye_views[side] = sub
			eye_cams[side] = ecam
			eye_ui[side] = rect
	return apply(stereo)

## (Re-)drive everything from the stereo DATA block — hotload discipline: re-wires the SAME
## SubViewport/Camera/TextureRect instances, never rebuilds. Call on every params-file change.
func apply(stereo: Dictionary) -> Dictionary:
	params = stereo if typeof(stereo) == TYPE_DICTIONARY else {}
	var geo: Dictionary = params.get("geometry", {}) if typeof(params.get("geometry")) == TYPE_DICTIONARY else {}
	if bool(params.get("fit_camera", true)) and source_camera != null:
		geo = fit_geometry_to_camera(geo, source_camera)
	var t := clampf(float(params.get("t", 1.0)), 0.0, 1.0)
	var m := morph(geo, t, params.get("layout", {}) if typeof(params.get("layout")) == TYPE_DICTIONARY else {})
	var g: Dictionary = m["geometry"]
	var bg: Array = params.get("background", DEFAULT_BACKGROUND)
	if _backdrop != null:
		_backdrop.color = Color(float(bg[0]), float(bg[1]), float(bg[2]))
	for side in ["left", "right"]:
		var sub: SubViewport = eye_views[side]
		if source_camera != null and source_camera.is_inside_tree():
			sub.world_3d = source_camera.get_world_3d()
		sub.size = Vector2i(int(g["image_width_px"]), int(g["image_height_px"]))
		_drive_eye(eye_cams[side], m["eyes"][side])
		_place_rect(eye_ui[side], m["rects"][side])
	# t=0: the two images are identical — render + show only the left (the mono frame).
	var mono := t <= 0.0001
	(eye_views["right"] as SubViewport).render_target_update_mode = (
		SubViewport.UPDATE_DISABLED if mono else SubViewport.UPDATE_ALWAYS)
	(eye_ui["right"] as TextureRect).visible = not mono
	_last = m
	_sync_cameras()
	return m

## Off-axis frustum from the eye descriptor (transform is set by _sync_cameras, in the source
## camera's frame — that is what makes the wrapper portable to any moving camera).
static func _drive_eye(cam: Camera3D, d: Dictionary) -> void:
	cam.projection = Camera3D.PROJECTION_FRUSTUM
	cam.size = float(d["frustum_size"])
	cam.frustum_offset = Vector2(float(d["frustum_offset"][0]), float(d["frustum_offset"][1]))
	cam.near = float(d["znear"])
	cam.far = float(d["zfar"])

func _place_rect(rect: TextureRect, r: Array) -> void:
	rect.anchor_left = float(r[0])
	rect.anchor_top = float(r[1])
	rect.anchor_right = float(r[0]) + float(r[2])
	rect.anchor_bottom = float(r[1]) + float(r[3])
	rect.offset_left = 0.0
	rect.offset_top = 0.0
	rect.offset_right = 0.0
	rect.offset_bottom = 0.0

## Every frame: the eye cameras ride the source camera (offset ±ipd_eff/2 along its local X),
## so ANY camera motion — walkabout, orbit, animation — is stereo'd with zero host changes.
func _process(_delta: float) -> void:
	_sync_cameras()

func _sync_cameras() -> void:
	if source_camera == null or not is_instance_valid(source_camera) or _last.is_empty() \
			or not source_camera.is_inside_tree():
		return
	for side in ["left", "right"]:
		if (eye_views[side] as SubViewport).world_3d == null:
			(eye_views[side] as SubViewport).world_3d = source_camera.get_world_3d()
	for side in ["left", "right"]:
		var p: Array = _last["eyes"][side]["position"]
		(eye_cams[side] as Camera3D).global_transform = source_camera.global_transform \
			* Transform3D(Basis.IDENTITY, Vector3(float(p[0]), float(p[1]), float(p[2])))
