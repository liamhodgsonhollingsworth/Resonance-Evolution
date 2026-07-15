class_name ReflectiveFloorMaterial
extends RefCounted
## ReflectiveFloorMaterial -- node 4 ("Texture / material tier") of
## notes/planning/underground_halls_plan_2026_07_14.md §4, Wave 3 item 3.2 of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-2e1202ca). A thin engine-feature
## wrap: "solid color of gloss ... reflective" (Liam's spec) via a low-roughness/high-specular
## StandardMaterial3D plus Godot's built-in screen-space reflections (`Environment.ssr_enabled`,
## confirmed present on this engine build, Godot 4.6) -- zero new render code, per plan §2.3's
## cheapest-first escalation ladder (SSR first; planar-mirror-camera / a bespoke fresnel shader only
## if SSR shows visible artifact at floor-level grazing angles, which is NOT built here).
##
## NEW leaf material node -- no inputs (plan §4 node 4: "In: none"). Unlike ProceduralRockTexture,
## a reflective floor is TWO pieces of state that must travel together: the MATERIAL (on the floor
## mesh) and an ENVIRONMENT patch (`ssr_enabled` etc. live on the scene's `Environment` resource,
## not on any one material) -- so `build()` returns both, and `apply_environment()` is the one call
## a scene driver makes once per WorldEnvironment to wire the second half in.
##
## Tunables (plan §4 node 4, the EXACT three named):
##   base_color      (Color) -- solid floor color (no texture -- "solid color of gloss").
##   gloss/roughness (float 0..1, LOW default = glossy) -- exposed as `gloss` (plan's own name);
##                    `roughness = 1.0 - gloss` internally (StandardMaterial3D's own axis is
##                    roughness, so gloss=1.0 -> roughness=0.0, mirror-sharp).
##   reflection_mode (enum: "ssr" | "planar" | "cheap_fresnel", default "ssr").

const MODE_SSR := "ssr"
const MODE_PLANAR := "planar"
const MODE_CHEAP_FRESNEL := "cheap_fresnel"
const MODES := [MODE_SSR, MODE_PLANAR, MODE_CHEAP_FRESNEL]

const DEFAULT_BASE_COLOR := Color(0.09, 0.10, 0.13)  # dark solid gloss, reads "wet stone/polished
                                                      # floor" against the reference image
const DEFAULT_GLOSS := 0.85                          # high gloss = low roughness, per plan default
const DEFAULT_REFLECTION_MODE := MODE_SSR

# SSR implementation-detail defaults (plan §2.3 names SSR as the mechanism but not its own tunable
# knobs beyond "ray steps / resolution scale if it gets expensive" -- documented decisions,
# overridable via `tunables`, same pattern as this wave's other new nodes).
const DEFAULT_SSR_MAX_STEPS := 64
const DEFAULT_SSR_FADE_IN := 0.15
const DEFAULT_SSR_FADE_OUT := 2.0
const DEFAULT_SSR_DEPTH_TOLERANCE := 0.2


## Build the floor's StandardMaterial3D ("floor_material_descriptor"'s material half). Reflectivity
## comes from LOW roughness (sharp specular highlight + what SSR/probes need to produce a crisp
## reflection) -- metallic stays 0 (a glossy dielectric floor, not a chrome/metal one, matching
## "solid color of gloss" rather than a mirror-metal read).
##   ssr / planar          -> roughness driven straight by `gloss` (planar is the same material;
##                             only the reflection MECHANISM differs, which lives in the environment
##                             patch / a future dedicated mirror-camera, not the material).
##   cheap_fresnel         -> additionally raises `specular`/relies on the engine's free ambient/sky
##                             + ReflectionProbe pipeline (no SSR ray march needed at all) -- the
##                             actual "static env-map fake" analog on the Godot side.
static func build_material(tunables: Dictionary = {}) -> StandardMaterial3D:
	var base_color: Color = tunables.get("base_color", DEFAULT_BASE_COLOR)
	# `gloss` is the plan's own named tunable; `roughness` (its StandardMaterial3D-native inverse)
	# is accepted too so a caller thinking in either axis works -- `gloss` wins if both are given.
	var gloss: float = DEFAULT_GLOSS
	if tunables.has("gloss"):
		gloss = clampf(float(tunables["gloss"]), 0.0, 1.0)
	elif tunables.has("roughness"):
		gloss = clampf(1.0 - float(tunables["roughness"]), 0.0, 1.0)
	var mode := _resolve_mode(tunables)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = base_color
	mat.roughness = clampf(1.0 - gloss, 0.0, 1.0)
	mat.metallic = 0.0
	mat.specular_mode = BaseMaterial3D.SPECULAR_SCHLICK_GGX
	if mode == MODE_CHEAP_FRESNEL:
		# No SSR ray march at all -- lean on the engine's free ambient/sky + ReflectionProbe
		# pipeline for the reflective read, with a rim-boost so grazing angles read more reflective
		# (the "fresnel" cue), matching the plan's "static env-map fake" analog for a cheap escalation
		# rung below full SSR cost.
		mat.rim_enabled = true
		mat.rim = 0.6
		mat.rim_tint = 0.35
	return mat


## Build the ENVIRONMENT half ("floor_material_descriptor"'s other half) -- what `apply_environment`
## below writes onto a scene's `Environment` resource. Returns a plain data patch (not applied yet)
## so a caller can inspect/log it before touching the live Environment, matching this codebase's
## descriptor-then-apply convention (e.g. cavity_carver.gd's sdf_edits list vs. a later sculpt pass).
static func build_environment_patch(tunables: Dictionary = {}) -> Dictionary:
	var mode := _resolve_mode(tunables)
	if mode == MODE_PLANAR:
		# A true second-camera planar-mirror render is the plan's own named escalation rung (§2.3)
		# -- explicitly NOT built in this thin-wrap node (out of this item's 3h budget; "escalate
		# only if grazing-angle artifacts appear" on the cheaper SSR path). Falls back to the SSR
		# patch so `planar` still produces a real, visibly-reflective floor today rather than a
		# silent no-op; the fallback is logged, not hidden.
		push_warning("ReflectiveFloorMaterial: reflection_mode 'planar' is not yet implemented (plan §2.3 escalation rung) -- falling back to 'ssr'")
		mode = MODE_SSR
	if mode == MODE_CHEAP_FRESNEL:
		return { "ssr_enabled": false }
	return {
		"ssr_enabled": true,
		"ssr_max_steps": int(tunables.get("ssr_max_steps", DEFAULT_SSR_MAX_STEPS)),
		"ssr_fade_in": float(tunables.get("ssr_fade_in", DEFAULT_SSR_FADE_IN)),
		"ssr_fade_out": float(tunables.get("ssr_fade_out", DEFAULT_SSR_FADE_OUT)),
		"ssr_depth_tolerance": float(tunables.get("ssr_depth_tolerance", DEFAULT_SSR_DEPTH_TOLERANCE)),
	}


## Apply a `build_environment_patch()` dict onto a real `Environment` resource -- the one call a
## scene driver makes against its WorldEnvironment. No-op fields are simply absent from `patch`
## (`cheap_fresnel`'s patch only ever sets `ssr_enabled = false`, leaving every other SSR property
## at the Environment's existing value).
static func apply_environment(env: Environment, patch: Dictionary) -> void:
	if env == null:
		return
	if patch.has("ssr_enabled"):
		env.ssr_enabled = bool(patch["ssr_enabled"])
	if patch.has("ssr_max_steps"):
		env.ssr_max_steps = int(patch["ssr_max_steps"])
	if patch.has("ssr_fade_in"):
		env.ssr_fade_in = float(patch["ssr_fade_in"])
	if patch.has("ssr_fade_out"):
		env.ssr_fade_out = float(patch["ssr_fade_out"])
	if patch.has("ssr_depth_tolerance"):
		env.ssr_depth_tolerance = float(patch["ssr_depth_tolerance"])


## Top-level convenience matching this wave's other nodes' `build()` shape: returns
## {"material": StandardMaterial3D, "environment_patch": Dictionary} -- the full
## "floor_material_descriptor" the plan names as node 4's single Out port.
static func build(tunables: Dictionary = {}) -> Dictionary:
	return {
		"material": build_material(tunables),
		"environment_patch": build_environment_patch(tunables),
	}


static func _resolve_mode(tunables: Dictionary) -> String:
	var mode := String(tunables.get("reflection_mode", DEFAULT_REFLECTION_MODE))
	if not MODES.has(mode):
		push_warning("ReflectiveFloorMaterial: unknown reflection_mode '%s', falling back to '%s'" % [mode, DEFAULT_REFLECTION_MODE])
		mode = DEFAULT_REFLECTION_MODE
	return mode
