# Provenance — KayKit Dungeon Remastered

- **Pack:** KayKit — Dungeon Remastered (1.0)
- **Author / creator:** Kay Lousberg (https://www.kaylousberg.com)
- **License:** Creative Commons Zero 1.0 Universal (CC0-1.0) — public domain, no attribution required
  - SPDX: `CC0-1.0`
  - Link: https://creativecommons.org/publicdomain/zero/1.0/
- **Download date:** 2026-07-05
- **Status:** VENDORED (14 GLB pieces)

## Sources

- Primary (itch.io storefront): https://kaylousberg.itch.io/kaykit-dungeon-remastered
- Downloaded from the official GitHub mirror published by the creator's org:
  https://github.com/KayKit-Game-Assets/KayKit-Dungeon-Remastered-1.0
- Raw file base used for downloads:
  `https://raw.githubusercontent.com/KayKit-Game-Assets/KayKit-Dungeon-Remastered-1.0/main/addons/kaykit_dungeon_remastered/Assets/gltf/`

## Method

The itch.io storefront uses a form-based download flow that is not reachable
headless via curl. Instead, the assets were vendored from the creator's own
official GitHub mirror (`KayKit-Game-Assets` org), which hosts the full pack —
over 200 GLB models — under `addons/.../Assets/gltf/`. A representative subset of
14 modular dungeon pieces (walls, floor tiles, a column, stairs, and props) was
selected to keep the vendored size small. Only the `gltf/` (GLB binary) variant
was taken; the `fbx/`, `obj/`, and `texture/` folders were skipped (the GLBs are
self-contained — the gradient atlas texture is embedded in each binary).

Every file was verified to begin with the `glTF` binary magic header.

## Files vendored (in ./glb/)

| File | Bytes | Category |
|------|-------|----------|
| wall.gltf.glb | 53132 | wall (straight) |
| wall_corner.gltf.glb | 49212 | wall (corner) |
| wall_doorway_Tsplit.gltf.glb | 93124 | wall (doorway) |
| wall_window_open.gltf.glb | 57256 | wall (window) |
| floor_tile_large.gltf.glb | 28100 | floor |
| floor_tile_small.gltf.glb | 20740 | floor |
| column.gltf.glb | 20260 | structural column |
| stairs.gltf.glb | 43368 | stairs |
| barrel_large.gltf.glb | 44292 | prop (barrel) |
| chest.glb | 81412 | prop (chest) |
| torch_lit.gltf.glb | 31244 | prop (torch) |
| coin_stack_large.gltf.glb | 101076 | prop (loot) |
| banner_red.gltf.glb | 24216 | prop (banner) |
| box_large.gltf.glb | 28740 | prop (box) |

Total: 14 files, ~684 KB.

Note: the upstream repo names most files `<name>.gltf.glb` but a few props
(e.g. the chest) are named `<name>.glb`. Filenames here match upstream exactly.
