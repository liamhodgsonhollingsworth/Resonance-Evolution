"""Tests for the icon_attachment_driver — Tool T5 of brief 03 commit 4.

Covers the forward + inverse icon-attach flow per Scenario 5 of the
per-module plan (*"Icon attach + revert"*) + Q5 of brief 03
(*"Drag an image onto a node — what changes in the receiving node's
data?"*).

The driver composes against the Alethea-cc substrate (publish +
read_node_by_id). Tests use a temporary nodes directory via
ALETHEA_CC_NODES_DIR + ALETHEA_CC_SUBSTRATE env vars so the production
nodes/ store is never touched.

Scope (per per-module plan Scenario 5 + Tool T5):
- attach publishes a new supersession with `icon: image:<id>`.
- The original target node remains reachable (append-only invariant).
- attach is idempotent against re-attachment of the same icon.
- remove publishes another supersession without the `icon` field.
- remove is idempotent on already-no-icon targets.
- Cycle guard: a node cannot be its own icon.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

APEIRON_ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(APEIRON_ROOT))

# Locate the Alethea-cc substrate package once for the test session.
SUBSTRATE_DIR = APEIRON_ROOT.parent / "Alethea" / "Alethea-cc" / "substrate"


@pytest.fixture
def temp_nodes_dir(tmp_path, monkeypatch):
    """Set up a temporary nodes/ directory for the substrate primitives
    + point the driver at it via env vars."""
    nodes_dir = tmp_path / "nodes"
    nodes_dir.mkdir()
    monkeypatch.setenv("ALETHEA_CC_NODES_DIR", str(nodes_dir))
    monkeypatch.setenv("ALETHEA_CC_SUBSTRATE", str(SUBSTRATE_DIR))
    monkeypatch.setenv("ALETHEA_AUTO_NOTION_SYNC", "0")
    if str(SUBSTRATE_DIR) not in sys.path:
        sys.path.insert(0, str(SUBSTRATE_DIR))
    yield nodes_dir


@pytest.fixture
def published_target_and_image(temp_nodes_dir):
    """Publish a minimal target + an ImageNode reference to the temp
    nodes dir. Returns (target_id, image_id, nodes_dir)."""
    from primitives import publish  # type: ignore

    nodes_dir = temp_nodes_dir
    target = {
        "kind": "ButtonNode",
        "name": "test_target_button",
        "body-format": "text",
        "body": "test target button",
    }
    image = {
        "kind": "ImageNode",
        "name": "test_image",
        "body-format": "text",
        "body": "test image reference",
    }
    pt = publish(target, nodes_dir=nodes_dir)
    pi = publish(image, nodes_dir=nodes_dir)
    return pt["id"], pi["id"], nodes_dir


# --------------------------------------------------------------------------
# attach_image_as_icon
# --------------------------------------------------------------------------


def test_attach_publishes_new_supersession(published_target_and_image):
    target_id, image_id, nodes_dir = published_target_and_image
    from tools.icon_attachment_driver import attach_image_as_icon
    from toolbox import read_node_by_id  # type: ignore

    result = attach_image_as_icon(target_id, image_id, nodes_dir=nodes_dir)
    assert result["previous_id"] == target_id
    assert result["new_id"] != target_id  # content changed → new id
    assert result["icon_ref"] == f"image:{image_id}"
    assert result["noop"] is False

    # New node has the icon field set + supersedes the original.
    new_node = read_node_by_id(result["new_id"], nodes_dir=nodes_dir)
    assert new_node.get("icon") == f"image:{image_id}"
    assert new_node.get("supersedes") == target_id

    # Original node remains reachable per append-only.
    pre = read_node_by_id(target_id, nodes_dir=nodes_dir)
    assert pre.get("icon", "") == ""  # original had no icon
    # Both files exist on disk.
    pre_hex = target_id.split(":", 1)[1]
    new_hex = result["new_id"].split(":", 1)[1]
    assert (nodes_dir / f"{pre_hex}.md").exists()
    assert (nodes_dir / f"{new_hex}.md").exists()


def test_attach_idempotent_when_same_icon(published_target_and_image):
    target_id, image_id, nodes_dir = published_target_and_image
    from tools.icon_attachment_driver import attach_image_as_icon

    # First attach — publishes a new supersession.
    first = attach_image_as_icon(target_id, image_id, nodes_dir=nodes_dir)
    new_id = first["new_id"]
    assert first["noop"] is False

    # Re-attach to the SAME post-attach id: no-op.
    second = attach_image_as_icon(new_id, image_id, nodes_dir=nodes_dir)
    assert second["new_id"] == new_id
    assert second["noop"] is True


def test_attach_cycle_guard_rejects_self_reference(temp_nodes_dir):
    from tools.icon_attachment_driver import attach_image_as_icon
    with pytest.raises(ValueError, match="cannot be its own icon"):
        attach_image_as_icon("sha256:dead", "sha256:dead",
                              nodes_dir=temp_nodes_dir)


def test_attach_rejects_empty_ids(temp_nodes_dir):
    from tools.icon_attachment_driver import attach_image_as_icon
    with pytest.raises(ValueError, match="target_node_id"):
        attach_image_as_icon("", "sha256:abc",
                              nodes_dir=temp_nodes_dir)
    with pytest.raises(ValueError, match="image_node_id"):
        attach_image_as_icon("sha256:abc", "",
                              nodes_dir=temp_nodes_dir)


def test_attach_raises_on_missing_target(temp_nodes_dir):
    from tools.icon_attachment_driver import attach_image_as_icon
    with pytest.raises(FileNotFoundError):
        attach_image_as_icon(
            "sha256:0000000000000000000000000000000000000000000000000000000000000000",
            "sha256:1111111111111111111111111111111111111111111111111111111111111111",
            nodes_dir=temp_nodes_dir,
        )


# --------------------------------------------------------------------------
# remove_icon_action
# --------------------------------------------------------------------------


def test_remove_publishes_new_supersession(published_target_and_image):
    target_id, image_id, nodes_dir = published_target_and_image
    from tools.icon_attachment_driver import (
        attach_image_as_icon, remove_icon_action,
    )
    from toolbox import read_node_by_id  # type: ignore

    # Attach first to have something to remove.
    attached = attach_image_as_icon(target_id, image_id, nodes_dir=nodes_dir)
    # Now remove.
    removed = remove_icon_action(attached["new_id"], nodes_dir=nodes_dir)
    assert removed["previous_id"] == attached["new_id"]
    assert removed["new_id"] != attached["new_id"]
    assert removed["removed_icon_ref"] == f"image:{image_id}"
    assert removed["noop"] is False

    # Post-remove node has no icon field + supersedes the attached
    # version.
    final = read_node_by_id(removed["new_id"], nodes_dir=nodes_dir)
    assert "icon" not in final or final.get("icon") in (None, "")
    assert final.get("supersedes") == attached["new_id"]

    # All three versions exist on disk per Scenario 5 acceptance
    # criterion.
    for nid in (target_id, attached["new_id"], removed["new_id"]):
        hex_part = nid.split(":", 1)[1]
        assert (nodes_dir / f"{hex_part}.md").exists()


def test_remove_idempotent_on_no_icon(published_target_and_image):
    target_id, _, nodes_dir = published_target_and_image
    from tools.icon_attachment_driver import remove_icon_action
    result = remove_icon_action(target_id, nodes_dir=nodes_dir)
    assert result["new_id"] == target_id
    assert result["noop"] is True
    assert result["removed_icon_ref"] == ""


# --------------------------------------------------------------------------
# Integration: the seed rule resolves the attach effect-node
# --------------------------------------------------------------------------


def test_seed_rule_dispatches_to_attach_effect(temp_nodes_dir):
    """The seed interaction-rule + its effect-node compose: querying
    `find({by: rule, ...})` returns the rule, and the rule's
    effect.node_id points at an effect-node we can load."""
    from primitives import find, publish

    # Publish minimal effect-node + rule into the temp nodes dir so
    # the discovery query has something to find. (The production seed
    # nodes live in Alethea-cc/substrate/nodes; this test publishes
    # disposable copies into the tmp dir.)
    effect = publish({
        "kind": "effect-node",
        "name": "attach_image_as_icon",
        "body-format": "text",
        "body": "attach effect node test fixture",
    }, nodes_dir=temp_nodes_dir)

    rule = publish({
        "kind": "interaction-rule",
        "name": "interaction_rule_image_onto_any",
        "body-format": "interaction-rule-spec",
        "body": {
            "name": "image_onto_any",
            "description": "test seed rule",
            "trigger": {
                "source_kind": "ImageNode",
                "target_kind": "*",
                "drag_kind": "move",
            },
            "effect": {
                "kind": "execute-node",
                "node_id": effect["id"],
                "input_mapping": {
                    "source": "$.source",
                    "target": "$.target",
                    "context": "$.context",
                },
            },
            "precedence": 100,
        },
        "system-rule": True,
    }, nodes_dir=temp_nodes_dir)

    # Discover via the wildcard target match.
    matches = find({
        "by": "rule",
        "source_kind": "ImageNode",
        "target_kind": "ButtonNode",
        "drag_kind": "move",
    }, nodes_dir=temp_nodes_dir)
    assert len(matches) >= 1
    assert any(m["id"] == rule["id"] for m in matches)
    fired_rule = next(m for m in matches if m["id"] == rule["id"])
    assert fired_rule["body"]["effect"]["node_id"] == effect["id"]


# --------------------------------------------------------------------------
# CLI smoke
# --------------------------------------------------------------------------


def test_cli_attach_smoke(published_target_and_image, tmp_path):
    target_id, image_id, nodes_dir = published_target_and_image
    env = dict(os.environ)
    env["ALETHEA_CC_NODES_DIR"] = str(nodes_dir)
    env["ALETHEA_CC_SUBSTRATE"] = str(SUBSTRATE_DIR)
    env["ALETHEA_AUTO_NOTION_SYNC"] = "0"
    result = subprocess.run(
        [sys.executable, "tools/icon_attachment_driver.py", target_id, image_id],
        cwd=APEIRON_ROOT, env=env, capture_output=True, text=True,
    )
    assert result.returncode == 0, result.stderr
    assert "new_id" in result.stdout
    assert f"image:{image_id}" in result.stdout
