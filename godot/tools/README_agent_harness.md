# Agent Harness — text-equivalent verification gate for the Godot game

**Liam 2026-07-05 (item 4):** *"testing every feature by building text equivalent tools that you can
interact with on your end that verify that functionality is working end to end and allow you to
manipulate increasingly complex game mechanics by using composites of tools (for example, tools that
allow you to manipulate a character, look at a particular thing, interact, take screenshots, etc)."*

This is the **mandatory verification gate** for all future UI / game work in Resonance-Evolution. It
lets an agent (no human, no GUI) drive the game headlessly and **prove** that an interactive element
is at its exact visual position AND that a click there fires the handler — the exact recurring failure
class it exists to kill (*"the X button renders but doesn't click"*, `[[feedback-verify-ui-before-
handing-over]]`). A UI is **not done** until a harness click at each element's on-screen coord produces
the intended effect, and that PASS is captured.

## Files

| File | Role |
|---|---|
| `agent_harness.gd` | the `SceneTree` driver — loads a scene, runs JSON commands, prints one `HARNESS_JSON:` line |
| `agent_harness_lib.gd` | reusable static primitives (ui_dump, hit-testing, input synthesis, effect diff, char driving) |
| `agent_harness.py` | thin python wrapper an agent calls — runs the driver, greps the JSON line, returns it |
| `../headless_agent_harness_test.gd` | self-test proving the harness itself works (run in CI) |
| `../headless_feedback_loop_test.gd` | end-to-end proof of the approve/deny + note feedback loop |

## Quick start (python — the normal path)

```sh
# 1. import assets once on a fresh checkout (runtime can't import GLBs — #145)
"$GODOT" --headless --path godot --import

# 2. dump every interactive control on the 2D board
py -3 godot/tools/agent_harness.py \
    --scene res://aperture/aperture_board_2d.tscn \
    --config '{"mode":"file","inbox_path":"…/inbox.jsonl","feedback_path":"…/feedback.jsonl","mount_chat":false}' \
    --cmd ui_dump

# 3. click the ✕ on a card and ASSERT the skip fired (PASS/FAIL)
py -3 godot/tools/agent_harness.py --scene … --config … \
    --cmd ui_click --arg 'target={"text":"✕","reveal_hover":true}'

# 4. a multi-step script (array of commands run against one live scene)
py -3 godot/tools/agent_harness.py --scene … --config … --cmds-file cmds.json
```

`$GODOT` on this host: `C:/Users/Liam/godot/Godot_v4.6.3-stable_win64_console.exe` (or set the `GODOT`
env var). Always drive against a **temp substrate** (point `feedback_path`/`notes_path` at a temp dir)
so you never pollute the live aperture files.

### Direct (no python) — same thing

```sh
"$GODOT" --headless --path godot -s res://tools/agent_harness.gd -- \
    --scene res://aperture/aperture_board_2d.tscn --config '<json>' --cmds '<json array>'
```

The driver prints exactly one machine line `HARNESS_JSON:{…}` plus a pretty copy. Exit code is 0 when
every command's `assert` is PASS.

## Verbs

| verb | args | what it does / returns |
|---|---|---|
| `ui_dump` | — | every interactive Control: `node_path`, `global_rect{x,y,w,h}`, `mouse_filter`, `visible`, `modulate_a`, `z`, `topmost_at_center`, **`covered`** (true = another node eats its clicks) |
| `ui_click` | `target`, `at?`, `effect_optional?` | synthesize a real press+release at the target's center (or `at:[x,y]`); reports `topmost_at_coord`, `routed_to_target`, `effect_fired`, `effect.deltas`, and **`assert: PASS\|FAIL`** |
| `ui_hover` | `target` | establish hover on a control (reveal hover-gated buttons) |
| `screenshot` | `out?` | run a few frames + save a PNG (needs a real display; headless reports that honestly) |
| `char_move` | `to:[x,y,z]` \| `forward:n` | move the first-person character; returns the new camera position |
| `char_look` | `at:[x,y,z]` \| `node:<path>` | aim the character's camera; returns the resulting forward vector + aimed node |
| `char_interact` | `button?:left\|right` | trigger the character's interact (place / pick / open); returns state after |
| `read_state` | — | camera pos/forward, yaw/pitch, aimed node, mouse mode, board mode, displayed card ids |
| `wait` | `frames?:int` | advance N frames (settle deferred image loads / animation) |
| `list_scenes` | — | the known drivable scenes + whether each exists |

### `target` selectors

```jsonc
{"path": "Bento/…/Tile_x/TileOverlay/@Button@63"}   // exact node
{"text": "✕"}                                        // first Button/Label whose text == this
{"name": "FeedbackBox"}                              // first node whose name == this
{"topmost_at": [420, 186]}                           // whatever control is topmost at that coord
// add "reveal_hover": true to auto-hover the owning Tile_* first (for hover-gated controls)
```

## Why `ui_click` is trustworthy (and how it caught the real bug)

A naive test that clicks `button.get_global_rect().get_center()` **passes even when the button is
invisible or mis-placed**, because it clicks wherever the rect happens to be — not where the user sees
it. `ui_click` closes that gap two ways:

1. **`topmost_at_coord`** — it records which control is *actually topmost* at the click coord. If a
   covering panel / STOP node sits over the button, that shows up here (and `ui_dump.covered` flags it
   ahead of time).
2. **`effect_fired`** — it snapshots the durable side effect (feedback/notes/bookmark row counts +
   displayed-card count) before and after, so a PASS means *an observable thing changed*, not just that
   a signal was emitted into the void.

This is what surfaced the 2026-07-05 X-button fix: the buttons were **hover-gated**, so on the in-room
2D board they were invisible until the pointer was already on the tile — Liam "couldn't press the X"
because there was nothing to press until he was hovering, and a slightly-off pointer never revealed it.
Fix: the ✕/✎/☆ buttons are now **always visible**, the overlay is pinned full-rect, hitboxes are 28px.
Proven by `headless_agent_harness_test.gd` + the windowed screenshot `docs/harness_card_buttons_proof.png`.

## Composing into complex mechanics

Verbs share one live scene across a command array, so state composes:

```json
[
  { "verb": "char_look", "at": [0, 1, -11] },
  { "verb": "char_interact", "button": "right" },
  { "verb": "read_state" },
  { "verb": "ui_dump" }
]
```

(look at the in-room computer → right-click to open the board → read state → dump the board's controls).

## The gate rule

Before handing any UI/game surface to Liam: run `ui_dump` (assert no interactive element is `covered`
and each hitbox matches its visual rect), then `ui_click` each element (assert `PASS`), then capture a
screenshot. Only then is it done. Add a headless test alongside the feature that runs these asserts, so
the gate is a permanent regression guard, not a one-time check.
