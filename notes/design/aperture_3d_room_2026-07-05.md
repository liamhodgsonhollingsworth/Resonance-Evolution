# 3D Aperture Room — design note (2026-07-05)

Lane `aperture-3d-room-v2`, coordinator session 53e5c832. Implements Liam verbatim spec
`2026-07-05_sandbox_controls_explore_3daperture_liam_verbatim.md` **items 4 & 5** (+ the overarching
"leave feedback on pages and scenes" ask, in-scene half).

## What was built

The 3D aperture (`godot/aperture/aperture_3d.tscn` / `.gd`) is **rebuilt from a card gallery into a
walkable sandbox ROOM**. Git history preserves the old gallery script; the room supersedes it because
item 4 is explicit that the 3D aperture has "none of the same 2D menu pages or links to things like
art" — the old aperture_3d WAS that in-world card menu.

Four new files, one rewrite:

| File | Role |
|---|---|
| `aperture/aperture_3d.gd` (rewrite) | The room: first-person player, solid walls, sandbox place/pick-up/remove/drop/empty-hand, computer + doors wiring, in-scene feedback. |
| `aperture/scene_transition.gd` (new) | Transition manager: per-target same-window-vs-new-window flag + seamless fade (item 5). |
| `aperture/door_gateway.gd` (new) | Reusable data-driven physical door; walk in → enter target scene (item 4). |
| `aperture/computer_terminal.gd` (new) | The 3D computer; right-click empty-handed → mounts `aperture_board_2d.tscn` as a same-window overlay (item 4). |
| `headless_aperture_3d_room_test.gd` + `headless_aperture_3d_scene_driver.gd` (new) | 19 + 11 headless assertions; ALL PASS. |

## Item-by-item mapping (every visible element → a spec line)

- **"sandbox environment (picking up and removing nodes) so that I can change the layout"** — the room
  composes the merged sandbox runtime helpers into a first-person controller: **place** a hotbar block
  at the aim point, **pick up** an aimed node (it follows the ray, click to drop → rearrange),
  **remove** with X, **drop** the held item with Q (it disappears for now), **empty hand** = hotbar
  slot 0. Layout persists append-only in the world store (F5). Walls are solid (movement-clamp
  collision) — the "run into solid walls" feel.
- **"none of the same 2D menu pages or links to things like art"** — the room has NO in-world card menu.
  The only interactive object beyond the sandbox is the computer and the doors.
- **"a 3D computer asset that I can interact with by right clicking when holding nothing … opens the
  2D page (which I leave using escape)"** — `computer_terminal.gd` builds a desk+monitor; the room's
  ray tags it `interactable:"computer"`; empty-hand RIGHT-click → `open_board` mounts the **existing
  peer-owned** `aperture_board_2d.tscn` into a `CanvasLayer` overlay in the same window; ESC unmounts.
- **"a physical door or gateway in the world that I can enter to go into the scene (leave is wired to
  escape)"** — `door_gateway.gd` is a reusable portal; the room polls each door against the player each
  frame; crossing the threshold fires `entered(target)` once → the room hands it to the transition
  manager. Leaving is ESC (the target scene wires ESC back, as the room does).
- **Item 5 same-window vs new-window** — see below.
- **In-scene feedback (overarching)** — F opens a note box → appends one JSONL line to
  `Alethea-cc/state/sandbox/notes.jsonl` keyed to `scene: "aperture_3d"`, the **same substrate + schema**
  as card feedback. A note left in the room is byte-indistinguishable from a card note by data contract.

### Item 2 correction honored (no grid, no preview)

Placement is **FREE**: the block lands exactly where the camera ray hits room geometry (no grid snap,
no highlighted preview ghost). This matches spec item 2 and the direction the peer `sandbox-mc-controls-v2`
lane is taking `sandbox_creative.gd`, so the room stays consistent without forking that file.

## Item 5 — the transition manager (the load-bearing design)

`scene_transition.gd` routes every target through **one per-target FLAG**:

```
{ "scene": "res://…tscn",
  "same_window": true|false,   // explicit wins
  "experimental": true,        // convenience: experimental ⇒ same_window defaults to false
  … }
```

- **`same_window: true`** → `SceneTree.change_scene_to_file` — the whole active scene swaps in the ONE
  process. Seamlessness is a black fade-out on a top `CanvasLayer`, the swap under cover of the black
  frame (no reload flash), then the incoming scene calls `SceneTransition.fade_in_on_ready(self)` to
  fade back in — the "step through a doorway between two physical rooms" feel spans the boundary. The
  room already calls `fade_in_on_ready` at the top of its own `_ready`, so re-entering the room via a
  same-window transition resolves smoothly. Fade duration is DATA (`fade_seconds`).
- **`same_window: false` / `experimental: true`** → delegates to the existing tested
  `ApertureSceneLauncher.launch` (scene_launcher.gd) — the exact detached-Godot-window path the 2D board
  and the `resonance://` web protocol already use. This is the "experimental scenes that rely on a new
  system that could break → open a new godot window" path.

**The migrate-back seam (spec: "Later on, these should then be connected back to being in the same 3D
window"):** flipping one experimental scene from a new window to same-window is a **one-field data edit**
— set `same_window: true` on its door spec (or target). No code change. Verified by the test
`explicit same_window WINS over experimental`.

The room ships two doors demonstrating both channels:
- **"Explore gallery (experimental)"** → `res://examples/aperture_explore_scene.tscn`, `experimental:true`
  → NEW window. This is the peer `aperture-explore-scene-demo` lane's scene; the door OPENS it when it
  exists, and flips to same-window with one field once that system is proven.
- **"Sandbox"** → `res://examples/sandbox_creative.tscn`, `same_window:true` → SAME window, seamless.

## Sandbox reuse: composition, not a fork (and what clean reuse would need)

Per dispatch, `sandbox_creative.gd` was **not** edited or forked (a peer lane actively refactors it).
The room instead **composes the stable runtime helpers** that `#145` merged to origin/main:

- `runtime/asset_library.gd` — lazy GLB loader (manifest at boot, background load on demand). Reused
  verbatim for the room's asset placement + the placeholder-then-swap flow.
- `runtime/world_store.gd` — append-only versioned world persistence. Reused for the room layout
  (`aperture_room` world; F5 saves v(N+1)).
- `runtime/sandbox_behaviors.gd` — composable data behaviors. Reused via `Behaviors.tick` for every
  placed node.
- `renderers/godot_scene_renderer.gd::_primitive_mesh` — the 13-shape primitive vocabulary. Reused for
  the room's building-block palette.

The room re-implements the first-person controller + free placement itself (~150 lines) because
`sandbox_creative.gd` is a **whole scene root**, not a component: it owns its own camera, HUD, hotbar
UI, input pump, and grid model, tightly coupled to being the scene root. It cannot be instanced as a
child of another scene without two cameras, two HUDs, and duplicated input.

**What clean controller reuse would need (follow-up for the peer lane refactor):**

1. Extract the sandbox's place/pick-up/move/remove/drop/save verbs into a **`SandboxController`
   component** (a plain `Node3D` or `RefCounted`) that takes an injected camera + object root + asset
   library + world store, and exposes the verbs as methods — separating *mechanics* from *scene chrome*
   (camera/HUD/input). Then both `sandbox_creative.tscn` and this room instance the SAME controller.
2. Make the held-item seam (`sandbox_items.gd`, currently on the peer branch) part of that component so
   empty-hand / tool behavior is shared, not re-implemented per scene.
3. Move the free-placement model (post item-2) into the component so grid-vs-free is one config flag,
   not divergent code in two scenes.

Until that extraction lands, the room's composition-against-the-runtime-API approach is the correct
non-forking choice, and the two stay consistent by both honoring items 1 & 2.

## Testing / verification

- `headless_aperture_3d_room_test.gd` — 19 assertions: transition routing (the flag), door arming
  (fire-once + re-arm), note schema (scene-id-keyed), live-guard (no notes.jsonl pollution). ALL PASS.
- `headless_aperture_3d_scene_driver.gd` — 11 assertions: the REAL `aperture_3d.tscn` instantiates,
  builds Objects/Doors/Computer, both door specs resolve their channel, free placement adds an object.
  ALL PASS.
- `docs/aperture_3d.png` — windowed `--shot`: the room renders (solid walls, computer, both doors, demo
  blocks, hotbar with empty-hand slot 0).
- `docs/aperture_3d_board_overlay.png` — windowed `--shot-board`: the 2D board mounts as a same-window
  overlay (`board_is_open=true`), chat panel + live notifications rendering, ESC ribbon on top.
- Class-cache independence (#046): all sibling loads are path-based `preload()`; tested with the class
  cache freshly built.

## Follow-ups (enqueue)

- **Sandbox controller extraction** (above) so the room and `sandbox_creative.tscn` share one mechanics
  component instead of two implementations.
- **Block-primitive layout serialization** — the room's F5 save currently round-trips only asset objects
  through the world store; primitive blocks need a serialize/reseed path (the sandbox has one for its
  grid model; adapt for free placement).
- **Migrate the explore door to same-window** once the peer explorer scene is proven stable — flip its
  `same_window` field.
