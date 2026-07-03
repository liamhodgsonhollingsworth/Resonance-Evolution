# Godot demo inventory — aperture-demo-links lane (2026-07-03)

Task (Liam verbatim): "Put the various demos that I can start up in godot on this aperture so
that I can click around and move between them." Every runnable demo becomes a scene_link card
on the Godot aperture board (`aperture_board_2d.tscn`); clicking opens the demo in its own
detached window via `aperture/scene_launcher.gd` (RE #139 convention). The same card link
(`resonance://open?target=godot&scene=…`) opens the same window from the web board.

## Openable demo scenes (candidates for cards)

All 16 scenes below (14 pre-existing + the 2 new wrappers) boot CLEAN headless from a fresh
worktree with no `.godot` dir (the class-cache-independence condition): exit 0, no script
errors. Windowed spot-checks: walkabout / gallery / lsystem `--shot` proofs captured
(committed under `godot/docs/`).

| # | Scene | What it is | Mode | Boot check |
|---|-------|------------|------|-----------|
| 1 | `res://examples/sandbox_creative.tscn` | Resonance Sandbox — MC-creative buildable world: fly, place/remove blocks, hotbar + paged inventory (desktop-shortcut target) | 3d | clean |
| 2 | `res://examples/painterly_scene.tscn` | Painterly rendering example — sky+clouds landscape through the painterly effect stack, hot-reloads `painterly_params.json` | 3d | clean |
| 3 | `res://examples/focus_scene.tscn` | Focus / depth-of-field sim — receding colonnade, focal distance/depth as data, hot-reloads `focus_params.json` | 3d | clean |
| 4 | `res://examples/projection_sim_demo.tscn` | Projection-mapping simulation (RE #126) — angled projector on a wall, calibration as data | 3d | clean |
| 5 | `res://examples/stereo_mode_scene.tscn` | StereoMode (RE #140) — one→two-images renderer morph, flat→VR on one slider, hot-reloads `stereo_mode_params.json` | 3d | clean |
| 6 | `res://examples/lsystem_scene.tscn` | L-system procgen renderer (RE #134/#137/#138) — axiom/rules/turtle as data, hot-reloads `lsystem_params.json` | 3d | clean, SLOW (grow+paint ≈2-4 min to first frame at depth 4; verified complete, exit 0 — card carries a give-it-time line) |
| 7 | `res://examples/wfc_demo.tscn` | Generalized probabilistic WFC (RE #133) — three weight tiers side by side, SPACE rerolls seed (shipped RE #144) | 2d | clean |
| 8 | `res://walkabout/walkabout.tscn` | 3D walkabout — first-person walk among ingested assets on the renderer-neutral seam | 3d | clean |
| 9 | `res://gallery/gallery.tscn` | Gallery — circular auto-orbiting turntable showcase of ingested assets | 3d | clean |
| 10 | `res://optical_showcase.tscn` | Optical showcase — enclosed forest with sunbeams/god-rays + lens flare + bloom | 3d | clean |
| 11 | `res://aperture/evolution_3d.tscn` | Texture evolution room — walk among evolving texture candidates in 3D | 3d | clean |
| 12 | `res://aperture/aperture_3d.tscn` | 3D Aperture — the in-engine 3D board surface | 3d | clean |
| 13 | `res://live_demo.tscn` | Live-iteration proof — three on-disk arrangement edits re-wire the running 3D scene, then quits (self-closing by design) | 3d | clean |
| 14 | `res://aperture/aperture_board.tscn` | Node-graph board — renders a {nodes,edges} graph file as a GraphEdit panel (sample graph bundled) | 2d | clean |
| 15 | `res://examples/math_paintings_scene.tscn` | NEW WRAPPER — the three math-painting arrangements (Lissajous/flow-field/harmonic) evaluated through GraphRuntime and shown in one window | 2d | clean |
| 16 | `res://examples/stereogram_scene.tscn` | NEW WRAPPER — the stereogram arrangement's four outputs (depth/SIRDS/pair/anaglyph) evaluated and shown in one window | 2d | clean |

## Card mechanics (how clicking works, both surfaces)

Cards are pushed with `--link "resonance://open?target=godot&scene=<uri-encoded res:// path>"`
and stable ids `demo_<slug>`. The GODOT board's `_open_card` shell-opens `card.link` for
inbox cards → the registered `resonance://` protocol handler records the request →
`aperture_launch_watcher.py` (running) spawns the GUI Godot exe detached on
`G:\Wavelet\repos\Resonance-Evolution\godot` with the scene positional — its OWN window.
The WEB board's click walks the identical path. No board-file edits needed (the board files
belong to the concurrent input-fix lane). Thumbnails are raw.githubusercontent.com URLs of
the committed `godot/docs/*.png` proofs.

## Deliberately NOT carded

- `res://aperture/aperture_board_2d.tscn` — the board the cards live ON (no self-link).
- `res://aperture/aperture_chat_panel.tscn` — embeddable component, not a demo.
- `res://aperture/aperture_links_demo.tscn` — the scene-link mechanism proof; superseded as a
  destination by the board itself doing the launching. Skipped to avoid a confusing recursion.
- `res://main.tscn` — the engine default scene; its live-hotload story is covered by
  live_demo + sandbox cards.
- `res://render_view.tscn` — a render(scene,view)→one-PNG driver, not an interactive demo.

## Features WITHOUT an entry scene (wrapper-scene candidates)

- **Math paintings** — `examples/math_{flow_field,harmonic,lissajous}.arrangement.json` run
  only via the headless `math_painting_demo.gd` SceneTree script. Wrapper: minimal window that
  evaluates the three arrangements through GraphRuntime and shows the three paintings.
- **Stereogram demo** (`examples/stereogram_demo.json`) — headless-test-only
  (`headless_stereo_test.gd`); docs PNGs exist (pair/anaglyph/SIRDS/depth). Wrapper candidate.
- **Texture-apply** (`examples/texture_apply_demo.json`) — headless-test-only; the live
  texturing area belongs to the sandbox arc; covered by the sandbox card. No wrapper.

## Boot-check method

`C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot <scene> --quit-after N`
(clean parse/boot → include; trivially broken → trivial fix; deeply broken → exclude + note).
Windowed spot-checks via the GUI exe for scenes whose boot path needs a display.
