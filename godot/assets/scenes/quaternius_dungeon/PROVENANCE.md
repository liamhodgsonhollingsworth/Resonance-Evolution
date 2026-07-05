# Provenance — Quaternius Modular Dungeon

- **Pack:** Quaternius — LowPoly Modular Dungeon Pack (a.k.a. "Modular Dungeons Pack")
- **Author / creator:** Quaternius (https://quaternius.com)
- **License:** Creative Commons Zero 1.0 Universal (CC0-1.0) — public domain, no attribution required
  - SPDX: `CC0-1.0`
  - Link: https://creativecommons.org/publicdomain/zero/1.0/
- **Download date:** 2026-07-05
- **Status:** VENDORED (27 GLB models — the full bundle)

## Sources

- Creator storefront (itch.io): https://quaternius.itch.io/lowpoly-modular-dungeon-pack
- Creator site: https://quaternius.com/packs/modulardungeon.html
- Downloaded from the poly.pizza mirror bundle (hosts the GLB variant, CC0):
  https://poly.pizza/bundle/Modular-Dungeons-Pack-HaFPqhAp3w
- GLB binaries served from the poly.pizza static CDN:
  `https://static.poly.pizza/<uuid>.glb`

## Method

The Quaternius itch.io page distributes FBX/OBJ/Blend and uses a form-based
download flow not reachable headless via curl. The poly.pizza mirror hosts the
same pack as individual CC0 GLB models. The bundle page lists 27 models, each
with a `/m/<shortid>` page; each page embeds the real CDN URL
`https://static.poly.pizza/<uuid>.glb`. All 27 short-ids were resolved to their
UUIDs and every GLB was downloaded (referer https://poly.pizza/ required — the
CDN 403s otherwise). Only GLB was taken (no FBX/OBJ/Blend). Every file was
verified to begin with the `glTF` binary magic header. Filenames are the model
name in snake_case plus the poly.pizza short-id (the short-id disambiguates the
two "Column" and two "Pedestal" models).

## Files vendored (in ./glb/)

| File | Model name | poly.pizza page |
|------|-----------|-----------------|
| sword_wall_mount_3LyJaWgoJG.glb | Sword Wall Mount | https://poly.pizza/m/3LyJaWgoJG |
| floor_tile_6baBuVGcyD.glb | Floor Tile | https://poly.pizza/m/6baBuVGcyD |
| column_6y1EFzpRI9.glb | Column | https://poly.pizza/m/6y1EFzpRI9 |
| bucket_83obI9bNun.glb | Bucket | https://poly.pizza/m/83obI9bNun |
| coin_piles_9OWkKczINo.glb | Coin Piles | https://poly.pizza/m/9OWkKczINo |
| horse_statue_AK9CmjFnL6.glb | Horse Statue | https://poly.pizza/m/AK9CmjFnL6 |
| skull_EAsVEJwsv7.glb | Skull | https://poly.pizza/m/EAsVEJwsv7 |
| cobweb_EHYNWew6JK.glb | Cobweb | https://poly.pizza/m/EHYNWew6JK |
| torch_Gq38E7hFZw.glb | Torch | https://poly.pizza/m/Gq38E7hFZw |
| table_big_KWaAZIDK9F.glb | Table Big | https://poly.pizza/m/KWaAZIDK9F |
| arch_door_MVVMLXOfg1.glb | Arch Door | https://poly.pizza/m/MVVMLXOfg1 |
| chest_O72u4Drp8k.glb | Chest | https://poly.pizza/m/O72u4Drp8k |
| barrel_ONdghDBByN.glb | Barrel | https://poly.pizza/m/ONdghDBByN |
| trap_door_PALqVBff9b.glb | Trap Door | https://poly.pizza/m/PALqVBff9b |
| arch_QwWdOcNIMh.glb | Arch | https://poly.pizza/m/QwWdOcNIMh |
| crate_SfJtdV8GDr.glb | Crate | https://poly.pizza/m/SfJtdV8GDr |
| bricks_Tvlvh8AAbs.glb | Bricks | https://poly.pizza/m/Tvlvh8AAbs |
| pedestal_VE1kTjVgJf.glb | Pedestal | https://poly.pizza/m/VE1kTjVgJf |
| banner_wall_dQjx8fBjIl.glb | Banner Wall | https://poly.pizza/m/dQjx8fBjIl |
| chest_with_gold_haqf9qoiOG.glb | Chest with Gold | https://poly.pizza/m/haqf9qoiOG |
| coin_bag_iUpWtNWXI7.glb | Coin Bag | https://poly.pizza/m/iUpWtNWXI7 |
| wall_modular_itasw0GWNf.glb | Wall Modular | https://poly.pizza/m/itasw0GWNf |
| small_table_rAEBvfb1FT.glb | Small Table | https://poly.pizza/m/rAEBvfb1FT |
| banner_svYG8KZxjq.glb | Banner | https://poly.pizza/m/svYG8KZxjq |
| column_wLubNpOTX4.glb | Column | https://poly.pizza/m/wLubNpOTX4 |
| pedestal_wUeoDKnFBF.glb | Pedestal | https://poly.pizza/m/wUeoDKnFBF |
| chair_zMmKNm8w4a.glb | Chair | https://poly.pizza/m/zMmKNm8w4a |

Total: 27 files, ~3.1 MB.
