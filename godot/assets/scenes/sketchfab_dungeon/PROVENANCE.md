# Provenance — Sketchfab pre-assembled dungeon environment (CC-BY 4.0)

- **Status:** FAILED (attribution recorded, file NOT vendored)
- **Reason:** Sketchfab model downloads require an authenticated login/OAuth
  session. The download endpoint is gated and returns HTTP 401
  ("Authentication credentials were not provided") when requested headless via
  curl, so no GLB could be vendored. This is the expected outcome for Sketchfab.
- **Download date (attribution recorded):** 2026-07-05

## Identified model (attribution recorded)

- **Title:** Low-Poly Dungeon – Game-Ready 3D Environment
- **Author / creator:** Chandan-kr
- **Author profile:** https://sketchfab.com/Chandan-kr
- **Model URL:** https://sketchfab.com/3d-models/low-poly-dungeon-game-ready-3d-environment-786b756ee34d4841988426d1e7477ac4
- **License:** Creative Commons Attribution 4.0 International (CC BY 4.0)
  - SPDX: `CC-BY-4.0`
  - Link: https://creativecommons.org/licenses/by/4.0/
  - ATTRIBUTION IS MANDATORY. See ATTRIBUTION.txt for the required credit line.
- This is a *pre-assembled* dungeon environment (modular corridors, treasure
  rooms, lighting) rather than a loose parts kit — chosen to match the
  "pre-assembled dungeon environment" brief.

## Verification performed

- Fetched the model page (HTTP 200) and confirmed the license link
  `creativecommons.org/licenses/by/4.0` and the author "Chandan-kr" (og:title +
  profile path `sketchfab.com/Chandan-kr`).
- Confirmed the download is gated: `GET https://sketchfab.com/i/models/<uid>/download`
  returned HTTP 401 "Authentication credentials were not provided."

## Other CC-BY / CC0 candidates identified (not downloaded)

Recorded in case a different model is preferred. Verify each model's own license
badge on its page before use (licenses vary per model):

- Free Modular Low Poly Dungeon Pack — RgsDev (reported CC0)
  https://sketchfab.com/3d-models/free-modular-low-poly-dungeon-pack-31f2e88017574702bb2c1c1e286dc747
- Low-poly Game Assets: Modular Dungeon Pack — Brid Jagtap (@BridJagtap)
  https://sketchfab.com/3d-models/low-poly-game-assets-modular-dungeon-pack-762bc000234c4e8f83e6c13f72113cae
- Low Poly Modular Dungeon — Vesleii
  https://sketchfab.com/3d-models/low-poly-modular-dungeon-389b688c710e4bb7be8817d06575c8f4
- Low Poly Dungeon Pack — Dandushik
  https://sketchfab.com/3d-models/low-poly-dungeon-pack-69649dfd328a4799b3d9c419ce0fb129

## Files vendored

None. The `glb/` directory is intentionally empty. To vendor this model, log in
to Sketchfab, download the GLB manually, place it in `glb/`, and keep
ATTRIBUTION.txt alongside it (CC BY 4.0 requires the credit to travel with the
asset).
