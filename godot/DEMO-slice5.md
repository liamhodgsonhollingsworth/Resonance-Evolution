# Slice 5 — the in-world interaction demo

The runnable payoff of Dreams-arc Slice 5: three tiny **node arrangements** driving real
in-world effects, all inside the **actual walkable Aperture3D room** (the same room the
Resonance shortcut opens). Nothing new was built about the room or the primitives — the demo
just *composes* landed pieces (Input / Const / Compare / Select / Sensor / WorldAction +
the `ui.*` and `device.*` host op families) and wires them together.

The interaction-authoring format is one line everywhere: **Source → BRAIN (Logic) → Action.**

| Demo | Source | BRAIN | Action (op) | You see |
|------|--------|-------|-------------|---------|
| **A — button → dialogue** | `Input action.interact` | `Compare` gt + `Select` | `dialogue.show` | a dialogue box appears |
| **B — area → menu** | `Sensor` proximity (player.pos ↔ area centre) | `Compare` lt radius + `Select` | `ui.menu.open` | a menu opens near the red marker |
| **C — band → LED** | `Input signal.band.high` (live oscillator) | `Compare` gt + `Select` (warm/cool) | `device.set_led` | the top-left LED swatch fades warm ↔ cool |

Each op returns a **declarative receipt (DATA)** — the arrangement is portable: on a host with no
UI / no LED, `dialogue.show` / `device.set_led` fall through WorldActions' "unknown op = declared
no-op" and the *same* arrangement runs unchanged.

## Launch (GUI, windowed)

Run from a shell in the repo root (`Resonance-Evolution/`). Use the **GUI** exe (no `_console`):

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64.exe --path godot res://demo_interactions.tscn
```

(The `_console` exe is only for the headless stdout test below.)

## Controls

| Key / action | Effect |
|--------------|--------|
| **WASD + mouse** | walk / look (the room's own first-person controller) |
| **E** | **INTERACT** → shows the dialogue box (demo A). Press **E** again or click **Dismiss** to close. |
| **walk to the RED marker** (≈ centre-front of the room) | enter the area → the menu opens (demo B); walk away to close it |
| **the LED swatch** (top-left) | driven by a slow band oscillator (demo C) — watch it fade warm ↔ cool on its own |
| **hold B** | force the band HIGH → the LED flips to WARM on demand (demo C) |
| **ESC** | release the mouse (room default) |

## Verify headless (the real-tree #049 test)

Every assertion runs on the **mounted, room-owned** tree the GUI drives (via the controller's
`drive_once()` backend — there is no GUI-only path), not a standalone widget:

```
C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe --headless --path godot -s res://headless_demo_interactions_test.gd
```

Expect `RESULT: ALL PASS` (all three demos in the real room + the `register_host` builtin-shadow
guard + connection-isolated-failure + malformed-args-no-op).

## Files

- `aperture/demo_interactions.gd` + `demo_interactions.tscn` — the demo controller + scene (the GUI entry).
- `runtime/ui_actions.gd` — the `dialogue.*` / `ui.menu.*` op family.
- `aperture/ui_action_renderer.gd` — the minimal in-world host that draws a receipt (dialogue box / menu).
- `arrangements/demo_button_dialogue.json`, `demo_area_menu.json`, `demo_band_led.json` — the three arrangements.
- `runtime/device_actions.gd` — the `device.*` family (reused from Slice 7 for demo C).
- `runtime/world_actions.gd` — the op registry + the `register_host` builtin-shadow guard (Slice 5).
