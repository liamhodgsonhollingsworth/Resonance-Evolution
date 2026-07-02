# Stereogram + VR viewer — one viewing-geometry parameter set, many stereo output modes

2026-07-02 · research + foundational build (stereogram-vr-viewer lane) ·
diagram: [stereogram_geometry_2026-07-02.svg](stereogram_geometry_2026-07-02.svg) ·
prototype: `godot/primitives/prim_stereo_render.gd` (`StereoRender`) + `godot/renderers/stereo_rig.gd` (`StereoRig`) ·
test: `godot/headless_stereo_test.gd`

## The idea

Every stereo display trick — autostereograms, side-by-side pairs, anaglyphs, VR — is the *same*
geometry: two eyes at a known separation, a display surface at a known distance, and a scene whose
depths must be turned into **on-screen parallax**. So the design centers ONE renderer-neutral
**viewing-geometry parameter set** (plain dict, node-wireable DATA, per the everything-is-data
convention) and derives every output mode from it. Change `ipd_m` or `screen_distance_m` once and
the stereogram period, the pair disparity, the anaglyph offset, and the VR camera rig all move
together — because they are the same numbers.

## The geometry parameter set (all DATA)

Carried as a plain dictionary — in `StereoRender` params, on a `geometry` wire (e.g. from a
`Const`), or handed to `StereoRig`. Canonical space: viewer-centred view space, cyclopean eye at
the origin, looking down **−Z**, +Y up, +X right, meters (glTF-aligned, same as `View`).

| key | default | meaning |
|---|---|---|
| `screen_distance_m` | 0.6 | viewer-to-screen distance **D** (the screen IS the zero-parallax / convergence / focal plane) |
| `ipd_m` | 0.063 | eye separation **e** (interpupillary distance; adult mean ≈ 63 mm) |
| `screen_width_m` | 0.52 | physical width of the displayed image **W_m** |
| `image_width_px` / `image_height_px` | 960 / 600 | output raster size; **ppm** = `image_width_px / screen_width_m` (pixels per meter, the DPI seam); screen height H_m = `image_height_px / ppm` |
| `viewing` | `"cross"` | free-viewing mode: `"parallel"` (wall-eyed; fused image floats *behind* the screen) or `"cross"` (cross-eyed; floats *in front*) |
| `display_near_m` / `display_far_m` | 0.40 / 0.54 | the **depth budget**: the interval of viewer-distances the displayed scene occupies. Must sit in front of the screen for `"cross"`, behind it for `"parallel"` |
| `scene_near_m` / `scene_far_m` | auto | which scene-depth range remaps onto the budget (auto = min/max of the rendered depth map) |
| `znear_m` / `zfar_m` | 0.05 / 100 | clip planes for the camera rig |

Derived (echoed by `StereoRender.derive()` so downstream nodes can read them):
`ppm`, `screen_height_m`, `sep_near_px`, `sep_far_px`, `valid` + `errors`.

## The core math (derived once, reused by every mode)

**Screen parallax.** A scene point at viewer-distance Z projects through the two eyes onto the
screen plane at two x positions. By similar triangles (see the diagram):

```
x_L = −e/2 + (X + e/2)·D/Z          x_R = +e/2 + (X − e/2)·D/Z
parallax  p(Z) = x_R − x_L = e·(Z − D)/Z          [meters, signed]
```

- `Z = D` → `p = 0` — the screen is the convergence/focal plane; zero disparity there.
- `Z > D` (behind screen) → `p > 0` (**uncrossed**), bounded above by `e` as Z→∞ (eyes parallel;
  never exceed it or the eyes must diverge).
- `Z < D` (in front) → `p < 0` (**crossed**), magnitude grows without bound as Z→0.

**Autostereogram period.** Two dots on the screen separated by `s` fuse into one perceived point:
wall-eyed at `Z = e·D/(e−s)` behind the screen, cross-eyed at `Z = e·D/(e+s)` in front. Inverting:

```
parallel:  s(Z) = e·(Z − D)/Z      (needs D < display_near ≤ Z;  far ⇒ larger period)
cross:     s(Z) = e·(D − Z)/Z      (needs Z ≤ display_far < D;   near ⇒ larger period)
in pixels: s_px(Z) = ppm · s(Z)
```

Same function, same parameters — only the side of the screen the depth budget lives on changes.

**Stereo-pair disparity.** With both eye images sharing the physical screen window (off-axis
frusta, below), a point at depth Z lands at pixel columns whose difference is

```
d(Z) = u_L − u_R = ppm · e · (D − Z)/Z        [pixels, signed]
```

positive (left-image position is to the right → crossed) for near points, `0` at the focal plane,
negative (uncrossed) behind it. This is the decoder-testable quantity.

**Depth mapping.** Depth-map values `v ∈ [0,1]` (1 = near) map to display distance **linearly in
1/Z** (i.e. linearly in disparity — uniform perceptual/disparity quantization, the same choice VR
reprojection buffers make):

```
1/Z(v) = 1/display_far + v · (1/display_near − 1/display_far)
```

Scene depths remap onto the budget first: `v = clamp((1/Z_scene − 1/scene_far) / (1/scene_near −
1/scene_far))`. The budget is deliberately a REMAP — the scene can be any size; the *display*
depth interval is what comfort constrains.

**Depth budget / comfort.** The comfort quantities are all derivable from the same params:
- never let `p(Z) ≥ e` (divergence — impossible to fuse); the parallel formula enforces this
  structurally (`s < e` for all finite Z).
- vergence–accommodation comfort: keep the vergence change `δ(Z) = 2·[atan(e/2D) − atan(e/2Z)]`
  within roughly ±1° for casual viewing (the classic "percent rule" — parallax under ~2–3% of
  viewing distance). With the defaults, the whole cross budget [0.40, 0.54] m spans δ ≈ 2.2° —
  fine for a deliberate free-viewing stereogram, generous for passive content; tighten the budget
  for comfort-critical use. These are guidance numbers surfaced by `derive()`, not hard clamps.

## One parameter set → four output modes

### (a) Autostereogram (SIRDS / wallpaper)

CPU, classic single-image random-dot algorithm, per row left-to-right:

```
s = round(s_px(Z(v[x,y])))
img[x] = (x ≥ s) ? img[x − s] : pattern[x mod strip_w, y]
```

The repeating constraint IS the depth encoding: a region at depth Z repeats with period `s_px(Z)`
exactly, which is what the decoder test measures back (autocorrelation: the smallest offset with
~100% row self-match equals the predicted period). The pattern strip is seeded random RGB
(`pattern.seed`), width `pattern.strip_px` (default: the max period in the budget). Known
limitation of the simple back-reference form: no hidden-surface handling — depth step edges leave
faint "echo" artifacts (the Thimbleby–Inglis–Witten symmetric algorithm with hidden-surface
removal is the documented follow-up; the geometry function does not change). A `"wallpaper"` mode
(tileable image strip instead of random dots) is the same seam: only `pattern` changes.

### (b) Side-by-side stereo pair (cross + parallel)

Two CPU pinhole renders from `(±e/2, 0, 0)` through the **same physical screen window** (an
off-axis / asymmetric frustum each — never toe-in, which adds vertical parallax + keystone). The
disparity of any feature between the two images is `d(Z)` above, geometry-exact from the same
params. `pair_layout: "cross"` swaps the images (left eye's view on the right) so crossing your
eyes fuses it; `"parallel"` keeps L|R for wall-eyed viewing or a phone-in-cardboard.

### (c) Anaglyph (cheap verification mode)

Channel compose of the same two eye renders: `R ← left.r`, `G,B ← right.g,b`. Zero new geometry —
it exists as the always-available physical check (any red/cyan glasses) and as the exact-equality
unit test (channels must match their source renders pixel-for-pixel).

### (d) VR viewer (the OpenXR seam — same params, live cameras)

`StereoRig` (`godot/renderers/stereo_rig.gd`) turns the SAME geometry dict into live camera data:
two `Camera3D`s at `(±e/2, 0, 0)` in `PROJECTION_FRUSTUM` mode with

```
size            = screen_height_m · znear_m / D          (near-plane height)
frustum_offset  = (∓ e/2 · znear_m / D, 0)               (off-axis shift toward the shared window)
```

so both frusta converge exactly on the screen window at distance D — the identical projection the
CPU pair renderer used, now on the GPU for a live windowed side-by-side preview (two
`SubViewport`s side by side is the intended host wiring). The seam to a real headset:

- **OpenXR supplies per-eye transforms + projection matrices itself** (measured hardware IPD, per-eye
  FOV) via `XROrigin3D`/`XRCamera3D` — you do NOT force `ipd_m` onto a headset. The geometry dict
  maps onto XR as: `ipd_m / hardware_ipd → XROrigin3D.world_scale` (deliberate hyper/hypo-stereo =
  scale illusion), `screen_distance_m` + `screen_width_m` → the virtual screen quad you place in
  the world when showing flat stereo content (the stereogram itself is viewable *in* VR by
  texturing that quad at distance D — the free-viewing geometry then physically matches the
  generator's params), `znear_m/zfar_m` → camera clips.
- Actual headset bring-up (OpenXR init, controller input) is explicitly out of scope here; the
  contract is that `StereoRig.eye_descriptors(geo)` is the single function both the preview rig
  and a future XR adapter read, so no output mode ever grows private geometry.

## Node wiring (everything configurable as data)

```
Const(scene_node sphere/box …) ─┬─▶ Group ─▶ StereoRender ─▶ stereo (descriptor: paths + derived geometry)
Const(geometry dict, optional) ─┴──────────────▲
```

`StereoRender` inputs: `scene` (a renderer-neutral `scene_node` tree — the same descriptors
`Model`/`Transform`/`Group`/`PartsCatalog` already emit), `geometry` (optional dict wire that
overrides params — so a slider node can drive IPD live). Params: `geometry{…}`, `pattern{seed,
strip_px}`, `outputs[depth|stereogram|pair|anaglyph]`, `out_dir`, `basename`, `pair_layout`.
Output `stereo`: a JSON-serializable descriptor (written PNG paths + derived geometry + depth
stats) — no `Image` on any wire (portability invariant, same as `Render2D`).

The CPU depth renderer intentionally supports the **analytic subset** of the primitive-mesh
vocabulary — `sphere` + `box` (any TRS for boxes; uniform scale for spheres) — because the proof
needs exact expected depths. GLB meshes and the other 11 catalog shapes are skipped with a count
in the descriptor (`skipped_nodes`). The follow-up that lifts this restriction is a depth-buffer
readback from the GPU renderer delegate (then ANY scene the engine renders feeds the same
stereogram math unchanged); the geometry functions already take a plain depth map, so it is a
source swap, not a redesign.

## Verification model (headless, deterministic — the proof the geometry is right)

`godot --headless --path godot -s res://headless_stereo_test.gd` decodes its own outputs:

1. **Formula anchors** — `separation_px` / `pair_disparity_px` asserted against hand-computed
   literals (not round-trips through the same code).
2. **Depth map** — a sphere dead-centre at distance Z with radius r must read `Z − r` at the
   centre pixel; misses read far. Exact analytic expectation.
3. **SIRDS decoder** — constant-depth bands: for each band row, the smallest offset with ≥99.5%
   pixel self-match (measured on the RELOADED PNG, so the artifact file itself is what's proven)
   must equal `round(s_px(Z))`, and every other offset in range must score ≤90%. Run in BOTH
   viewing modes.
4. **Stereo pair decoder** — centroid of a small white sphere in the left vs right renders;
   pixel disparity must match `d(Z)` within sub-pixel tolerance, sign correct on both sides of
   the focal plane, ≈0 at it. (Tolerance floor: the perspective silhouette-shift of a sphere,
   ~`ppm·D·(e/Z)·tan²α`, kept ≪ 1 px by using a small sphere.)
5. **Anaglyph** — exact channel equality with its source renders.
6. **Rig** — `StereoRig` camera transforms + frustum offsets equal the closed-form values from
   the same dict.

## Failure modes found while building (kept honest)

- **Simple SIRDS back-reference has no hidden-surface handling** — depth discontinuities leave
  echo bands; acceptable at research stage, follow-up documented above.
- **Sphere-silhouette bias**: a stereo-pair decoder using blob centroids measures the silhouette
  centre, not the projected sphere centre — the discrepancy grows with (r/Z)² and can break a
  sub-pixel tolerance; bounded by testing with a small sphere and documenting the term.
- **Autocorrelation is multi-valued**: offset 2s (copy-of-copy) and the pattern strip width both
  produce partial/full self-matches; the decoder must assert the *smallest* qualifying offset.
- **Cross vs parallel invert the near/far→period relation** — a generator that gets the side of
  the screen wrong still makes a pretty stereogram, just with inverted depth; only the decoded
  period-vs-band assertion catches it.

## Follow-ups (enqueue-able)

1. GPU depth-buffer readback (`SubViewport` depth → the same `sirds()`), unlocking arbitrary
   scenes/GLBs as stereogram sources.
2. Hidden-surface SIRDS (symmetric constraint algorithm) + wallpaper/textured pattern strips.
3. Live windowed side-by-side preview host wiring `StereoRig` into two `SubViewport`s (then the
   Godot-aperture window harness can show it); OpenXR adapter reading `eye_descriptors`.
4. An `ipd`/`distance` slider card on the Aperture driving the `geometry` wire (rapid-iteration
   affordance).
