# Resonance-Evolution

**An in-game homoiconic node engine — functionality is an arrangement of primitives you
wire together as physical objects.**

Nothing the system does is "new code." Every function — a behavior, a condition, a renderer,
an image effect — is a small **primitive node** with standard typed inputs/outputs, and you
build anything by **wiring primitives into arrangements** (data). You compose and edit those
arrangements *inside the running game*: open an object's "control panel" to see and rewire the
nodes that compose it, group a wiring into a reusable **chip**, and send chips to other people
as portable plugins. Because what you share is *data over shared primitives* (not code), it's
portable and safe.

The engine is **Godot-first but engine-agnostic**: the substrate (arrangements + GLB models)
is independent of any renderer, and porting tools carry it into Godot today and other engines
later. Claude Code iterates on a *running* game live — change the arrangement data and the game
re-wires its already-loaded primitives with **no restart**.

> Formerly named **Apeiron** (a placeholder name, now retired). The prior Python node-graph
> engine and its docs are archived under [`legacy/`](legacy/); they do not reflect the current
> direction. Part of the [Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront) network.

## Status

Phase 0 + Phase 1 are **built and verified** (headless test suites + a live windowed demo where
HTTP pushes hot-swapped a running 3D scene):

- **Substrate** — an *arrangement* is a graph of primitive instances + typed wires, as data.
- **Live hotload runtime** — reloads by *diff*: unchanged primitives (and live 3D models) are
  kept, only changed nodes are touched. No script reload.
- **Primitives** — `Const`, `Math`, `Log`, `Model` (loads a GLB at runtime), `Transform`.
- **Claude↔game bridge** — push an arrangement over HTTP, screenshot the running game back.

In active development: an in-game `GraphEdit` node editor (control panels / chips), photo→3D
models, an optical/image-effect pipeline, portable chip sharing, and a supervised model evolver.

## Quick start

The engine is the Godot project in [`godot/`](godot/). See [`godot/README.md`](godot/README.md)
for the architecture and [`godot/PROGRESS.md`](godot/PROGRESS.md) for run commands. The full
design is in [`PLAN.md`](PLAN.md).

```sh
# headless self-test of the hotload spine (Godot 4.6+):
godot --headless --path godot --editor --quit-after 60      # builds the class cache (first time)
godot --headless --path godot -s res://headless_demo.gd     # expects "RESULT: ALL PASS"
godot --path godot                                          # run the live game
```
