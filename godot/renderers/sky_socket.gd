class_name SkySocket
extends RefCounted
## SkySocket -- node 9 ("Sky / atmosphere tier") of notes/planning/brick_street_scene_plan_2026_07_14.md
## §4, Wave-A1 increment 1. A pluggable sky PORT wrapping `PainterlySky` (renderers/sky.gd) WITHOUT
## touching its internals -- `mode` is a genuinely separate branch on THIS wrapper, never a change
## inside sky.gd itself. This is the plan's own resolution of failure mode 5 / open question §7 ("is a
## new `mode` enum value on a wrapper node the right boundary, or does this need to touch sky.gd?"):
## a new file, a new class, sky.gd untouched -- satisfies the new-node-not-edit-a-primitive law.
##
## Liam's §12-13 addenda (2026-07-14, msg-thread captured in DQ-ae6870d8): the two AI-generated sky
## texture samples shown were REJECTED ("very bad, low quality and low fidelity") -- **blank white sky
## ships FIRST** (already planned), with a NODE-BASED cloud/sky generation method to be researched
## separately as a later, P3-phase mode. `mode=blank_white` is this wrapper's DEFAULT.
##
## SHADOW ANGLE (§12-13 addenda): near-overhead sun -- `sun_altitude` defaults to 82 degrees above the
## horizon (range 60-90, matching the reference image's midday-in-an-alley lighting: short, almost-
## vertical shadows, not a long raking afternoon shadow).
##
## free_params (plan §4 node 9 shape, `{type,min,max,default}`):
##   mode          {type:enum, options:[blank_white,procedural,clouds_painterly,god_rays_stack], default:blank_white}
##   sun_altitude  {type:float, min:60, max:90, default:82}
##   sun_azimuth   {type:float, min:0, max:360, default:135}
##   light_energy  {type:float, min:0.5, max:3, default:1.2}
##
## `clouds_painterly` (CloudsLayer wiring) and `god_rays_stack` (GodRaysLayer wiring) are plan-phase P3
## items (§9, nodes 10/11) -- NOT this increment's scope (no-auto-generalization discipline: build what
## the spec asks for now, defer the rest as a documented decision). An unimplemented mode degrades to
## `blank_white` with a `push_warning`, never a crash -- the same graceful-degradation shape
## `DetailField._falloff_at` uses for an unrecognized falloff curve `type`.

const MODE_BLANK_WHITE := "blank_white"
const MODE_PROCEDURAL := "procedural"
const MODE_CLOUDS_PAINTERLY := "clouds_painterly"
const MODE_GOD_RAYS_STACK := "god_rays_stack"

const DEFAULT_MODE := MODE_BLANK_WHITE
const DEFAULT_SUN_ALTITUDE := 82.0   # degrees above horizon -- "near-overhead" per the §12-13 addendum
const DEFAULT_SUN_AZIMUTH := 135.0
const DEFAULT_LIGHT_ENERGY := 1.2


## Build a live Godot Environment + sun DirectionalLight3D from a SkySocket descriptor. Returns
## `{ "environment": Environment, "sun": DirectionalLight3D }` -- the SAME shape `PainterlySky.build()`
## returns, so any caller wired against sky.gd's output mounts either module's result identically.
static func build(desc: Dictionary = {}) -> Dictionary:
	var d: Dictionary = desc if typeof(desc) == TYPE_DICTIONARY else {}
	var mode := String(d.get("mode", DEFAULT_MODE))
	match mode:
		MODE_BLANK_WHITE:
			return _build_blank_white(d)
		MODE_PROCEDURAL:
			return PainterlySky.build(d.get("sky_descriptor", PainterlySky.default_descriptor()))
		MODE_CLOUDS_PAINTERLY, MODE_GOD_RAYS_STACK:
			push_warning("SkySocket: mode '%s' is P3-phase (plan §9, not built this increment) -- falling back to blank_white" % mode)
			return _build_blank_white(d)
		_:
			push_warning("SkySocket: unknown mode '%s' -- falling back to blank_white" % mode)
			return _build_blank_white(d)


## The blank-white sky: a flat white background (`Environment.BG_COLOR`, per Liam's explicit
## rejection of the AI-generated sky-texture samples) + a near-overhead `DirectionalLight3D` so
## bricks/window reveals cast the short, almost-vertical shadows a midday overhead sun produces --
## matching the reference image's own lighting.
static func _build_blank_white(d: Dictionary) -> Dictionary:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(1.0, 1.0, 1.0)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(1.0, 1.0, 1.0)
	env.ambient_light_energy = 0.9
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.tonemap_exposure = 1.0

	var altitude := clampf(float(d.get("sun_altitude", DEFAULT_SUN_ALTITUDE)), 60.0, 90.0)
	var azimuth := fmod(float(d.get("sun_azimuth", DEFAULT_SUN_AZIMUTH)), 360.0)
	var energy: float = maxf(0.0, float(d.get("light_energy", DEFAULT_LIGHT_ENERGY)))

	var sun := DirectionalLight3D.new()
	sun.name = "SkySocketSun"
	# A DirectionalLight3D shines along its local -Z; pitching it down by `altitude` degrees from
	# horizontal (rotation.x = -altitude in radians) points it near-straight-down as altitude -> 90,
	# the same elevation/azimuth -> rotation convention sky.gd's own sun derivation uses, so a scene
	# composing both sky modules agrees on what "sun angle" means.
	sun.rotation = Vector3(-deg_to_rad(altitude), deg_to_rad(azimuth), 0.0)
	sun.light_color = Color(1.0, 1.0, 1.0)
	sun.light_energy = energy
	sun.shadow_enabled = true

	return {"environment": env, "sun": sun}


## True altitude (degrees above horizon) a built `sun` light's rotation encodes -- lets a test or a
## proof driver verify "near-overhead" without re-deriving the rotation math independently.
static func altitude_of(sun: DirectionalLight3D) -> float:
	return rad_to_deg(-sun.rotation.x)
