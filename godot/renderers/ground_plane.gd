class_name GroundPlane
extends RefCounted
## GroundPlane -- a flat, tunable ground-plane mesh, general-purpose (not underground-scene-
## specific; ANY scene needing a flat floor plugs this in), per Liam's 2026-07-15 process-refinement
## spec (DISPATCH claim underground-railing-iteration-2026-07-15): "Make the entire world based on a
## flat plane of the ground, this will be the equatorial plane of any spheres or elliptical objects
## that exist in this scene."
##
## Formalizes what `underground_wave5_proof.gd` previously inlined as a one-off `BoxMesh` into a
## reusable node (TOP IDEAL: new node, not a scene-script one-off) -- pairs naturally with
## `RingScaffoldGenerator`'s new `ground_plane_mode` (renderers/ring_scaffold.gd, increment 3): that
## mode's upper-half-only shells already terminate EXACTLY at their own ring's `elevation` (the same
## Y this node's own `elevation` tunable should match), so the two compose with zero seam geometry.
##
## API: build_mesh(tunables: Dictionary = {}) -> Dictionary
##   {"mesh": Mesh, "position": Vector3}
## Tunables:
##   size       (float) -- plane half-extent in EACH horizontal direction (so the full plane spans
##                          `size * 2` on a side), world units. Should cover at least the outermost
##                          ring's radius + wall thickness; a caller building a ring-scaffold scene
##                          typically derives this from `RingScaffoldGenerator.build_topology()`'s
##                          own outermost radius.
##   elevation  (float) -- world Y the plane sits at (matches a ring's own `elevation` tunable).
##   thickness  (float) -- a thin BoxMesh (not an infinitely-thin PlaneMesh) so the ground reads as
##                          solid material with a visible edge/side, matching every other solid
##                          generator in this arc (bridges/cavities/dirt -- "solid, not floating
##                          plane" discipline `DirtFloorInfill`'s own wedge already documents).

const DEFAULT_SIZE := 20.0
const DEFAULT_ELEVATION := 0.0
const DEFAULT_THICKNESS := 0.1


static func build_mesh(tunables: Dictionary = {}) -> Dictionary:
	var size: float = maxf(0.1, float(tunables.get("size", DEFAULT_SIZE)))
	var elevation: float = float(tunables.get("elevation", DEFAULT_ELEVATION))
	var thickness: float = maxf(0.001, float(tunables.get("thickness", DEFAULT_THICKNESS)))

	var mesh := BoxMesh.new()
	mesh.size = Vector3(size * 2.0, thickness, size * 2.0)
	var position := Vector3(0.0, elevation - thickness * 0.5, 0.0)
	return {"mesh": mesh, "position": position}
