# WFC Editor UX Patterns — Don't Reinvent

**Purpose:** Survey existing Wave Function Collapse (WFC) rule-authoring and tile-instance-authoring tools/games and extract concrete, borrowable UX patterns for the engine's future WFC authoring UI — so we copy proven interactions instead of reinventing them.

**Date:** 2026-07-01

---

## 1. Intro — the two-surface spec, and why borrow

Liam's spec is a WFC authoring UI with **two surfaces**:

- **(a) A visual RULE editor** — author adjacency/constraint rules between tiles *visually* (scrollable/draggable canvas), not by hand-editing JSON. A rule = which tile may sit next to which, in which direction, plus higher-order constraints (paths, borders, counts).
- **(b) A drag-drop tile INSTANCE editor** — the user places specific tiles by hand, and the solver **re-solves around** the placed (locked/pinned) tiles: incremental / constrained collapse with user pins.

Both surfaces are well-trodden ground. The overlapping-vs-tiled distinction, the "pin a tile then propagate" concept, the live animated collapse, and the place-and-locally-re-solve feel all exist in shipped tools. The engine already has a **WFC Context-handler kernel** (a `wfc` handler inside `godot/primitives/prim_context.gd` taking `params.wfc = { width, height, tiles, adjacency }`, seeded, deterministic, fail-soft) but **no `prim_wfc` and no authoring surface** — verified: `ls godot/primitives/ | grep wfc` returns nothing, and the only WFC code is the handler arm + `godot/headless_wfc_test.gd`. So we need to build the *authoring* layer that feeds this kernel DATA. This note is the "steal these interactions" input to that build.

---

## 2. Per-tool findings

### 2.1 mxgmn/WaveFunctionCollapse — the original (learn-by-example vs explicit adjacency)

The canonical implementation ([github.com/mxgmn/WaveFunctionCollapse](https://github.com/mxgmn/WaveFunctionCollapse), [README](https://github.com/mxgmn/WaveFunctionCollapse/blob/master/README.md)) ships **two models**, and the split between them is the single most important authoring decision we inherit:

- **Overlapping model** — *learns rules from an example bitmap.* "Read the input bitmap and count NxN patterns" ([README](https://github.com/mxgmn/WaveFunctionCollapse/blob/master/README.md)); "In the examples a typical value of N is 3"; the guarantee is "The output should contain only those NxN patterns of pixels that are present in the input." The user authors **an example image**, not rules — the tool infers adjacency. UX cost: near-zero rule authoring; UX limit: you can only get what the sample implies.
- **Simple Tiled model** — *explicit adjacency.* "It's convenient to initialize the simple tiled model with a list of tiles and their adjacency data"; each tile is "assigned with its symmetry type," and "it's enough to enumerate pairs of adjacent tiles only up to symmetry." The user authors **which tile pairs may touch**, per edge/direction. This is exactly the DATA our `wfc` handler already consumes (`tiles` + `adjacency`, with auto-mirror), so our rule editor is fundamentally a Simple-Tiled authoring surface.

The README also documents the **pin-then-propagate** concept directly: "WFC algorithm supports constraints… it can be easily combined with… manual creation," with an example of "WFC autocompleting a level started by a human," where "preset tiles remain fixed while the algorithm fills remaining regions." That *is* our instance editor in one sentence.

> **Borrowable:** (1) Offer **both** authoring modes — learn-by-example (draw a sample arrangement, infer the ruleset) **and** explicit adjacency (author tile-pair edges) — because they're the same underlying legal-adjacency list from two directions. (2) Preset/fixed tiles are a first-class, cheap feature in the base algorithm — the instance editor is not a bolt-on.

### 2.2 DeBroglie (BorisTheBrave) — the constraint taxonomy goldmine

DeBroglie ([github.com/BorisTheBrave/DeBroglie](https://github.com/BorisTheBrave/DeBroglie)) is a C# WFC library and the engine *behind* Tessera. It supports **both** models explicitly ([features](https://boristhebrave.github.io/DeBroglie/articles/features.html)): the **Overlapping** model ("constrains that every `n` by `n` rectangle in the output is a copy of a rectangle taken from the sample") and the **Adjacent** model ("constrains which tiles can be placed adjacent to which other ones"). Crucially, the Adjacent model can be fed **two ways** — from a sample ("Adding a sample to an adjacent model adds all adjacent tile pairs in the sample into the legal adjacency lists") **or** explicitly ("You can also directly specify adjacent tile pairs"). This is the exact "one legal-adjacency list, two authoring front-ends" pattern our rule editor should expose.

Its **constraint taxonomy** ([constraints](https://boristhebrave.github.io/DeBroglie/articles/constraints.html)) is the reference model for the non-local part of our RULE editor:

- **Border** — "Restricts what tiles can be selected in various regions of the output" (e.g. ground/empty at edges).
- **Fixed Tile** — "Forces a given location to be the specified Tile at initialization" (random legal position if unspecified). *This is the instance-editor pin, as a rule primitive.*
- **Path constraints** ([path_constraints](https://boristhebrave.github.io/DeBroglie/articles/path_constraints.html)) — `ConnectedConstraint` ("there is a valid path between relevant tiles"), `LoopConstraint`, `AcyclicConstraint`; "generally more performance heavy… usually require backtracking."
- **Count** — "Forces the number of a given tile… to be at most or at least a given number."
- **Max Consecutive** — "Prevents more than a certain number of tiles appearing consecutively along the x, y or z axis."
- **Mirror / Symmetry** — force symmetric output about an axis, or generalized symmetry.
- **Separation / Pair Separation** — "Forces particular tiles to not be placed near each other" / "one set of tiles… not… near another set" (Poisson-disk-like distribution).

And the load-bearing solver feature: **backtracking.** "the propagator does not give up when a contradiction occurs. It will attempt to roll back the most recent tile placement, and try another placement instead" ([constraints](https://boristhebrave.github.io/DeBroglie/articles/constraints.html)); "With multiple constraints… Turning on backtracking can alleviate" failure. This is what lets a *pinned instance edit* re-solve without dead-ending.

> **Borrowable:** Adopt DeBroglie's **constraint vocabulary verbatim** as the rule-editor's palette of rule types (adjacency, border, fixed, path/connected, count, max-consecutive, mirror, separation). Each becomes a wired rule-node. And **backtracking is mandatory** the moment we allow instance pins — our current handler is fail-soft ("REPORTS contradiction… still emits a grid," per `headless_wfc_test.gd`); the instance editor needs *roll-back-and-retry*, not just report.

### 2.3 Tessera (BorisTheBrave, Unity plugin on DeBroglie) — the "paint the sides" authoring UX

Tessera ([Unity forum thread](https://forum.unity.com/threads/released-tessera-generate-3d-tile-based-levels-with-wave-function-collapse.784844/), [docs](https://www.boristhebrave.com/permanent/21/01/tessera_docs_4/articles/quality.html)) wraps DeBroglie with the concrete authoring UI we most want to copy. Its headline pattern: it "lets you control the generation by 'painting' information onto the sides of your tiles" ([search result summary](https://forum.unity.com/threads/released-tessera-generate-3d-tile-based-levels-with-wave-function-collapse.784844/)). The user does **not** enumerate adjacency pairs by hand — they **paint colored/labeled faces onto tile sides**, and any two faces with matching paint may abut. That collapses an O(n²) pairwise-rule authoring problem into an O(n) per-face labeling problem. The docs confirm "faces painted" on tiles drives adjacency ([quality docs](https://www.boristhebrave.com/permanent/21/01/tessera_docs_4/articles/quality.html)).

Tessera's **pins / fixed tiles**: "pins are used to fix specific tiles in place before generation. Fixed tiles can be used to pin the destination points of the path, and then the Path constraint is obliged to insert tiles that force the rest of the path to connect… pre-generating your path and using pins can help Tessera use it instead of the more expensive Path constraint" ([tips-and-tricks](https://www.boristhebrave.com/2020/02/08/wave-function-collapse-tips-and-tricks/)). Big tiles (multi-cell tiles) and per-generation quality controls are exposed in the editor — **Backtracking toggle, Step Limit, Failure Mode = "Last"** which spawns "Uncertainty Tile / Contradiction Tile" prefabs, and a diagnostic view with "white tiles indicating what has yet to be generated, and the red tile indicating where the contradiction occurred" ([quality docs](https://www.boristhebrave.com/permanent/21/01/tessera_docs_4/articles/quality.html)).

> **Borrowable:** (1) **Paint labels on tile sides** rather than authoring pairwise rules — the biggest single UX win for the rule editor. (2) **Pins as path anchors** — place two fixed tiles, let a connectivity constraint fill between them. (3) **A visible contradiction tile** (red cell) at the exact failure location — the instance editor needs this so a pin that over-constrains the grid shows *where* it broke, not a silent failure.

### 2.4 Townscaper (Oskar Stålberg) — the gold-standard INSTANCE feel

Townscaper is the reference for the "place and it resolves around you" interaction ([How Townscaper Works, gamedeveloper.com](https://www.gamedeveloper.com/game-platforms/how-townscaper-works-a-story-four-games-in-the-making)). The interaction is one click: players "click to add or remove blocks within an irregular grid." The re-solve is **local, not global**: "the placement of a new block forces the rest of the existing structure to re-evaluate, to make sure constraints are satisfied" — the whole town is *not* regenerated. The work is **staged for responsiveness**: "the hard part of the process is done first: when a new piece is added, the Wave Function Collapse identifies the possible modules for that cell, and then afterwards it will decorate it" — so the expensive constraint solve happens on placement and the cosmetic decoration follows, preventing lag "during the crucial moment of player interaction." The "everything auto-connects" feel comes from the solver: "Players experience seamless connectivity because the underlying constraint solver ensures all adjacent tiles satisfy placement rules automatically." The WFC lineage traces to Bad North ("this constraint-based approach mirrors what occurs in Bad North but optimized for real-time responsiveness rather than pre-generation").

> **Borrowable — the core of the instance editor:** **one click places a tile → the solver re-collapses only the affected neighborhood → the result appears instantly.** Two staged phases: (1) constraint-solve the placed cell + ripple, (2) decorate. The user never sees "generate" — placement *is* the generate action. This is the interaction to build the instance editor around.

### 2.5 Oskar Stålberg's WFC talks (EPC2018 "WFC in Bad North") — the live-collapse visualization

The EPC2018 talk ([YouTube](https://www.youtube.com/watch?v=0bcZb-SsnrA), [Are.na](https://www.are.na/block/5123624)) covers "the theory behind WFC, its implementation and further development in Bad North, as well as the tools and pipeline." The load-bearing UX artifact: Stålberg "made an interactive version of the tiled model that runs in the browser, and he shows **partially observed states as semi-transparent boxes, where the box is bigger for a state with more options**" ([search summary](https://www.youtube.com/watch?v=0bcZb-SsnrA)). That is a direct, animated rendering of **cell entropy** — you *see* superposition shrink as constraints propagate, and you can constrain a cell and watch the ripple.

> **Borrowable — the rule editor's live-feedback loop:** render **un-collapsed cells as fuzzy/semi-transparent, sized by remaining option count (entropy)**, and animate the collapse. When the author edits a rule or drops a pin, they *watch* the propagation instead of pressing "regenerate" and diffing. This is the single best "is my ruleset doing what I think" debugging affordance.

### 2.6 Godot-native WFC addons — code-only, no authoring UI

The Godot ecosystem has solvers but essentially **no in-editor authoring UI** — which is precisely the gap our surface fills:

- **AlexeyBond/godot-constraint-solving** ([github](https://github.com/AlexeyBond/godot-constraint-solving)) — the most capable Godot-4 WFC/CSP solver. But: "Currently it's possible to 'learn' WFC rules in running game only, not in editor." Rules come from **inferring from an example map** ("2d WFC generator is able to infer rules from an example of a valid map"), **negative samples**, or **tileset terrain metadata** ("Rules can also in some cases be learned from terrain settings of tilesets"). Critically it *does* support pinning via a **Preconditions API**: "place some tiles on that map (either manually or procedurally), generator will take them into account," defining "a set of tiles allowed in given cell." 2D only for now ("3d map generation… is not yet implemented").
- **WFC 2D/3D Generator** ([asset 2473](https://godotengine.org/asset-library/asset/2473)) — code/scene-based, sample-driven ("you need 2 tile maps. one to create a new map on (target) and one to use as a sample"), C#, no visual authoring UI, no explicit fixed-tile UX.
- Others (`WaveFunctionCollapse-GodotAddon`, asset 1951) are similar code-first solvers.

> **Borrowable:** The **Preconditions API "set of tiles allowed in a given cell"** is exactly the data shape our instance-editor pin should write (a pin is a single-element allowed-set). And the observation that *none* of these ships an editor UI confirms the authoring surface is the differentiator worth building.

### 2.7 Godot's TileSet "Terrains" tab — the nearest in-house visual adjacency editor (already inside Godot)

The strongest borrowable pattern already ships **inside our engine's toolkit**. Godot's TileSet **Terrains** feature ([using_tilesets docs](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html), [Portponky/better-terrain](https://github.com/Portponky/better-terrain)) is, functionally, a visual adjacency-rule editor:

- Rules live in **Terrain Sets**, each with a matching **mode**: "Match Corners and Sides" (all 8 neighbors), "Match Corners," or "Match Sides" ([docs](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html)).
- The rule engine is **Terrain Peering Bits** — a **3×3 grid where the center is this tile's own terrain and the 8 surrounding squares are the required neighbor terrains** ([UhiyamaLab](https://uhiyama-lab.com/en/notes/godot/terrains-autotile-setup/)). "if a tile has all its bits set to `0` or greater, it will only appear if _all_ 8 neighboring tiles are using a tile with the same terrain ID" ([docs](https://docs.godotengine.org/en/stable/tutorials/2d/using_tilesets.html)).
- The authoring gesture is **painting**: "You switch to the Paint brush… and paint connection rules using the Terrain Peering property" — the author selects a tile and paints which neighbor slots must match, "effectively paint[ing] connection rules directly onto the tile representation." At *use* time, painting a terrain onto the map auto-selects the tile "whose peering bits best match the actual neighbors."

> **Borrowable — the rule editor's visual model:** the **per-tile 3×3 (or directional) neighbor-slot grid you paint**, plus terrain-set match-modes, is a battle-tested, in-house, visually intuitive adjacency editor. Our rule editor can mirror this exact interaction (paint required neighbors onto a tile's slots) and even *learn* an initial ruleset from an existing terrain-configured TileSet (matching AlexeyBond's "learn from terrain settings").

---

## 3. Synthesis — RULE editor: patterns to copy

1. **Two authoring front-ends over one legal-adjacency list** (mxgmn, DeBroglie): (a) **learn-by-example** — the author draws/assembles a valid sample arrangement and we infer `adjacency`; (b) **explicit** — the author states tile-pair edges directly. Same data, two doors. Our `wfc` handler already auto-mirrors, so "state once per axis" holds.
2. **Paint labels on tile sides instead of enumerating pairs** (Tessera): matching face-labels ⇒ legal adjacency. Turns O(n²) pair authoring into O(n) per-face labeling.
3. **Godot's Terrains 3×3 peering-bit paint UI as the visual model** (Godot TileSet): the nearest in-house analog — paint required neighbors onto a tile's neighbor-slot grid; support corner/side/both match modes; optionally seed the ruleset from an existing terrain-configured TileSet.
4. **DeBroglie's constraint taxonomy as the rule palette** (DeBroglie): adjacency, **border**, **fixed**, **path/connected/loop/acyclic**, **count**, **max-consecutive**, **mirror/symmetry**, **separation** — each a distinct rule type in the editor.
5. **Live propagation preview** (Stålberg EPC2018): render un-collapsed cells as fuzzy boxes sized by entropy; when the author edits a rule, animate the re-collapse so they *see* the effect. Show the **red contradiction cell** (Tessera) at the exact failure location.

## 4. Synthesis — INSTANCE editor: patterns to copy

1. **One click place → local re-collapse → instant result** (Townscaper): placement *is* the generate action; re-solve only the affected neighborhood, not the whole grid; **stage** it (constraint-solve first, decorate after) for responsiveness.
2. **Fixed / pinned tiles as first-class** (mxgmn, DeBroglie, Tessera, AlexeyBond Preconditions API): a pin = an allowed-set of size one at a cell; the solver "seamlessly integrate[s]" pins and fills around them. Pins double as **path anchors** — drop two, let a connectivity constraint fill between (cheaper than a full path constraint).
3. **Backtracking on conflict** (DeBroglie): the moment pins can over-constrain, the solver must "roll back the most recent tile placement and try another" — not fail-soft-report. This is the biggest gap vs our current handler.
4. **Contradiction made visible** (Tessera): if a pin makes the grid unsatisfiable, show the red contradiction cell + the white "not-yet-generated" cells so the user knows *which pin* to move.

---

## 5. TOP PATTERN TO COPY

**Build the instance editor around Townscaper's "one-click place → local constrained re-collapse around pinned tiles" loop, backed by DeBroglie-style backtracking, and model the rule editor on Godot's TileSet Terrains 3×3 peering-bit paint UI.**

Rationale: the instance editor is where Liam's spec is most differentiated and most valuable (place a tile, watch it resolve around you), and Townscaper proves the interaction is delightful and shippable — but it is only delightful *with backtracking* (DeBroglie), because a pin that over-constrains must roll back and retry rather than silently contradict. That single loop (pin → re-solve neighborhood → backtrack on conflict → show red cell on failure) is the highest-value thing to implement first; it exercises the pin data shape, the incremental solve, and the failure UX all at once. The rule editor's peering-bit paint model (Godot Terrains) is the companion visual we already have expertise in and can even bootstrap a ruleset from. Everything else (learn-by-example, side-label painting, the full DeBroglie constraint palette) layers on afterward.

---

## 6. Mapping to our node system

Everything is a NODE wired as DATA (node-wiring simplicity law), so both surfaces are canvases of wired nodes, not bespoke widgets:

- **Tiles → nodes.** Each tile (from the parts catalog / ingested kits) is a node on the canvas carrying its geometry/handle + its side-labels.
- **Adjacency rules → edges/wired data.** A "may sit next to" rule is a typed **edge** between two tile-nodes (direction/axis as edge data), or an edge-typed **side-label** shared across faces (Tessera's paint model expressed as wires). Higher-order constraints (border, path, count, fixed) are **rule-nodes** wired into the ruleset — matching DeBroglie's taxonomy as node types.
- **Instance placement → nodes on the GraphEdit canvas.** Placing a tile in the instance editor = dropping a tile-node at a grid cell; a **pin** = that node marked fixed (an allowed-set of one), i.e. the Preconditions-API cell constraint expressed as node state.
- **Re-solve → re-running the WFC Context handler.** The instance/rule DATA is compiled to the existing `params.wfc = { width, height, tiles, adjacency }` (+ new constraint/pin fields) and fed to the `wfc` handler in `godot/primitives/prim_context.gd`; re-solving after a pin = re-running that handler on the affected neighborhood. (Note the handler is currently fail-soft; the instance editor's pin loop is the concrete reason to add backtracking to it — no `prim_wfc` needs inventing, the kernel already exists.)
- **Reuse existing canvas infrastructure.** Build both editors on `godot/editor/graph_panel.gd` (the GraphEdit delegate) rather than a new canvas, and render read-only ruleset/solve views through the Aperture board renderer (`godot/aperture/aperture_board.gd`). The live entropy preview (Stålberg) is a per-cell overlay on the GraphEdit canvas.

---

## How this connects to the existing systems (parts catalog / node-wiring / cross-platform)

This authoring UI is a **pure DATA producer feeding the WFC Context-handler kernel that already exists** — the `wfc` handler in `prim_context.gd` already collapses a grid against a static `{ tiles, adjacency }` ruleset, deterministically and seeded; there is no `prim_wfc` to invent, only an authoring surface that writes the ruleset + pin DATA the kernel consumes (and one kernel upgrade: backtracking, so pinned re-solves can roll back instead of fail-soft-reporting). The **tile vocabulary a WFC solve arranges is the parts catalog + ingested kits** — every catalog part is a candidate tile-node, its side-labels the adjacency alphabet, so the same ingestion that grows the catalog grows what WFC can build. Because rules and pins are authored as **wired nodes/edges on the GraphEdit canvas**, the feature obeys the **node-wiring simplicity law** end-to-end: a rule is data on a wire, a pin is node state, and no capability lives outside the canvas. And because the entire authored artifact is **pure data (tiles, adjacency, constraints, pins) with zero renderer coupling**, it is **engine-neutral and cross-platform by construction** — the same authored ruleset re-solves identically under any renderer delegate (2D TileMap, 3D GridMap, the Aperture board), exactly as the handler's determinism contract (`headless_wfc_test.gd`: "same (ruleset, seed) => identical grid, every run") already guarantees.
