#!/usr/bin/env python3
"""Generate godot/assets/manifest.json — the ONE index of every 3D asset imported anywhere
in this repo, so the sandbox can offer ALL of them without loading ANY at startup.

Spec (Liam, card apx_e5c6f8dc, 2026-07-03): the sandbox "should include not just the assets
that you loaded there but also the other ones that were found and imported for other
experiments" and must "be efficient for having any number of assets by not having them
loaded when the game starts up and instead loading them when they are needed."

The manifest is the lazy-loading substrate: a tiny JSON the sandbox reads at startup
(id / path / kit / tags per asset — NO geometry), so startup cost is O(manifest bytes),
never O(asset bytes). Actual GLB loads happen on demand in godot/runtime/asset_library.gd.

Sources scanned (everything already imported into the repo, per the spec line above):
  * godot/assets/vendor/**/*.glb          — every vendor-kit model (Kenney, Quaternius, ...)
  * godot/assets/ingested/*.scene_node.json — the ingest-kit tool's per-asset descriptors
    (used to enrich entries with the ingested display name when present)

Deterministic + idempotent: same tree in -> byte-identical manifest out (sorted, ASCII,
stable key order), so re-running never produces git churn. Run from the repo root:

    py -3 scripts/gen_asset_manifest.py [--check]

--check verifies the committed manifest matches a fresh scan (exit 1 on drift) without
writing — the headless test suite shells out to this to keep the manifest honest.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
GODOT = REPO / "godot"
VENDOR = GODOT / "assets" / "vendor"
INGESTED = GODOT / "assets" / "ingested"
OUT = GODOT / "assets" / "manifest.json"

# Words too generic to be useful search tags.
_STOP = {"free", "model", "by", "the", "a", "an", "of"}


def _tags_from_name(name: str) -> list[str]:
    """Human-searchable tags from an asset's name tokens (drop noise + random suffixes)."""
    toks = re.split(r"[^a-z0-9]+", name.lower())
    tags = []
    for t in toks:
        if not t or t in _STOP:
            continue
        # Drop the 10-char random suffixes Quaternius downloads carry (e.g. '699sfulcn2').
        if len(t) >= 8 and re.search(r"\d", t) and re.search(r"[a-z]", t):
            continue
        if t.isdigit():
            continue
        if t not in tags:
            tags.append(t)
    return tags


def _ingested_name(asset_id: str) -> str | None:
    p = INGESTED / f"{asset_id}.scene_node.json"
    if not p.is_file():
        return None
    try:
        data = json.loads(p.read_text(encoding="utf-8"))
        name = data.get("name")
        return str(name) if name else None
    except (json.JSONDecodeError, OSError):
        return None


def build_manifest() -> dict:
    assets = []
    if VENDOR.is_dir():
        for glb in sorted(VENDOR.rglob("*.glb")):
            rel = glb.relative_to(GODOT).as_posix()
            asset_id = glb.stem
            kit = glb.parent.name  # vendor/<kit>/<file>.glb
            name = _ingested_name(asset_id)
            if name is None:
                # e.g. 'kenney_nature__bed' -> 'bed'
                name = asset_id.split("__", 1)[-1]
            scene_node = INGESTED / f"{asset_id}.scene_node.json"
            entry = {
                "id": asset_id,
                "name": name,
                "path": f"res://{rel}",
                "type": "glb",
                "kit": kit,
                "tags": _tags_from_name(name) or _tags_from_name(asset_id),
            }
            if scene_node.is_file():
                entry["scene_node"] = f"res://{scene_node.relative_to(GODOT).as_posix()}"
            assets.append(entry)
    kits = sorted({a["kit"] for a in assets})
    return {
        "format": "resonance.asset_manifest/v1",
        "description": (
            "Index of every 3D asset imported anywhere in this repo. Read by the sandbox "
            "at startup (metadata only); geometry loads lazily on demand via "
            "godot/runtime/asset_library.gd. Regenerate: py -3 scripts/gen_asset_manifest.py"
        ),
        "kits": kits,
        "assets": assets,
    }


def render(manifest: dict) -> str:
    return json.dumps(manifest, indent=2, ensure_ascii=True, sort_keys=False) + "\n"


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--check", action="store_true",
                    help="verify the committed manifest matches a fresh scan; write nothing")
    args = ap.parse_args()

    manifest = build_manifest()
    text = render(manifest)
    if args.check:
        current = OUT.read_text(encoding="utf-8") if OUT.is_file() else ""
        if current != text:
            print(f"DRIFT: {OUT} does not match a fresh scan "
                  f"({len(manifest['assets'])} assets found). Re-run without --check.")
            return 1
        print(f"ok: manifest matches ({len(manifest['assets'])} assets, "
              f"{len(manifest['kits'])} kits)")
        return 0
    OUT.write_text(text, encoding="utf-8", newline="\n")
    print(f"wrote {OUT} ({len(manifest['assets'])} assets, kits: {', '.join(manifest['kits'])})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
