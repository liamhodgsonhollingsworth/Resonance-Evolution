# Resonance Node Editor (Godot)

An **in-game homoiconic node editor**. The one rule: **nothing the system does is "new
code" — every function is an arrangement of already-loaded primitive nodes, wired
together as data.** A behavior, a condition, a renderer, an image effect is each a
*primitive* with standard typed ports; you build anything by *wiring primitives into
arrangements*. When Claude Code (or you) "writes a function," it emits a new
**arrangement** that the running game applies live. People share functionality by
sending each other arrangements (chips) — data over shared primitives, never code.

See the full plan: `../.claude/plans/look-at-the-current-wondrous-scott.md`.

> **Approval gate:** no external tool becomes a primitive without Liam's sign-off. The
> files here depend on nothing external yet — they are pure substrate.

## What's here (Phase 0 — substrate contracts)

| Path | Role |
|---|---|
| `schema/arrangement.schema.json` | The arrangement data format (graph of primitives + typed wires). The thing that hotloads, that a control panel shows, and that serializes for sharing. |
| `schema/arrangement.example.json` | A tiny example: `Const 3` + `Const 4` → `Math add` → `Log`. |
| `runtime/port_types.gd` | The typed-port vocabulary + widening-only compatibility (maps onto GraphEdit slot types in Phase 2). |
| `primitives/primitive.gd` | Base class: typed ports + a pure `evaluate(inputs)` dataflow step. Self-contained/portable by design. |
| `primitives/prim_const.gd`, `prim_math.gd`, `prim_log.gd` | The first three primitives (a source, a compute, a sink). |
| `runtime/graph_runtime.gd` | Interprets an arrangement into live primitives and evaluates the dataflow. **Reload is a DIFF, not a rebuild** — kept primitives (and later, live 3D models) survive; only changed nodes are touched. This is the hotload model. |
| `headless_demo.gd` | A headless self-test of the hotload spine (no GUI needed). |

## Run the headless self-test

Once Godot 4.4+ is installed:

```sh
godot --headless --path godot -s res://headless_demo.gd
```

Expected output ends with `RESULT: ALL PASS`. It loads the example arrangement
(expects `7`), then **hotloads** by changing only `Math.op` to `mul` in the data and
re-evaluates (expects `12`) — proving that changing the arrangement re-wires the
already-loaded primitives without rebuilding their instances.

## Where this is going (see the plan)

- **Phase 1** — the data-driven runtime + hotload spine in a running game; add any GLB
  live (`GLTFDocument`) as a `Model` primitive; `/api/scene/*` relay to the Python
  bridge; `godot-mcp` screenshot verify.
- **Phase 2** — the in-game editor: `GraphEdit` in a diegetic `SubViewport` on a 3D
  object (you open an object to see/rewire its internal arrangement); group a wiring
  into a **Chip** (a reusable, nestable, shareable plugin).
- **Phase 3** — photo→model + the **glasses** demo: worn-condition → renderer/lens →
  flare/shader/grain/vignette optical pipeline, opened and rewired live in-game.
- **Phase 4** — portable chip strings (sharing) + the supervised evolver.

## Conventions

- Primitives are **portable plugins**: no hidden globals; only serializable values
  cross ports (so a node/cluster can be lifted out and shared). The `static-replay`
  conformance idea: a primitive you can replace with a recorded output blob has
  serializable ports by construction.
- New primitive **types** are rare and register in `GraphRuntime`; new **functions**
  are just new arrangements over existing types.
- GDScript uses **tab** indentation here.
