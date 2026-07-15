class_name RoofGlowCutoff
extends RefCounted
## RoofGlowCutoff -- Wave 4 item 4.1 (B) of DQ-60f088f7 (notes/planning/
## scene_projects_comparison_2026_07_14.md §5's Wave 4, roof tier of Project B's underground-halls
## scene). Liam's spec: cavities/surfaces above a tunable elevation show a bright white glowing
## surface -- read as light spilling from a roof opening / a luminous ceiling, not a flat dark
## ceiling like the rest of the shell. AESTHETIC-CRITICAL alongside AmberLightCubeScatterer (both are
## the two things Liam named as composing "the whole vibe of the image").
##
## TWO composition modes, both built off the SAME cutoff math:
##   build_material() / from_wall_material() -- a FULL-REPLACEMENT spatial ShaderMaterial (base
##     color/texture below the cutoff, glow above it). Simple, one material, but a caller supplying
##     `base_texture` gets a RAW UV sample (no tiling/triplanar) -- see that function's own note.
##   build_overlay_material() / apply_as_overlay() -- an ADDITIVE-BLEND, UNSHADED `next_pass` overlay
##     (RECOMMENDED composition path): stack it on top of an EXISTING material (e.g.
##     ProceduralRockTexture.build_material()'s output) via `BaseMaterial3D.next_pass` -- the base
##     material renders completely unchanged (real rock texture, real tiling, real lighting) and the
##     overlay pass ADDS pure glow_color*glow_energy on top, ramped by the SAME cutoff/blend_softness
##     math, contributing exactly (0,0,0) below the cutoff (a true no-op, not just visually dark) so
##     it never fights the base material's own look.
## Either way: below `cutoff_elevation` the surface reads as the base material; above it -- across a
## soft `blend_softness` world-unit band, never a hard seam -- it reads as `glow_color` at
## `glow_energy`. Godot is Y-up, so "elevation" is world-space Y in meters, matching
## RingScaffoldGenerator's own per-ring `elevation` convention (renderers/ring_scaffold.gd).
##
## SHADER + GDSCRIPT TWIN, same math, so they cannot drift (the same discipline
## effect_stack_gpu.gd's GLSL-generator + emulate() pair uses, lighter-weight here: one clearly
## labelled `blend_factor()` mirrors the shader fragment's own cutoff formula exactly, both headless-
## testable and reusable by a future CPU-side render/analysis pass without spinning up a GPU).
##
## Tunables (the EXACT ones named -- no more, per no-auto-generalization):
##   cutoff_elevation (float) -- world Y above which the glow appears.
##   glow_color        (Color)-- the bright glow color (default near-white).
##   glow_energy        (float)-- emission strength at full glow.
##   blend_softness      (float)-- vertical world-unit distance the transition ramps across (0 = a
##                                 hard cutoff edge).
##   base_color / base_roughness -- the material's appearance BELOW the cutoff (a flat tone; pass
##                                 `base_texture` too for a textured base, or use
##                                 `from_wall_material()` to lift base_color/base_roughness straight
##                                 off an existing StandardMaterial3D).

const DEFAULT_CUTOFF_ELEVATION := 2.4
const DEFAULT_GLOW_COLOR := Color(0.96, 0.97, 1.0)
const DEFAULT_GLOW_ENERGY := 3.5
const DEFAULT_BLEND_SOFTNESS := 0.6
const DEFAULT_BASE_COLOR := Color(0.5, 0.46, 0.4)
const DEFAULT_BASE_ROUGHNESS := 0.85


## The fragment-shader cutoff math, duplicated here in pure GDScript so it is headless-testable
## without a GPU AND reusable by a future CPU-side pass (e.g. a render-quality analysis step) --
## MUST be kept byte-identical to the GLSL in `build_shader_code()`'s `fragment()` body; a change to
## one without the other is a drift bug, not a style choice.
static func blend_factor(world_y: float, cutoff_elevation: float, blend_softness: float) -> float:
	var softness: float = maxf(0.0001, blend_softness)
	return clampf((world_y - cutoff_elevation) / softness, 0.0, 1.0)


static func build_shader_code() -> String:
	return """shader_type spatial;

uniform vec4 base_color : source_color = vec4(0.5, 0.46, 0.4, 1.0);
uniform sampler2D base_texture : source_color;
uniform bool use_base_texture = false;
uniform float base_roughness : hint_range(0.0, 1.0) = 0.85;
uniform vec4 glow_color : source_color = vec4(0.96, 0.97, 1.0, 1.0);
uniform float glow_energy = 3.5;
uniform float cutoff_elevation = 2.4;
uniform float blend_softness = 0.6;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	vec4 base = base_color;
	if (use_base_texture) {
		base = texture(base_texture, UV) * base_color;
	}
	float t = clamp((world_y - cutoff_elevation) / max(blend_softness, 0.0001), 0.0, 1.0);
	ALBEDO = mix(base.rgb, glow_color.rgb, t);
	ROUGHNESS = mix(base_roughness, 0.25, t);
	EMISSION = glow_color.rgb * glow_energy * t;
}
"""


## Build the ready-to-use ShaderMaterial ("roof_glow_material_descriptor").
static func build_material(tunables: Dictionary = {}) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = build_shader_code()
	mat.shader = shader

	mat.set_shader_parameter("base_color", Color(tunables.get("base_color", DEFAULT_BASE_COLOR)))
	mat.set_shader_parameter("base_roughness",
		clampf(float(tunables.get("base_roughness", DEFAULT_BASE_ROUGHNESS)), 0.0, 1.0))
	if tunables.get("base_texture") is Texture2D:
		mat.set_shader_parameter("base_texture", tunables["base_texture"])
		mat.set_shader_parameter("use_base_texture", true)
	else:
		mat.set_shader_parameter("use_base_texture", false)
	mat.set_shader_parameter("glow_color", Color(tunables.get("glow_color", DEFAULT_GLOW_COLOR)))
	mat.set_shader_parameter("glow_energy", maxf(0.0, float(tunables.get("glow_energy", DEFAULT_GLOW_ENERGY))))
	mat.set_shader_parameter("cutoff_elevation", float(tunables.get("cutoff_elevation", DEFAULT_CUTOFF_ELEVATION)))
	mat.set_shader_parameter("blend_softness",
		maxf(0.0001, float(tunables.get("blend_softness", DEFAULT_BLEND_SOFTNESS))))
	return mat


## Convenience: lift `base_color`/`base_roughness` straight off an existing StandardMaterial3D (e.g.
## ProceduralRockTexture.build_material()'s output) so a caller need not restate them. The albedo
## TEXTURE itself is intentionally not sampled through -- StandardMaterial3D's own texture-sampling
## model (triplanar/uv1_scale tiling, see procedural_rock_texture.gd) differs enough from a raw
## sampler2D fetch that faithfully replicating it here would duplicate that module's own tiling math;
## pass `base_texture` explicitly via `tunables` if a caller wants the roof glow to blend from a real
## texture rather than a flat tone.
static func from_wall_material(base: StandardMaterial3D, tunables: Dictionary = {}) -> ShaderMaterial:
	var t := tunables.duplicate()
	if base != null:
		t["base_color"] = base.albedo_color
		t["base_roughness"] = base.roughness
	return build_material(t)


# ── Additive `next_pass` overlay (recommended composition path) ───────────────────────────────────

## The overlay shader source: UNSHADED + `blend_add`, so the fragment's own output color IS the exact
## additive contribution (no lighting response, no base-color mixing) -- at t=0 (below the cutoff)
## this emits pure (0,0,0), a true no-op regardless of the base material underneath.
static func build_overlay_shader_code() -> String:
	return """shader_type spatial;
render_mode blend_add, unshaded, cull_back;

uniform vec4 glow_color : source_color = vec4(0.96, 0.97, 1.0, 1.0);
uniform float glow_energy = 3.5;
uniform float cutoff_elevation = 2.4;
uniform float blend_softness = 0.6;

varying float world_y;

void vertex() {
	world_y = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	float t = clamp((world_y - cutoff_elevation) / max(blend_softness, 0.0001), 0.0, 1.0);
	ALBEDO = glow_color.rgb * glow_energy * t;
	ALPHA = t;
}
"""


## Build the standalone overlay ShaderMaterial (for a caller that wants to manage `next_pass` chaining
## itself, e.g. onto a Material this module doesn't own).
static func build_overlay_material(tunables: Dictionary = {}) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = build_overlay_shader_code()
	mat.shader = shader
	mat.set_shader_parameter("glow_color", Color(tunables.get("glow_color", DEFAULT_GLOW_COLOR)))
	mat.set_shader_parameter("glow_energy", maxf(0.0, float(tunables.get("glow_energy", DEFAULT_GLOW_ENERGY))))
	mat.set_shader_parameter("cutoff_elevation", float(tunables.get("cutoff_elevation", DEFAULT_CUTOFF_ELEVATION)))
	mat.set_shader_parameter("blend_softness",
		maxf(0.0001, float(tunables.get("blend_softness", DEFAULT_BLEND_SOFTNESS))))
	return mat


## RECOMMENDED entry point: stack the glow overlay onto an EXISTING material via `next_pass` and
## return that same material (chaining convenience -- `mat = RoofGlowCutoff.apply_as_overlay(mat,
## tunables)`). The base material (e.g. ProceduralRockTexture.build_material()'s output) is left
## otherwise completely untouched -- its own texture/tiling/lighting render exactly as before; the
## overlay pass only ever ADDS glow on top.
static func apply_as_overlay(base_material: BaseMaterial3D, tunables: Dictionary = {}) -> BaseMaterial3D:
	if base_material != null:
		base_material.next_pass = build_overlay_material(tunables)
	return base_material
