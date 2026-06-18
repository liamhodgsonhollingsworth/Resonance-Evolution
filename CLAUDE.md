# Resonance-Evolution — orientation for Claude Code sessions

You are in **Resonance-Evolution**, the general-purpose **in-game homoiconic node engine**.
This repository was formerly named **Apeiron** (an explicit placeholder name); the engine
built here supersedes it. Part of the [Resonance meta-layer](https://github.com/liamhodgsonhollingsworth/The-Resonance-Wavefront) network.

## Read in order
1. `PLAN.md` — the full plan (the user reads ONLY its first "✦ READ THIS" section; everything
   below is reference).
2. `godot/PROGRESS.md` — current status + exact run commands.
3. `godot/README.md` — the engine architecture and the design law in detail.

## The design law (hold these — they are the whole point)
- **Functionality is NEVER new code; it is an arrangement of already-loaded primitive nodes
  wired as DATA.** "Make a function" = emit a new *arrangement*. New primitive TYPES are rare
  (register in `GraphRuntime`); new FUNCTIONS are new arrangements over existing primitives.
- **Homoiconic in-game editor:** functionality is represented as physical objects you OPEN to
  reveal & rewire their internal node graph (the Dreams "microchip" model). Everything
  abstracts down to shared primitives with standard typed I/O.
- **Engine-agnostic substrate + thin porting tools;** renderers are dumb delegates. Godot
  first, never locked-in; GLB/glTF is the model interchange; web/three.js is a later delegate.
- **Portable, recursively-composable plugins** (chips). Declarative-data sharing is safer than
  code-sharing. Maximize portability now; build the sharing layer later.
- **The evolver is supervised** — the user defines what changes / what's fixed / how, per model;
  nothing is pre-wired (Phase 4).
- **Do as little as possible;** build minimal threads between things that already exist.
  **NOTHING is imported or wired without the user's explicit approval** (the approval gate).

## Repo layout
- **`godot/`** — THE engine (current, active). A Godot 4 project. Start here.
- **`PLAN.md`** — the approved plan.
- **`legacy/`** — archived former-Apeiron docs/context (README, architecture, whats_built,
  the old CLAUDE.md, etc.). Outdated understandings — historical reference only.
- **Root Python dirs** (`engine/`, `node_types/`, `renderers/`, `scenes/`, `tools/`, `state/`,
  `session_types/`, `tests/`, `examples/`, `scripts/`, `pyproject.toml`) — the **LEGACY Apeiron
  Python engine.** Do NOT develop or rely on it. It is retained in place (not in `legacy/`) only
  because the sibling **Resonance-Website** repo still imports some of it at runtime
  (`tools/workflow/auth` via `issue_account.py`) and references `state/`. Treat it as frozen.

## Status (2026-06-18)
Phase 0 + Phase 1 **done & verified** (4 headless suites + a live windowed demo): the data
arrangement substrate, the diff-based hotload runtime (re-wires loaded primitives from data,
no script reload), primitives `Const/Math/Log/Model/Transform` (Model = runtime GLTFDocument
GLB load), the content-hash live file watcher, a bootable 3D game, and the Claude↔game live
bridge (`godot/bridge/scene_bridge.py`, `/api/scene/*`). **Next:** Phase 2 (in-game GraphEdit
control panels), Phase 3 (photo→3D model — pending a Tripo3D-vs-Meshy + API-key decision),
Phase 4 (portable chips + the supervised evolver).

## Toolchain
- Godot **4.6.3** at `C:\Users\Liam\godot\Godot_v4.6.3-stable_win64_console.exe` (use the
  `_console.exe` for stdout).
- After adding/renaming any `class_name` script, FIRST run
  `godot --headless --path godot --editor --quit-after 60` to build the class cache, THEN
  `godot --headless --path godot -s res://<test>.gd`. See `godot/PROGRESS.md` for all commands.

## Conventions
- Append-only / write-only: every edit produces a new node/version rather than overwriting.
- Set a local git identity (`git config user.name/email`) before committing.
- **The Phase-4 evolver** (`window.Evolve`, `static/evolve/*`) lives in the **Resonance-Website**
  repo (worktree `admiring-ptolemy-0d49ab`), to be reused — not rebuilt — for Phase 4.
- **Website-specific work belongs in Resonance-Website, not here.** This repo is the engine only.

## Gotchas
- Godot **script** hot-reload is flaky (#72825) → hotload is DATA-driven (re-wire loaded
  primitives), never script-source reload.
- The local TLS proxy blocks big HTTPS downloads ~16MB (`SEC_E_DECRYPT_FAILURE`) → resume with
  `curl -L -C -` in a loop until the file validates.
