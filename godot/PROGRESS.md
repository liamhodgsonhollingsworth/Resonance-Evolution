# Progress / handoff — Resonance Node Editor (Godot)

Status as of 2026-06-18. Plan: `../.claude/plans/look-at-the-current-wondrous-scott.md`.
Read `README.md` for the architecture and the design law (functionality = arrangements of
already-loaded primitives, wired as data; never new code).

## Done + verified (Phase 0 + Phase 1)
- **Substrate:** an *arrangement* = a graph of primitive instances + typed wires, as data
  (`schema/arrangement.schema.json`). The one representation that hotloads, that a control
  panel will show, and that serializes for sharing.
- **Runtime + hotload:** `runtime/graph_runtime.gd` turns an arrangement into live
  primitives and **reloads by diff** (keeps unchanged instances / live models, updates
  params in place). `runtime/live_host.gd` watches the arrangement file by content-hash and
  hot-reloads the running game with no restart.
- **Primitives:** `primitives/` — `Const`, `Math`, `Log`, `Model` (runtime `GLTFDocument`
  GLB load = "add any 3D model live as a node"), `Transform` (placement composes by WIRING
  Model→Transform). Typed ports + widening compat in `runtime/port_types.gd`.
- **Running game:** `main.tscn` / `main.gd` boot a 3D scene that runs the live arrangement.
- **Claude↔game live bridge:** `bridge/scene_bridge.py` — standalone HTTP relay
  (`/api/scene/load|get|screenshot|status`) over `live/`, plus a screenshot-request channel.
  Demonstrated live: two HTTP pushes hot-swapped the same running instance (box 30° →
  160°+1.6×), screenshots captured each — no restart.
- **Tests:** `headless_demo|model|live|transform_test.gd` (4 suites, all green).

## How to run
Godot: `C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe` (use the console exe).
```
# REQUIRED after adding/renaming any class_name script (builds the class cache):
godot --headless --path godot --editor --quit-after 60
# headless test:
godot --headless --path godot -s res://headless_demo.gd
# windowed screenshot -> godot/shot.png:
godot --path godot -- --shot
# run the live game:
godot --path godot
# the live bridge:
python godot/bridge/scene_bridge.py --port 8210
#   then: curl -X POST :8210/api/scene/load -d '<arrangement json>'
#         curl -X POST :8210/api/scene/screenshot ; read godot/live/shot.png
```

## Next (not started)
- **Phase 2:** in-game `GraphEdit` control panels in a diegetic `SubViewport` (clone the
  official `gui_in_3d` demo; vendor MIT `liggiorgio/graph-edit-demo` +
  `tehelka-gamedev/godot-custom-graph-editor`); chip grouping + drill-down. Toward the
  glasses example.
- **Phase 3:** `tools/image_to_3d.py` + `/api/model/from-image` (DECISION PENDING:
  Tripo3D vs Meshy + API key; local TripoSR fallback) → glasses chip + screen-space effects.
- **Phase 4:** chip portable-string (de)serializer + supervised evolver domain.
- A Godot MCP is optional (the bridge already covers push + screenshot + read).

Nothing is committed yet.
