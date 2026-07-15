class_name PersonNodeSeam
extends RefCounted
## PersonNodeSeam -- node 13 ("Population tier") of
## notes/planning/underground_halls_plan_2026_07_14.md, Wave 5 item 5.1 (B) of
## notes/planning/scene_projects_comparison_2026_07_14.md §5 (DQ-225b57d9). "REUSE-wiring for the MVP
## default; the evolved-character mode is a real, separately-scoped gap. Silhouette default: NEW small
## wiring, 2h. Evolved-character mode: ~15h, full-spec-only" -- only the silhouette default is built
## here, per that scoping.
##
## In: `mode` (enum: `silhouette` / `evolved_character` / `real_photo_cutout`), `ring_topology`
## (RingScaffoldGenerator.build_topology()'s own output -- walkable floor placement).
## Out: `person_placements`.
##
## MODE HANDLING:
##   silhouette          -- BUILT. A flat low-detail humanoid silhouette CARD (a thin vertical box --
##                           the classic cheap "crowd card" technique, matching the plan's own
##                           "low-detail silhouettes" wording) at each placement.
##   evolved_character    -- STUB SEAM, matches PlantScatterInCavities' own CC0-asset-seam convention:
##                           `scene_node = null`, `call_target = "evolved_character:default"` -- a
##                           later ~15h pass (the FLAME-based character-creation arc, already scoped
##                           and budgeted separately, see `underground_halls_plan_2026_07_14.md` §7)
##                           resolves it. NOT built here.
##   real_photo_cutout    -- BLOCKED, NOT built, by explicit instruction. The plan's own §5 Q3 flags
##                           this as an unresolved needs-Liam PRIVACY question (real photographs of
##                           specific individuals vs. the FLAME base model) -- this module refuses to
##                           guess and returns an EMPTY placement set with `blocked: true` + a `reason`
##                           string rather than silently building something for it.
##
## WALKABLE-FLOOR-PLACEMENT INTERPRETATION (documented decision -- this node's own contract lists ONLY
## `ring_topology` as input, no wall/shell-extent params, so the placement stays self-contained against
## exactly that shape): each ring's own CENTERLINE circle (radius = `ring_data.radius`, world Y =
## `ring_data.elevation` -- the ring's own floor/corridor-centerline height) is the walkable path
## silhouettes are scattered along, evenly spaced with seeded jitter (`walk_path_seed`), facing
## tangentially (the direction a person walking that hallway would face).
##
## Every silhouette/evolved_character placement: {"ring": int, "transform": Transform3D, "mode":
## String, "call_target": String, "scene_node": Dictionary (or null for evolved_character's stub
## seam), "seed": int}.
##
## Tunables (the EXACT three named by the plan -- no more, per no-auto-generalization):
##   mode            (String enum) -- see MODE_* above.
##   density         (float 0..1) -- fraction of even-spaced candidate slots along each ring's
##                                    centerline that actually get a placement.
##   walk_path_seed  (int) -- seeds both the jitter and the density Bernoulli draw.
## (Implementation-detail defaults below -- `slot_spacing`/`height`/`width`/`jitter_fraction` --
## documented, overridable via `tunables`, same pattern every sibling module in this arc uses.)

const MODE_SILHOUETTE := "silhouette"
const MODE_EVOLVED_CHARACTER := "evolved_character"
const MODE_REAL_PHOTO_CUTOUT := "real_photo_cutout"   # BLOCKED -- see file header
const DEFAULT_MODE := MODE_SILHOUETTE

const DEFAULT_DENSITY := 0.4
const DEFAULT_WALK_PATH_SEED := 0
const DEFAULT_SLOT_SPACING := 3.0            # world units between candidate slots around a ring
const DEFAULT_HEIGHT := 1.75                 # world units, average human height
const DEFAULT_WIDTH := 0.5
const DEFAULT_JITTER_FRACTION := 0.35        # fraction of slot_spacing a placement may jitter by

const BLOCKED_REAL_PHOTO_CUTOUT_REASON := "real_photo_cutout is an unresolved needs-Liam privacy question (underground_halls_plan_2026_07_14.md §5 Q3: FLAME base model vs. literal photographs of specific individuals) -- not implemented; do not guess."


## Place people along every ring in `ring_topology`. Returns {"person_placements": Array[Dictionary],
## "blocked": bool, "reason": String} -- `blocked` is only ever true for `real_photo_cutout`.
static func place(ring_topology: Array, tunables: Dictionary = {}) -> Dictionary:
	var mode: String = String(tunables.get("mode", DEFAULT_MODE))
	if mode == MODE_REAL_PHOTO_CUTOUT:
		return {"person_placements": [], "blocked": true, "reason": BLOCKED_REAL_PHOTO_CUTOUT_REASON}
	if mode != MODE_SILHOUETTE and mode != MODE_EVOLVED_CHARACTER:
		mode = DEFAULT_MODE  # unrecognized mode string -> silhouette default, not a silent empty result

	var density: float = clampf(float(tunables.get("density", DEFAULT_DENSITY)), 0.0, 1.0)
	var walk_path_seed: int = int(tunables.get("walk_path_seed", DEFAULT_WALK_PATH_SEED))
	var slot_spacing: float = maxf(0.2, float(tunables.get("slot_spacing", DEFAULT_SLOT_SPACING)))
	var jitter_fraction: float = clampf(float(tunables.get("jitter_fraction", DEFAULT_JITTER_FRACTION)), 0.0, 1.0)

	var placements: Array = []
	if density > 0.0:
		for ring_data in ring_topology:
			placements.append_array(_place_on_ring(ring_data, mode, density, walk_path_seed,
				slot_spacing, jitter_fraction, tunables))
	return {"person_placements": placements, "blocked": false, "reason": ""}


static func _place_on_ring(ring_data: Dictionary, mode: String, density: float, walk_path_seed: int,
		slot_spacing: float, jitter_fraction: float, tunables: Dictionary) -> Array:
	var out: Array = []
	var ring: int = int(ring_data.get("ring", 0))
	var radius: float = maxf(0.0001, float(ring_data.get("radius", 1.0)))
	var elevation: float = float(ring_data.get("elevation", 0.0))
	var circumference := TAU * radius
	var slot_count: int = maxi(1, int(round(circumference / slot_spacing)))

	for slot in slot_count:
		var slot_seed := int(hash(Vector3i(walk_path_seed, ring, slot)))
		var rng := RandomNumberGenerator.new()
		rng.seed = slot_seed
		if rng.randf() >= density:
			continue
		var base_angle := TAU * float(slot) / float(slot_count)
		var jitter_angle := rng.randf_range(-1.0, 1.0) * (TAU / float(slot_count)) * jitter_fraction
		var angle := base_angle + jitter_angle
		var pos := Vector3(cos(angle) * radius, elevation, sin(angle) * radius)
		var tangent := Vector3(-sin(angle), 0.0, cos(angle))
		var xform := Transform3D(Basis.looking_at(tangent, Vector3.UP), pos)

		var call_target := "%s:default" % mode
		var scene_node = _build_silhouette_scene_node(rng, tunables) if mode == MODE_SILHOUETTE else null
		out.append({
			"ring": ring, "transform": xform, "mode": mode, "call_target": call_target,
			"scene_node": scene_node, "seed": slot_seed,
		})
	return out


## Flat low-detail humanoid silhouette "card" -- a thin vertical box, the classic cheap crowd-card
## technique, built as a renderer-neutral `mesh:{source:"primitive", shape:"box"}` scene_node so it
## composes with the SAME GodotSceneRenderer.build_static_tree() / glTF-export path every other
## primitive-sourced scene_node already uses (LSystem.to_scene_node's own convention).
static func _build_silhouette_scene_node(rng: RandomNumberGenerator, tunables: Dictionary) -> Dictionary:
	var height: float = maxf(0.2, float(tunables.get("height", DEFAULT_HEIGHT)) * rng.randf_range(0.92, 1.08))
	var width: float = maxf(0.05, float(tunables.get("width", DEFAULT_WIDTH)))
	var depth: float = width * 0.4
	return {
		"name": "person_silhouette", "translation": [0.0, height * 0.5, 0.0],
		"rotation": [0.0, 0.0, 0.0, 1.0], "scale": [1.0, 1.0, 1.0],
		"mesh": {"source": "primitive", "shape": "box", "params": {"width": width, "height": height, "depth": depth}},
		"children": [],
	}
