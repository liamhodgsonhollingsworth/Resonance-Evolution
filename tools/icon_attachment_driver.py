"""
icon_attachment_driver.py — Tool T5 of brief 03 commit 4.

Drives the icon-attach + revert flow per the per-module plan's
Scenario 5 (*"Icon attach + revert"*) and brief 03 Q5 verbatim
(*"Drag an image onto a node — what changes in the receiving node's
data? Right-click → remove icon — what reverts?"*).

The driver is the runtime helper the seed interaction-rule
``image_onto_any`` references via its ``effect.node_id =
attach_image_as_icon`` field. Two functions cover the forward + inverse
directions:

  - :func:`attach_image_as_icon` — given a target node-id + an image
    node-id, publish a NEW supersession of the target with
    ``icon: image:<image-node-id>`` set on its frontmatter. The
    target's pre-attach version stays reachable per the append-only
    invariant (SPEC-084).
  - :func:`remove_icon_action` — the inverse. Publishes another
    supersession of the target with ``icon`` REMOVED.

The CLI form lets a session drive the flow manually for verification:

  python tools/icon_attachment_driver.py <target_node_id> <image_node_id>
  python tools/icon_attachment_driver.py <target_node_id> --remove

Both commands print the resulting supersession chain (pre + post ids)
so the operator can confirm the new node id + verify the on-disk
artifact.

Composition contract (per existing-primitives audit + mistake #009):

  - ``Alethea-cc/substrate/primitives.publish`` — the canonical
    content-addressed publish. Driver does NOT re-implement
    publish-time validation; it constructs the post-supersession dict
    and hands it to publish().
  - ``Alethea-cc/substrate/toolbox.read_node_by_id`` — read the
    pre-attach target node by id.
  - ``Alethea-cc/substrate/evaluator.compute_id`` — content-addressed
    id (called inside publish; driver doesn't compute directly).

The driver discovers the Alethea-cc/substrate path by walking upward
from this file to the Apeiron root, then locating the sibling
``Alethea`` repo. The path is read from the ALETHEA_CC_SUBSTRATE
environment variable when set, so tests + cross-repo scripts can point
at a temporary nodes directory.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Any, Dict, Optional


def _resolve_substrate_dir() -> Path:
    """Resolve the Alethea-cc/substrate path.

    Priority:
      1. ``ALETHEA_CC_SUBSTRATE`` env var (used by tests).
      2. ``../Alethea/Alethea-cc/substrate`` relative to Apeiron root.
    """
    env = os.environ.get("ALETHEA_CC_SUBSTRATE")
    if env:
        return Path(env)
    here = Path(__file__).resolve()
    apeiron_root = here.parent.parent  # Apeiron/
    desktop_root = apeiron_root.parent  # Desktop/
    candidate = desktop_root / "Alethea" / "Alethea-cc" / "substrate"
    return candidate


def _ensure_substrate_importable() -> Path:
    substrate_dir = _resolve_substrate_dir()
    if not substrate_dir.exists():
        raise FileNotFoundError(
            f"Alethea-cc/substrate not found at {substrate_dir}. Set "
            f"ALETHEA_CC_SUBSTRATE to point at the directory."
        )
    if str(substrate_dir) not in sys.path:
        sys.path.insert(0, str(substrate_dir))
    return substrate_dir


def _nodes_dir(substrate_dir: Path) -> Path:
    env = os.environ.get("ALETHEA_CC_NODES_DIR")
    if env:
        return Path(env)
    return substrate_dir / "nodes"


def _format_icon_ref(image_node_id: str) -> str:
    """Format the icon reference per Q5: ``image:<image-node-id>``.

    Per per-module plan Q5: *"icon: image:<image_node_id> or
    icon: file:<image_path> for file-backed images"*. Phase-1 here
    handles the node-id form; the file-backed variant is a follow-up
    when the file-only ImageNode flow is wired.
    """
    if not isinstance(image_node_id, str) or not image_node_id:
        raise ValueError("image_node_id must be a non-empty string")
    if image_node_id.startswith("image:"):
        # Idempotent — accept already-prefixed inputs (so callers can
        # re-pass the icon field without double-prefixing).
        return image_node_id
    return f"image:{image_node_id}"


def attach_image_as_icon(
    target_node_id: str,
    image_node_id: str,
    nodes_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    """Attach the image as the target node's icon — publishes a new
    supersession with ``icon: image:<image-id>`` on its frontmatter.

    Returns a dict with keys:
      - ``previous_id`` — the pre-attach target's id.
      - ``new_id`` — the post-attach target's content-addressed id.
      - ``icon_ref`` — the ``image:<id>`` reference written.

    Idempotent against re-attachment of the same icon: when the target
    already has ``icon == icon_ref``, the function returns the existing
    id without re-publishing (the substrate's publish is content-
    addressed and would short-circuit anyway, but explicit detection
    keeps the chain clean).

    Cycle guard: refuses to attach if ``image_node_id == target_node_id``
    (a node cannot be its own icon).
    """
    substrate_dir = _ensure_substrate_importable()
    from primitives import publish  # noqa: E402  (import-after-sys.path)
    from toolbox import read_node_by_id  # noqa: E402

    if not isinstance(target_node_id, str) or not target_node_id:
        raise ValueError("target_node_id must be a non-empty string")
    if not isinstance(image_node_id, str) or not image_node_id:
        raise ValueError("image_node_id must be a non-empty string")
    if image_node_id == target_node_id:
        raise ValueError(
            "attach_image_as_icon: a node cannot be its own icon "
            f"(both id = {target_node_id!r})"
        )

    dir_path = nodes_dir if nodes_dir is not None else _nodes_dir(substrate_dir)
    target = read_node_by_id(target_node_id, nodes_dir=dir_path)
    icon_ref = _format_icon_ref(image_node_id)

    # Idempotency: already attached to the same image → no-op.
    if target.get("icon") == icon_ref:
        return {
            "previous_id": target_node_id,
            "new_id": target_node_id,
            "icon_ref": icon_ref,
            "noop": True,
        }

    # Build the post-attach supersession. Strip the old id so publish
    # computes a fresh content-addressed id; set supersedes to capture
    # the lineage per SPEC-084.
    new_node = dict(target)
    new_node.pop("id", None)
    new_node["icon"] = icon_ref
    new_node["supersedes"] = target_node_id

    published = publish(new_node, nodes_dir=dir_path)
    return {
        "previous_id": target_node_id,
        "new_id": published["id"],
        "icon_ref": icon_ref,
        "noop": False,
    }


def remove_icon_action(
    target_node_id: str,
    nodes_dir: Optional[Path] = None,
) -> Dict[str, Any]:
    """Remove the icon from the target node — publishes a new
    supersession with the ``icon`` field absent.

    Returns a dict mirroring :func:`attach_image_as_icon`:
      - ``previous_id`` — the pre-remove target's id.
      - ``new_id`` — the post-remove target's id.
      - ``removed_icon_ref`` — the value of ``icon`` before removal
        (or ``""`` when the target had no icon).

    Idempotent: when the target already has no ``icon``, returns
    without publishing.
    """
    substrate_dir = _ensure_substrate_importable()
    from primitives import publish  # noqa: E402
    from toolbox import read_node_by_id  # noqa: E402

    if not isinstance(target_node_id, str) or not target_node_id:
        raise ValueError("target_node_id must be a non-empty string")

    dir_path = nodes_dir if nodes_dir is not None else _nodes_dir(substrate_dir)
    target = read_node_by_id(target_node_id, nodes_dir=dir_path)
    previous_icon = target.get("icon") or ""

    if not previous_icon:
        return {
            "previous_id": target_node_id,
            "new_id": target_node_id,
            "removed_icon_ref": "",
            "noop": True,
        }

    new_node = dict(target)
    new_node.pop("id", None)
    new_node.pop("icon", None)
    new_node["supersedes"] = target_node_id

    published = publish(new_node, nodes_dir=dir_path)
    return {
        "previous_id": target_node_id,
        "new_id": published["id"],
        "removed_icon_ref": previous_icon,
        "noop": False,
    }


def _main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="icon_attachment_driver",
        description=(
            "Drive the icon-attach + revert flow for brief 03 commit 4 "
            "Scenario 5. Composes against the Alethea-cc substrate "
            "publish + read primitives."
        ),
    )
    parser.add_argument("target_node_id",
                        help="Substrate id of the target node (icon receiver).")
    parser.add_argument("image_node_id", nargs="?", default=None,
                        help="Substrate id of the ImageNode to attach (omit "
                             "with --remove).")
    parser.add_argument("--remove", action="store_true",
                        help="Remove the icon from the target node (inverse "
                             "operation).")
    args = parser.parse_args(argv)

    try:
        if args.remove:
            result = remove_icon_action(args.target_node_id)
        else:
            if not args.image_node_id:
                parser.error("image_node_id is required unless --remove is set")
            result = attach_image_as_icon(args.target_node_id, args.image_node_id)
    except (FileNotFoundError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(_main())
