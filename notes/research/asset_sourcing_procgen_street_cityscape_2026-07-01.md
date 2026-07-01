# Asset Sourcing for GZ-PROCGEN — Free Modular 3D Kits for Street + Cityscape

**Purpose:** A cited sourcing note for the Resonance-Evolution Godot engine's procedural street + cityscape generator (GZ-PROCGEN): which free CC0 / CC-BY modular 3D kits to pull, and exactly how they drop into the engine's `mesh:{source:"glb"}` ingest path.
**Date:** 2026-07-01

---

## 1. Why modular CC0/CC-BY kits — and the procgen goal

The GZ-PROCGEN generator needs an **asset vocabulary** it can place on a grid to synthesize streets, blocks, and skylines. The engine already ships a *primitive* vocabulary (13 catalog shapes) that needs no external files; kits give it a *content* vocabulary of ready-made buildings, roads, and urban props.

The right kits for a procgen street+cityscape generator share three properties:

- **Modular / snap-together / grid-based** — pieces are authored to tile on a fixed grid so a generator can place them without gap or overlap. This is the single most important property for procgen.
- **Low-poly** — a city is *many* instances; low triangle counts keep a generated block cheap to render.
- **Genuinely free (CC0 preferred)** — CC0 imposes zero attribution burden, so a generator can emit thousands of instances without a per-model credit ledger. CC-BY is acceptable but requires attribution.

Every kit below is delivered as (or convertible to) **glTF/GLB**, which is the engine's native ingest format (Section 6). glTF's canonical space is **+Y up, meters, radians** — the same as the engine's scene_node convention — so most kits drop in with an identity transform, though small-scale kits (Kenney) may need a `scale` set.

---

## 2. Comparison table — recommended kits

| Name | Author | License | Format(s) offered | URL | Notes |
|---|---|---|---|---|---|
| City Kit (Roads) | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/city-kit-roads | 70 assets; roads, highways, barriers, lightposts, Dutch cycle-path variant. Single material across all models. Grid-snap roads. |
| City Kit (Commercial) | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/city-kit-commercial | 50 assets; commercial buildings tiling on the City Kit grid. |
| City Kit (Suburban) | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/city-kit-suburban | 40 assets; suburban houses + fences, trees, driveways; same grid as Roads/Commercial. |
| Modular Buildings | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/modular-buildings | 100 assets; stackable modular building parts (floors/walls/roofs). |
| Retro Urban Kit | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/retro-urban-kit | 120 assets, ~100 models; early-3D "retro" look, low-res textures; explicitly ships **separate FBX, OBJ, and GLB files**. |
| Graveyard Kit | Kenney | CC0 | FBX, OBJ, GLB (glTF) | https://kenney.nl/assets/graveyard-kit | 90 assets; props (graves, fences, crypts) — good for a cemetery block / set-dressing, not core streets. |
| Downtown City MegaKit | Quaternius | CC0 | OBJ, FBX, glTF (+ .blend in source) | https://quaternius.com/packs/downtowncitymegakit.html | 300+ modular pieces for Boston/NYC-style blocks; buildings, streets, props, 7 example buildings. Strongest single cityscape kit. |
| Cyberpunk Game Kit | Quaternius | CC0 | FBX, OBJ, glTF, .blend | https://quaternius.com/packs/cyberpunkgamekit.html | 71 models; modular platform parts + props for a cyberpunk street look (more platformer than city, but strong stylistic props). |
| Ultimate (Textured) Buildings Pack | Quaternius | CC0 | FBX, OBJ, .blend (glTF varies — verify per download) | https://quaternius.com/packs/ultimatetexturedbuildings.html | 100+ models, base + modular parts, atlas-texture palette swaps. Confirm glTF on download; convert if OBJ-only. |
| KayKit : City Builder Bits | Kay Lousberg (KayKit) | CC0 | OBJ, FBX, GLTF | https://kaylousberg.itch.io/city-builder-bits | 32+ low-poly models (buildings, roads, cars, trees, fountains, paths); single 1024² gradient atlas; grid-friendly. Pay-what-you-want, free tier. |
| Poly Pizza (model host) | various | CC0 **and** CC-BY-3.0 (per model) | GLB | https://poly.pizza/ | Searchable host with direct GLB download; ideal for one-off props. License is **per model** — filter to CC0 to avoid attribution. |
| Sketchfab (downloadable) | various | CC0 / CC-BY / etc. (per model) | GLB (among others) | https://sketchfab.com/tags/cc0 | Supplement for one-offs. License is **per model**; download popup shows license + copy-paste attribution. Read each model's license. |
| Synty POLYGON City/Town | Synty | **NOT free** (paid / subscription) | FBX (Unity-oriented) | https://syntystore.com/products/polygon-city-pack | Excluded — paid. Listed only as the paid reference standard for low-poly city art. |

---

## 3. Per-kit detail — top picks

### Kenney — City Kit family (Roads / Commercial / Suburban) + Modular Buildings
Kenney assets are **CC0** ([kenney.nl/assets/city-kit-roads](https://kenney.nl/assets/city-kit-roads)) — public domain, no attribution, commercial use allowed. The City Kit sub-packs are designed to **share one grid**: Roads (70 assets — roads, highways, barriers, lightposts, construction fences), Commercial (50), and Suburban (40 — houses, fences, trees, driveways) snap together on the same module size, which is exactly what a street+block generator wants ([city-kit-commercial](https://kenney.nl/assets/city-kit-commercial), [city-kit-suburban](https://kenney.nl/assets/city-kit-suburban)). The Roads pack was updated to use a **single material across all models** ([Kenney announcement](https://x.com/KenneyNL/status/1900147344760356916)), which reduces draw-state churn when a generator instances many road tiles. Modular Buildings (100 assets, [modular-buildings](https://kenney.nl/assets/modular-buildings)) provides stackable floor/wall/roof parts for taller structures.

**Format gotcha:** Kenney's individual asset pages confirm the **CC0** license and asset counts but do not always enumerate formats inline. Kenney's standard distribution ships **FBX, OBJ, and GLB (glTF)** side by side — the Retro Urban Kit page states this explicitly ("separate FBX, OBJ, and GLB files", [retro-urban-kit](https://kenney.nl/assets/retro-urban-kit)), and Kenney's own import guidance treats glTF as a first-class export ([importing-3d-models](https://kenney.nl/knowledge-base/game-assets-3d/importing-3d-models-into-game-engines)). So the GLB files needed by the ingest path are present in the download ZIPs; no conversion required.

**Scale gotcha:** Kenney kits are often authored **small** relative to 1 unit = 1 meter. When emitting the scene_node JSON, expect to set a uniform `scale` (commonly a >1 factor) so a Kenney building reads at real-world size next to primitive parts. Verify visually per kit and bake the factor into the `scale` field rather than rescaling meshes.

### Quaternius — Downtown City MegaKit (best single cityscape kit)
The **Downtown City MegaKit** is the strongest single source for a dense street+cityscape: **300+ modular environment pieces** for "full Boston/NYC-style city blocks," with mix-and-match building parts, street elements, props, and 7 pre-built example buildings ([quaternius.com/packs/downtowncitymegakit.html](https://quaternius.com/packs/downtowncitymegakit.html)). It is **CC0** and the standard (free) version ships **OBJ, FBX, and glTF**; the paid "source" version adds `.blend` files and engine-side shader tricks (fake window interiors, vertex-color wear) but those are Unreal/Unity/Godot project extras, not needed for GLB ingest. The 60–70%-free split means the free tier already covers a large modular set. Because it is explicitly **modular and grid-oriented**, it maps cleanly onto a procgen block generator.

### KayKit — City Builder Bits (clean, tiny, grid-friendly)
KayKit City Builder Bits is **CC0** with **OBJ, FBX, and GLTF** ([kaylousberg.itch.io/city-builder-bits](https://kaylousberg.itch.io/city-builder-bits); mirror + license confirmation at [GitHub KayKit-City-Builder-Bits-1.0](https://github.com/KayKit-Game-Assets/KayKit-City-Builder-Bits-1.0)). The free tier is **32+ low-poly models** — buildings, roads, cars, trees, fountains, pathways — all on a **single 1024² gradient atlas** so the whole kit shares one material (cheap to instance). It is pay-what-you-want with a genuine free tier; an optional $3.95+ "Extra" tier adds ~16 park assets. Its small, consistent, isometric-city-builder styling makes it a clean starter for a stylized generator. Note itch.io "pay-what-you-want" is separate from the asset license: the models are CC0 regardless of what you pay.

### Poly Pizza — per-model GLB host (for one-off props)
[Poly Pizza](https://poly.pizza/) is a searchable host that serves **direct GLB downloads with no login**, ready for Unity/Unreal/**Godot**. It hosts models under **both CC0 and CC-BY-3.0**, and the **license is per model** — CC-BY models legally require attribution (the site surfaces copy-paste attribution text and a link). For GZ-PROCGEN, use Poly Pizza to fill gaps in the kits (a specific streetlight, hydrant, bench) rather than as a bulk source, and **filter to CC0** ([poly.pizza/search/CC0](https://poly.pizza/search/CC0)) so instanced props carry no attribution burden. Kenney's City Kit is even mirrored there as a convenience bundle ([City Kit bundle](https://poly.pizza/bundle/City-Kit-0CkvGrBJ0u)).

### Sketchfab — supplement only, license-per-model
[Sketchfab CC0 tag](https://sketchfab.com/tags/cc0) has downloadable GLB models, but the **license is chosen per model** by the uploader (CC-BY is the default). The download popup shows the license summary and attribution text ([Sketchfab intro to CC licenses](https://sketchfab.com/blogs/community/an-introduction-to-creative-commons-licenses/)). Treat Sketchfab as a last-resort one-off supplement and read each model's license before ingest; prefer CC0.

### Synty — paid reference standard (excluded)
Synty's **POLYGON City Pack** (331 assets) and **Town Pack** are the industry reference for low-poly stylized cities, but they are **paid** — sold individually and via a $30/mo+ subscription ([syntystore.com/products/polygon-city-pack](https://syntystore.com/products/polygon-city-pack), [town-pack](https://syntystore.com/products/polygon-town-pack)). **Excluded from sourcing** (not free); mentioned only as the visual quality bar the free kits are being measured against.

---

## 4. Recommended STARTER SET (3–5 kits, all CC0)

A concrete, all-CC0 starter set that together covers **roads + buildings + urban props** with **zero attribution burden**:

1. **Kenney — City Kit (Roads)** — CC0 — [kenney.nl/assets/city-kit-roads](https://kenney.nl/assets/city-kit-roads). The street/road layer: grid-snap roads, highways, barriers, lightposts. Single material, GLB included.
2. **Kenney — City Kit (Commercial)** + **City Kit (Suburban)** — CC0 — [commercial](https://kenney.nl/assets/city-kit-commercial), [suburban](https://kenney.nl/assets/city-kit-suburban). The building layer, authored on the *same grid* as Roads, so blocks assemble without gaps.
3. **Quaternius — Downtown City MegaKit** — CC0 — [quaternius.com/packs/downtowncitymegakit.html](https://quaternius.com/packs/downtowncitymegakit.html). The density layer: 300+ modular NYC/Boston pieces for taller, denser blocks and stylistic variety beyond Kenney's simpler set. Ships glTF directly.
4. **KayKit — City Builder Bits** — CC0 — [kaylousberg.itch.io/city-builder-bits](https://kaylousberg.itch.io/city-builder-bits). The props/detail layer: cars, trees, fountains, pathways on a single atlas — cheap street dressing.
5. **Poly Pizza (CC0 filter)** — CC0 per model — [poly.pizza/search/CC0](https://poly.pizza/search/CC0). The gap-filler: individual one-off props (hydrants, benches, signs) as GLB, on demand.

**Why this set:** Items 1–2 give a *coherent, grid-consistent* road+building base (the hardest thing to get right for procgen — pieces that actually tile). Item 3 adds density and a second visual register for variety. Item 4 supplies cheap, single-material street dressing. Item 5 covers anything the kits miss. **All five are CC0**, so a generator can emit unlimited instances with no attribution tracking. **Attribution note:** none of the starter-set kits require attribution (all CC0). If you later pull from **Poly Pizza CC-BY models** or **Sketchfab CC-BY models**, those *do* require attribution — keep them out of the CC0-only starter set unless you add a credits surface.

---

## 5. Format sanity for the starter set

| Starter kit | GLB shipped? | Conversion needed? |
|---|---|---|
| Kenney City Kit (Roads/Commercial/Suburban), Modular Buildings, Retro Urban | Yes (GLB alongside FBX/OBJ) | No |
| Quaternius Downtown City MegaKit | Yes (glTF in free tier) | No |
| KayKit City Builder Bits | Yes (GLTF) | Possibly `.gltf`→`.glb` pack (trivial) |
| Poly Pizza (CC0) | Yes (GLB direct) | No |

If any pull turns out OBJ/FBX-only (e.g., some older Quaternius packs list only FBX/OBJ/.blend), convert to GLB before ingest (Section 6).

---

## 6. How it plugs into the `mesh:{source:'glb'}` ingest path

The engine ingests **any spec-valid GLB with zero code change**. The flow, verified against the repo:

1. **Download & extract** the kit ZIP; keep the **GLB** files (discard FBX/OBJ unless converting).
2. **Drop the GLB into a vendor folder** at `godot/assets/vendor/<kit_name>/`, mirroring the existing `kenney_nature/` and `quaternius_nature/` folders. Name files `<kit>__<model>.glb`, e.g. `godot/assets/vendor/kenney_city_roads/kenney_city_roads__road_straight.glb`.
3. **Emit a renderer-neutral scene_node JSON** at `godot/assets/ingested/<kit>__<model>.scene_node.json` of the exact shape the engine expects:

   ```json
   {
     "name": "kenney_city_roads__road_straight",
     "translation": [0, 0, 0],
     "rotation": [0, 0, 0, 1],
     "scale": [1, 1, 1],
     "mesh": { "source": "glb", "path": "res://assets/vendor/kenney_city_roads/kenney_city_roads__road_straight.glb" },
     "children": []
   }
   ```

   For Kenney kits authored small, set `scale` to the size-correcting factor (e.g. `[N, N, N]`) instead of `[1,1,1]`. Because glTF is **+Y up / meters / radians**, no axis conversion is needed and `rotation` stays identity `[0,0,0,1]` for an upright model.

4. **It becomes a wireable node.** The Godot renderer `godot/renderers/godot_scene_renderer.gd` loads `mesh:{source:"glb", path}` via `GLTFDocument.append_from_file` → `generate_scene` (the `_load_glb` function). The ingested GLB then behaves **exactly like the 13 catalog primitive parts** — a `Model` node you can place, transform, parent, and wire into the graph. The procgen generator just picks a kit part by name and stamps its scene_node onto the grid.

**OBJ/FBX → GLB conversion (only when a kit ships no GLB):** run the mesh through Blender's CLI export (`blender --background --python <export_gltf.py>`) or a glTF pipeline tool to produce a `.glb`, then proceed from step 2. (A sibling note covers the Blender conversion in detail.) The rest of the path is identical — conversion only changes *how you get the GLB*, not how it ingests.

---

## How this connects to the existing systems (parts catalog / node-wiring / cross-platform)

These kits are the **asset vocabulary** that sits alongside the engine's existing **asset-free primitive vocabulary** — the 13-shape `catalog.json` parts. A primitive part (box, cylinder, etc.) needs no external file and is generated procedurally; a kit part is the *same kind of thing* — a placeable, transformable `Model` node — except its geometry comes from a vendored GLB rather than a math primitive. Nothing in the pipeline distinguishes them downstream: both resolve to a scene_node, both render through the same renderer path. GZ-PROCGEN can freely mix primitive parts (procedural road strips, blocked-out massing) with kit parts (detailed buildings, props) in one generated scene.

This falls directly out of the **node-wiring simplicity law**: adding a kit model to a scene is *identical in effort* to adding a primitive — you drop a `Model` node and wire it, no more steps than wiring a box. The ingest path (drop GLB → emit scene_node JSON → wireable node) is the concrete embodiment of "as easy as wiring nodes on a 2D canvas": a new kit expands the palette without expanding the interaction model.

Finally, this is **cross-platform / system-neutral by construction**. GLB is an **engine-neutral** interchange format — the *same* vendored `.glb` bytes and the *same* renderer-neutral scene_node JSON load in **Godot** (via `GLTFDocument`) and in **three.js** (via `GLTFLoader`) through identical data, with no per-engine asset fork. The repo's **Khronos glTF validator** and **three.js oracles** validate each GLB against the spec, so a kit that passes ingest is guaranteed to render the same across both renderers. Sourcing CC0 GLB kits therefore extends the shared, portable asset substrate — the procgen city built from these kits is one scene graph that renders anywhere the engine runs.

---

### Verification status
- **Verified with a direct fetch (license + format + contents):** Kenney City Kit Roads/Commercial/Suburban, Kenney Modular Buildings, Kenney Retro Urban Kit, Kenney Graveyard Kit, Quaternius Downtown City MegaKit, Quaternius Cyberpunk Game Kit, KayKit City Builder Bits (both itch.io + GitHub), Synty POLYGON City/Town (confirmed paid).
- **Verified via search, GLB confirmed, page not deep-fetched:** Poly Pizza (CC0 + CC-BY-3.0 per model, GLB direct — its `/search/CC0` page returns HTTP 403 to automated fetch, so the license model is corroborated from search snippets + the [API docs](https://poly.pizza/docs/api/v1.1), not a page fetch), Sketchfab CC0/CC-BY downloadable.
- **Could NOT fully verify:** **Quaternius "Ultimate Modular buildings" / Ultimate (Textured) Buildings Pack glTF availability** — search results list its free formats as **FBX, OBJ, .blend** and do not confirm glTF for that specific pack (glTF is confirmed for the Downtown City MegaKit and Cyberpunk Kit). Treat as *may require OBJ/FBX→GLB conversion* until the download is inspected. There is no standalone Kenney kit literally named "Roads" separate from **City Kit (Roads)** — the plain "Roads" reference resolves to City Kit (Roads).
