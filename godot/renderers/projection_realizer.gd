class_name ProjectionRealizer
extends RefCounted
## Realizes the renderer-neutral PROJECTOR descriptor two ways:
##
##  1. CPU (headless twin, deterministic): rasterize the warped calibration pattern into the
##     projector's input image, and ray-render WHAT THE WITNESS CAMERA SEES of the projection
##     landing on the surface — pixel-exact against ProjectionMath, no GPU. This is the path
##     the headless proofs/tests use (Godot --headless has a dummy renderer: no viewport
##     readback), mirroring the EffectStackGpu.emulate pattern.
##
##  2. LIVE (windowed demo): a SpotLight3D with the rasterized input as its light_projector
##     cookie — true perspective projection onto ARBITRARY scene geometry (oblique planes,
##     curved meshes, GLBs) with occlusion via shadows, and NO per-material shader surgery.
##     Chosen over: Decal (projects ORTHOGRAPHICALLY along -Y — physically wrong for a
##     projector frustum, no oblique perspective spread) and a custom projected-UV shader
##     (optically exact but must be injected into every receiving material — breaks the
##     "arrangements over arbitrary models" law; it is the later upgrade if cookie mapping
##     precision ever matters). The CPU seam stays the calibration source of truth either way.

# ── 1a. projector INPUT image: the warped pattern, rasterized ────────────────────────────────

## Draw the pattern's fiducial dots (warped by map.matrix) into the projector's pixel grid.
## Black field, white dots — exactly what the projector "emits".
static func rasterize_input(pattern: Dictionary, map, resolution: Array) -> Image:
	var w := int(resolution[0])
	var h := int(resolution[1])
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	img.fill(Color(0.0, 0.0, 0.0))
	if typeof(pattern) != TYPE_DICTIONARY:
		return img
	var warp: Array = ProjectionMath.mat_identity()
	if typeof(map) == TYPE_DICTIONARY and ProjectionMath.mat_is_valid((map as Dictionary).get("matrix")):
		warp = (map as Dictionary)["matrix"]
	var r := maxf(float(pattern.get("dot_radius", 0.012)) * float(w), 1.5)
	for pt in pattern.get("points", []):
		var base := Vector2(float(pt["u"]) * w, float(pt["v"]) * h)
		var p := ProjectionMath.apply_h(warp, base)
		_fill_circle(img, p, r, Color(1.0, 1.0, 1.0))
	return img

static func _fill_circle(img: Image, c: Vector2, r: float, col: Color) -> void:
	var x0 := maxi(int(c.x - r) - 1, 0)
	var x1 := mini(int(c.x + r) + 1, img.get_width() - 1)
	var y0 := maxi(int(c.y - r) - 1, 0)
	var y1 := mini(int(c.y + r) + 1, img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			if Vector2(x + 0.5, y + 0.5).distance_to(c) <= r:
				img.set_pixel(x, y, col)

# ── 1b. the OBSERVED view: CPU ray-render of the witness camera (the headless proof) ────────

## Render what the witness camera sees: for every camera pixel, cast a ray, land on the
## surface, and look that world point back up through the projector to sample its (warped)
## input image. Overlays: GREEN rings where the fiducials SHOULD land (targets); the white
## dots are where they DO land. Deterministic, CPU-only.
static func render_observed(view: Dictionary, cam_res: Array, surface: Dictionary,
		projector: Dictionary, input_img: Image, correspondences: Array) -> Image:
	var w := int(cam_res[0])
	var h := int(cam_res[1])
	var img := Image.create(w, h, false, Image.FORMAT_RGB8)
	var cam_pose: Transform3D = PrimProjectionObserve.view_pose(view)
	var cam_yfov := float(view.get("yfov", deg_to_rad(45.0)))
	var cam_aspect := float(w) / float(h)
	var res_v := Vector2(float(w), float(h))
	var proj_pose: Transform3D = PrimProjectionObserve.projector_pose(projector)
	var proj_res := Vector2(float(projector["resolution"][0]), float(projector["resolution"][1]))
	var proj_yfov := float(projector.get("yfov", deg_to_rad(30.0)))
	var proj_aspect := float(projector.get("aspect", proj_res.x / proj_res.y))
	var bg := Color(0.05, 0.05, 0.07)
	var surf_base := Color(0.16, 0.16, 0.18)
	var beam := Color(0.75, 0.85, 1.0)
	for y in h:
		for x in w:
			var ray := ProjectionMath.px_ray(cam_pose, cam_yfov, cam_aspect, res_v, Vector2(x + 0.5, y + 0.5))
			var hit := ProjectionMath.intersect_surface(surface, ray["origin"], ray["dir"])
			if not hit["hit"]:
				img.set_pixel(x, y, bg)
				continue
			# Cheap lambert off the camera direction keeps the surface readable.
			var shade: float = clampf(abs((hit["normal"] as Vector3).dot(ray["dir"])), 0.35, 1.0)
			var col := surf_base * shade
			var back := ProjectionMath.project_px(proj_pose, proj_yfov, proj_aspect, proj_res, hit["point"])
			if back["ok"]:
				var px: Vector2 = back["px"]
				if px.x >= 0.0 and px.x < proj_res.x and px.y >= 0.0 and px.y < proj_res.y:
					var s := input_img.get_pixel(int(px.x), int(px.y))
					col = col + beam * s.r  # additive light, like a real projector
			img.set_pixel(x, y, col.clamp())
	# Overlay the intent: green target rings (+ a red tick at each observed dot center, so
	# before/after reads at a glance even where dots are dim).
	for rec in correspondences:
		if typeof(rec) != TYPE_DICTIONARY:
			continue
		var t = (rec as Dictionary).get("target")
		if t is Array and (t as Array).size() >= 2:
			_ring(img, Vector2(float(t[0]), float(t[1])), 6.0, 1.4, Color(0.2, 1.0, 0.35))
		if bool((rec as Dictionary).get("valid", false)):
			var o = (rec as Dictionary)["observed"]
			_fill_circle(img, Vector2(float(o[0]), float(o[1])), 1.6, Color(1.0, 0.35, 0.25))
	return img

static func _ring(img: Image, c: Vector2, r: float, thickness: float, col: Color) -> void:
	var x0 := maxi(int(c.x - r - thickness) - 1, 0)
	var x1 := mini(int(c.x + r + thickness) + 1, img.get_width() - 1)
	var y0 := maxi(int(c.y - r - thickness) - 1, 0)
	var y1 := mini(int(c.y + r + thickness) + 1, img.get_height() - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var d := absf(Vector2(x + 0.5, y + 0.5).distance_to(c) - r)
			if d <= thickness:
				img.set_pixel(x, y, col)

## Side-by-side composite (before | divider | after) for a single proof image.
static func side_by_side(a: Image, b: Image) -> Image:
	var w := a.get_width()
	var h := a.get_height()
	var out := Image.create(w * 2 + 4, h, false, Image.FORMAT_RGB8)
	out.fill(Color(1.0, 1.0, 1.0))
	out.blit_rect(a, Rect2i(0, 0, w, h), Vector2i(0, 0))
	out.blit_rect(b, Rect2i(0, 0, b.get_width(), b.get_height()), Vector2i(w + 4, 0))
	return out

# ── 2. LIVE realization: SpotLight3D + light_projector cookie (the windowed demo) ────────────

## Build (or re-drive) a SpotLight3D from the projector descriptor + its rasterized input.
## The cookie must be square-ish for a spot cone, so the input is letterboxed into a square.
static func drive_spotlight(light: SpotLight3D, projector: Dictionary, input_img: Image) -> void:
	var pose: Transform3D = PrimProjectionObserve.projector_pose(projector)
	light.transform = pose
	var yfov := float(projector.get("yfov", deg_to_rad(30.0)))
	var aspect := float(projector.get("aspect", 16.0 / 9.0))
	var hfov := 2.0 * atan(tan(yfov * 0.5) * aspect)
	# Cover the frustum diagonal so the whole rectangular image fits inside the cone.
	var half_diag := atan(sqrt(pow(tan(yfov * 0.5), 2.0) + pow(tan(hfov * 0.5), 2.0)))
	light.spot_angle = rad_to_deg(half_diag)
	light.spot_range = 20.0
	light.spot_attenuation = 0.4
	light.light_energy = 6.0
	light.shadow_enabled = true
	# Reuse the one cookie texture across re-drives (set_image in place): re-ASSIGNING
	# light_projector each step churns the renderer's decal atlas (and logs engine errors).
	var cookie := _letterbox_square(input_img, half_diag, yfov, hfov)
	if light.light_projector is ImageTexture:
		(light.light_projector as ImageTexture).set_image(cookie)
	else:
		light.light_projector = ImageTexture.create_from_image(cookie)

static func make_spotlight(projector: Dictionary, input_img: Image) -> SpotLight3D:
	var light := SpotLight3D.new()
	light.name = "SimulatedProjector"
	drive_spotlight(light, projector, input_img)
	return light

## Pad the rectangular projector image into the square cookie footprint of the spot cone.
## The image occupies the angular sub-rectangle (hfov x yfov) of the cone's square (2*half_diag).
static func _letterbox_square(img: Image, half_diag: float, yfov: float, hfov: float) -> Image:
	var side := 1024
	var out := Image.create(side, side, false, Image.FORMAT_RGB8)
	out.fill(Color(0, 0, 0))
	var fx := tan(hfov * 0.5) / tan(half_diag)
	var fy := tan(yfov * 0.5) / tan(half_diag)
	var w := int(side * fx)
	var h := int(side * fy)
	var scaled := img.duplicate()
	(scaled as Image).resize(w, h, Image.INTERPOLATE_BILINEAR)
	out.blit_rect(scaled, Rect2i(0, 0, w, h), Vector2i((side - w) / 2, (side - h) / 2))
	return out
