# StereoMode — one image ⇄ two images of the exact scene, one slider from flat to VR

2026-07-03 · stereo-renderer-mode lane · builds on the geometry model of
[stereogram_vr_viewer_2026-07-02.md](stereogram_vr_viewer_2026-07-02.md) (RE #128) ·
code: `godot/renderers/stereo_mode.gd` (`StereoMode`) ·
test: `godot/headless_stereo_mode_test.gd` · demo: `godot/examples/stereo_mode_scene.tscn`

## What this is (Liam's correction, 2026-07-03)

Not the SIRDS "periodic mess of colors" — the **scene itself**, twice. The perspective-logic math
that smoothly turns ONE image on any screen into TWO images of the exact same scene, repositionable
anywhere on the screen, viewable cross-eyed as the actual scene in depth — and continuing, with the
same math, into VR. Packaged as a **portable renderer feature** like the focus/detail knob: wrap
any scene's active camera, no scene changes.

## The morph (all closed-form)

One parameter **t ∈ [0,1]**:

```
ipd_eff(t) = t · ipd_m                              (eye separation ramps 0 → e)
rect_e(t)  = lerp([0,0,1,1], target_e, t)           (each eye's screen rect: full-frame → target)
```

Everything else follows from the #128 geometry model unchanged — the eyes sit at `(±ipd_eff/2, 0, 0)`
in the source camera's frame, each with an **off-axis frustum** converged on the plane at distance
`D = screen_distance_m` (near-plane height `H_m·zn/D`, offset `∓(ipd_eff/2)·zn/D`). Consequences,
each one a decoder-tested assertion:

- **Disparity is linear in t**: `d_t(Z) = ppm · (t·e) · (D−Z)/Z = t · d_1(Z)`. Depth "turns on"
  smoothly with the slider — no pop, no discontinuity, because separation and disparity are the
  same linear family.
- **t = 0 IS the mono frame** (byte-identical, tested): `ipd_eff = 0` collapses both eyes onto the
  cyclopean point and the frustum offset to 0 — a symmetric frustum. With `fit_camera` (default),
  the screen height is derived from the wrapped camera (`H_m = 2·D·tan(fov/2)`), so the t=0
  frustum's near-plane height `H_m·zn/D = 2·zn·tan(fov/2)` equals the host perspective camera's
  own — the "one image" really is the host's exact view.
- **t = 1 IS StereoRig** (field-exact, tested): the per-eye descriptors equal
  `StereoRig.eye_descriptors(geometry)` — the single function the live rig and the future OpenXR
  adapter both read (#128's documented seam). So the continuity chain is:

```
t=0 mono frame ──(t slides)──▶ t=1 screen pair ══ same geometry dict ══▶ headset per-eye
                                                   ipd_m ↔ world_scale, screen quad at D,
                                                   znear/zfar ↔ camera clips (stereo_rig.gd)
```

  Screen pair ⇄ VR per-eye is the *same numbers*; entering VR is "t=1 plus XR hands you the eye
  transforms" — not a different renderer.

## Repositionable (rects are DATA)

`layout.rects = { left: [x,y,w,h], right: [x,y,w,h] }`, normalized, keyed by **eye** — so the
cross-eye swap is explicit data, not a hidden flip. Defaults:

| mode | left eye's image | right eye's image | viewing |
|---|---|---|---|
| `"cross"` (default) | RIGHT half `[0.5,0.25,0.5,0.5]` | LEFT half `[0.0,0.25,0.5,0.5]` | cross your eyes |
| `"parallel"` | LEFT half | RIGHT half | wall-eyed / cardboard |

Any placement works (tested with rects in opposite screen corners). At intermediate t each rect is
the lerp from full-frame to its target, so the two images *separate smoothly* out of one.

## Portability (the focus-knob pattern)

`StereoMode` wraps **any** scene/View without modifying it:

```gdscript
var sm := StereoMode.new()
add_child(sm)
sm.wrap(active_camera, stereo_block)   # 2 lines in any host; hotload = sm.apply(new_block)
```

Mechanism: two `SubViewport`s that **share the host camera's `World3D`** (`own_world_3d = false`)
— lights, sky, environment, everything included, zero reparenting. Each holds one eye `Camera3D`
that rides the source camera every frame (`±ipd_eff/2` along its local X), so walkabout / orbit /
animated cameras are stereo'd for free. Display = two `TextureRect`s whose anchors are the rect
data, over an opaque backdrop. At t=0 the right viewport is disabled (one image = one render).

Reference-oracle discipline (as FocusField/EffectStackCpu): the statics `morph` / `eye_rects` /
`compose_display` / `fit_geometry_to_camera` are the pure model; the live node consumes the same
descriptors, and the headless test proves the model with the #128 CPU renderer + decoders.

## Verification (headless, deterministic)

`godot --headless --path godot -s res://headless_stereo_mode_test.gd` — 25 checks:

1. **t=1 ≡ StereoRig** field-by-field (VR continuity); t=0 collapse; t=0.5 exactly half
   (linearity of positions + frustum offsets).
2. **Rect morph**: full-frame at 0, targets at 1, halfway at 0.5; custom rects verbatim;
   cross puts the LEFT eye on the RIGHT half, parallel doesn't.
3. **Disparity anchors**: `d_1(0.45) = +19.385 px`, `d_0.5(0.45) = +9.692 px` (hand literals,
   the #128 geometry), `d_t = t·d_1` exact, `d_0 = 0`.
4. **t=0 mono identity**: composed display byte-identical to the mono render.
5. **Pair decode** at t=0.5 and t=1: measured centroid disparity of a known sphere matches the
   math within 0.8 px (the #128 decoder).
6. **Eye-swap**: composed cross display's right half == left eye image pixel-exact (and the
   parallel display unswapped).
7. **Repositioning** honored on the composed display; **determinism** (re-render byte-identical);
   **fit_camera** anchor `2·zn·tan(fov/2)`; **live wrapper** — host scene untouched, shared
   World3D, camera tracking, hotload re-drives the same instances.

Windowed proof (`--shot`): `godot/docs/stereo_mode_t0.png` (one image) / `_t50.png` (mid-morph) /
`_t100.png` (the cross-eye pair of the real colonnade scene).

## Iteration knobs (the hotload JSON, `godot/examples/stereo_mode_params.json`)

`t` (THE slider) · `geometry.ipd_m` (0.063 human; bigger = hyper-stereo "giant's view", more pop
on far scenes — this is the XR `world_scale` seam) · `geometry.screen_distance_m` (convergence
plane) · `layout.mode` / `layout.rects` (put the two images anywhere) · `fit_camera` · plus the
whole scene/view/sky.

## Follow-ups

1. Wire an Aperture slider card driving `t` + `ipd_m` live over the bridge (rapid iteration).
2. OpenXR adapter reading `eye_descriptors` at t=1 (the documented seam — headset bring-up).
3. Apply the wrapper to the walkabout/sandbox scenes (it's 2 lines; needs only their camera).
4. Anaglyph as a third layout mode (channel-compose the same two viewports — no new geometry).
