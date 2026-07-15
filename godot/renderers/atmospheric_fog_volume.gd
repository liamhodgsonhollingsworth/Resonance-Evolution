class_name AtmosphericFogVolume
extends RefCounted
## AtmosphericFogVolume -- Wave 4 item 4.1 (C) of DQ-60f088f7 (notes/planning/
## scene_projects_comparison_2026_07_14.md §5's Wave 4, atmosphere tier of Project B's
## underground-halls scene; the plan's own node name is "FogVolume" -- named `AtmosphericFogVolume`
## HERE ONLY because Godot 4.6 already ships a native engine class literally called `FogVolume`
## (a Node3D + FogMaterial local volumetric-fog box); `class_name FogVolume` silently shadowed by
## the native type and every static call resolved to "not found in base GDScriptNativeClass" --
## caught by this module's own headless test suite. Liam's spec: fog/mist ACCUMULATING OVER
## DISTANCE, tunable. A thin wrap over Godot's built-in Environment distance fog
## (`fog_enabled`/`fog_density`/`fog_light_color`, Godot 4.6) -- the SAME two-piece
## build()+apply_environment() convention ReflectiveFloorMaterial
## (renderers/reflective_floor_material.gd) established, since fog lives on the scene's
## `Environment` resource, not on any mesh material.
##
## Tunables (the two headline ones Liam named -- density/color -- plus documented implementation-
## detail extras, the SAME "overridable, never silently hardcoded" pattern reflective_floor_material.gd
## / procedural_rock_texture.gd use beyond their own headline tunables):
##   density (float 0..1)  -- `fog_density`; how quickly distance fog accumulates ("accumulating over
##                            distance").
##   color   (Color)       -- `fog_light_color`; the mist's own tint.
##   height / height_density (float) -- optional height-based falloff (`fog_height`/
##                            `fog_height_density`) -- fog thicker low, thinner near the glowing roof;
##                            composes naturally with RoofGlowCutoff's own elevation cutoff. 0
##                            height_density = disabled (uniform density), Environment's own default.
##   sun_scatter (float 0..1) -- `fog_sun_scatter`; how much the fog catches directional-light
##                            scattering (a visible "shaft" cue near a bright light).
##   volumetric_enabled (bool) / volumetric_density (float) -- opt-in real participating-media fog
##                            (`Environment.volumetric_fog_*`) for scenes that can afford it; distance
##                            fog ALONE (the default) is the cheap, always-on "mist accumulating over
##                            distance" Liam asked for.

const DEFAULT_DENSITY := 0.045
# Warm-grey mist: reads WITH the amber-cube palette rather than fighting it (a cold blue mist would
# clash against the amber-glow aesthetic Liam named as the composing element of the whole image).
const DEFAULT_COLOR := Color(0.55, 0.5, 0.42)
const DEFAULT_LIGHT_ENERGY := 1.0
const DEFAULT_SUN_SCATTER := 0.15
const DEFAULT_HEIGHT := -2.0
const DEFAULT_HEIGHT_DENSITY := 0.0
const DEFAULT_VOLUMETRIC_ENABLED := false
const DEFAULT_VOLUMETRIC_DENSITY := 0.03


## Build the ENVIRONMENT patch ("fog_descriptor") -- what `apply_environment` below writes onto a
## scene's `Environment` resource. Returns a plain data patch (not applied yet), matching this
## codebase's descriptor-then-apply convention (reflective_floor_material.gd's own
## `build_environment_patch`).
static func build_environment_patch(tunables: Dictionary = {}) -> Dictionary:
	var patch := {
		"fog_enabled": true,
		"fog_density": clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0),
		"fog_light_color": Color(tunables.get("color", DEFAULT_COLOR)),
		"fog_light_energy": maxf(0.0, float(tunables.get("light_energy", DEFAULT_LIGHT_ENERGY))),
		"fog_sun_scatter": clampf(float(tunables.get("sun_scatter", DEFAULT_SUN_SCATTER)), 0.0, 1.0),
		"fog_height": float(tunables.get("height", DEFAULT_HEIGHT)),
		"fog_height_density": float(tunables.get("height_density", DEFAULT_HEIGHT_DENSITY)),
	}
	var volumetric_enabled: bool = bool(tunables.get("volumetric_enabled", DEFAULT_VOLUMETRIC_ENABLED))
	patch["volumetric_fog_enabled"] = volumetric_enabled
	if volumetric_enabled:
		patch["volumetric_fog_density"] = clampf(
			float(tunables.get("volumetric_density", DEFAULT_VOLUMETRIC_DENSITY)), 0.0, 1.0)
		patch["volumetric_fog_albedo"] = Color(tunables.get("color", DEFAULT_COLOR))
	return patch


## Apply a `build_environment_patch()` dict onto a real `Environment` resource -- the one call a
## scene driver makes against its WorldEnvironment. Matches reflective_floor_material.gd's own
## `apply_environment`: null-safe, only touches fields present in `patch`.
static func apply_environment(env: Environment, patch: Dictionary) -> void:
	if env == null:
		return
	if patch.has("fog_enabled"):
		env.fog_enabled = bool(patch["fog_enabled"])
	if patch.has("fog_density"):
		env.fog_density = float(patch["fog_density"])
	if patch.has("fog_light_color"):
		env.fog_light_color = patch["fog_light_color"]
	if patch.has("fog_light_energy"):
		env.fog_light_energy = float(patch["fog_light_energy"])
	if patch.has("fog_sun_scatter"):
		env.fog_sun_scatter = float(patch["fog_sun_scatter"])
	if patch.has("fog_height"):
		env.fog_height = float(patch["fog_height"])
	if patch.has("fog_height_density"):
		env.fog_height_density = float(patch["fog_height_density"])
	if patch.has("volumetric_fog_enabled"):
		env.volumetric_fog_enabled = bool(patch["volumetric_fog_enabled"])
	if patch.has("volumetric_fog_density"):
		env.volumetric_fog_density = float(patch["volumetric_fog_density"])
	if patch.has("volumetric_fog_albedo"):
		env.volumetric_fog_albedo = patch["volumetric_fog_albedo"]


## Top-level convenience matching this wave's other nodes' `build()` shape: returns
## {"environment_patch": Dictionary} -- the fog_descriptor's single Out port.
static func build(tunables: Dictionary = {}) -> Dictionary:
	return {"environment_patch": build_environment_patch(tunables)}
