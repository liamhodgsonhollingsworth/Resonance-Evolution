class_name PainterlySky
extends RefCounted
## The ALWAYS-ON SKY MODULE — a SEPARATE, independently-iterable wired module that gives every 3D scene
## a sky by default (Liam's 2026-07-01 spec: "3D scenes should always have a sky I can iterate on in
## parallel with the scenes and renderers"). It is deliberately its OWN module (not baked into the scene
## composition and not entangled with the painterly applier) so the sky can be tuned in parallel: its
## params live under a `sky` key in the same hot-reload JSON, and editing them re-renders ONLY the
## environment — the scene parts, the camera, and the painterly effect stack are untouched.
##
## THE MECHANISM (pure DATA in → a live Godot Sky/Environment out, the same delegate-seam discipline as
## GodotSceneRenderer): a `sky` descriptor is a renderer-neutral dict of gradient + sun + cloud knobs.
## `build(cfg)` realizes it as a Godot `Environment` whose background is a `Sky` resource backed by a
## `ProceduralSkyMaterial` — Godot's built-in analytic sky (top/horizon/ground gradient + a sun disk),
## which ALSO carries the cloud layer (see `clouds.gd`, wired through the same descriptor). No new engine
## primitive: a sky is an Environment/Sky resource the renderer host mounts, exactly like the scene tree
## the GodotSceneRenderer builds — swap the delegate (three.js), read the same descriptor.
##
## WHY ProceduralSkyMaterial and not a flat BG color: the old example used Environment.BG_COLOR (a single
## flat blue), which reads as a dead backdrop and gives the painterly pass no tonal gradient to work with.
## A procedural sky gives a real top→horizon→ground gradient + a sun the paint can catch — the sky then
## looks like a sky under the brushwork instead of a blue wall, and it is FULLY data-tunable per the spec.

## The sky descriptor's defaults — a warm daytime sky. Every key is overridable from the params JSON's
## `sky` block, so Liam iterates the sky alone (colors, sun position, energy) without touching anything
## else. Colors are [r,g,b] arrays (JSON-portable); angles are degrees.
static func default_descriptor() -> Dictionary:
	return {
		"top_color": [0.32, 0.52, 0.84],       # zenith blue
		"horizon_color": [0.80, 0.88, 0.95],   # pale horizon haze
		"ground_color": [0.55, 0.52, 0.47],    # muted earth below the horizon
		"sun_color": [1.0, 0.95, 0.84],        # warm sun tint
		"sun_angle_deg": 35.0,                  # sun elevation above the horizon
		"sun_azimuth_deg": -40.0,               # sun compass bearing (matches the scene key light)
		"sun_energy": 1.2,                      # directional light strength driven off the sky sun
		"sky_energy": 1.0,                      # overall sky brightness multiplier
		"ambient_energy": 0.7,                  # image-based ambient contribution from the sky
		"clouds": Clouds.default_descriptor(),  # the cloud layer — its OWN sub-module (clouds.gd)
	}

## Build a live Godot Environment (with a procedural Sky + a co-located sun DirectionalLight3D) from a
## `sky` descriptor. Returns { "environment": Environment, "sun": DirectionalLight3D } so the host can
## mount both. The sun light is derived FROM the sky descriptor (single source of truth for where the
## light comes from) so the lit scene and the sky sun agree — turn the sun in the JSON and both move.
static func build(desc: Dictionary) -> Dictionary:
	var d: Dictionary = desc if typeof(desc) == TYPE_DICTIONARY else {}
	var sky_mat := ProceduralSkyMaterial.new()
	sky_mat.sky_top_color = _col(d.get("top_color", [0.32, 0.52, 0.84]))
	sky_mat.sky_horizon_color = _col(d.get("horizon_color", [0.80, 0.88, 0.95]))
	sky_mat.ground_horizon_color = _col(d.get("horizon_color", [0.80, 0.88, 0.95]))
	sky_mat.ground_bottom_color = _col(d.get("ground_color", [0.55, 0.52, 0.47]))
	sky_mat.sun_angle_max = 12.0
	sky_mat.sky_energy_multiplier = float(d.get("sky_energy", 1.0))
	# The cloud layer plugs into the SAME procedural-sky material (its own module owns which knobs).
	Clouds.apply(sky_mat, d.get("clouds", {}))

	var sky := Sky.new()
	sky.sky_material = sky_mat

	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# Image-based ambient + reflections come FROM the sky, so shaded parts pick up the sky's color cast —
	# this is what makes the scene sit under the sky instead of on a flat backdrop.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	env.ambient_light_energy = float(d.get("ambient_energy", 0.7))
	env.ambient_light_sky_contribution = 1.0
	# A touch of tonemapping so the bright sky + sun don't clip to white under the paint.
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0

	# The sun as a DirectionalLight3D placed from the sky's sun angles — one source of truth for the light.
	var sun := DirectionalLight3D.new()
	sun.name = "SkySun"
	var elev := deg_to_rad(float(d.get("sun_angle_deg", 35.0)))
	var azim := deg_to_rad(float(d.get("sun_azimuth_deg", -40.0)))
	# Point the light DOWN from the sun's sky position: -elevation pitch, azimuth yaw.
	sun.rotation = Vector3(-elev, azim, 0.0)
	sun.light_color = _col(d.get("sun_color", [1.0, 0.95, 0.84]))
	sun.light_energy = float(d.get("sun_energy", 1.2))
	sun.shadow_enabled = true

	return { "environment": env, "sun": sun }

static func _col(a) -> Color:
	if a is Color:
		return a
	if typeof(a) == TYPE_ARRAY and (a as Array).size() >= 3:
		var alpha: float = float(a[3]) if (a as Array).size() >= 4 else 1.0
		return Color(float(a[0]), float(a[1]), float(a[2]), alpha)
	return Color(0.4, 0.6, 0.9, 1.0)
