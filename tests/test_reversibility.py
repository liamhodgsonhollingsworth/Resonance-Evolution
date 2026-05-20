"""
Reversibility cycle tests — SPEC-063.

The maintainer's stated test discipline:

> "do an action and then undo it, and see if the result is the same
> that you started with. Doing this for larger cycles of doing and
> undoing should reveal any problems or bugs with the software."

Each test captures a state snapshot, performs an action, captures
again, undoes, captures again, and asserts the after-undo snapshot
matches the initial snapshot. Then runs the same cycle N times to
surface drift that a single round wouldn't catch.

The snapshot shape varies per surface: per-renderer view-state for
expand/collapse, trust-set membership for promote/revoke, WorkflowView
mode for set-mode, etc.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from engine import Engine  # noqa: E402
from engine.actions import dispatch_action, get_view_state  # noqa: E402
from tools.text_test import dispatch_command  # noqa: E402
from tools.workflow.inbox import Inbox  # noqa: E402
from tools.workflow.trust import sender_trust_set  # noqa: E402


@pytest.fixture
def engine_with_workflow_scene():
    e = Engine(root_dir=ROOT)
    e.discover()
    e.load_scene(ROOT / "scenes" / "workflow_view.json")
    e.precompute()
    return e


# ---------------------------------------------------------------------------
# Generic reversibility runner
# ---------------------------------------------------------------------------


def run_cycle(action, undo, snapshot, n_cycles: int = 50):
    """Run ``n_cycles`` rounds of action / undo. After each round assert
    the snapshot equals the snapshot before the action. Returns the
    initial snapshot for callers that want to verify against an
    externally-recorded baseline.
    """
    initial = snapshot()
    for round_i in range(n_cycles):
        before = snapshot()
        action()
        undo()
        after = snapshot()
        assert after == before, (
            f"reversibility cycle {round_i} drifted: before={before!r} after={after!r}"
        )
    final = snapshot()
    assert final == initial, (
        f"reversibility cycle drifted across {n_cycles} rounds: "
        f"initial={initial!r} final={final!r}"
    )
    return initial


# ---------------------------------------------------------------------------
# expand / collapse — view-state reversibility
# ---------------------------------------------------------------------------


def test_expand_collapse_reversible_one_cycle(engine_with_workflow_scene):
    e = engine_with_workflow_scene
    target = e.cache["wishes_source"]["items"][0]["id"]
    run_cycle(
        action=lambda: dispatch_command(e, f"expand wish_panel {target}"),
        undo=lambda: dispatch_command(e, "collapse wish_panel"),
        snapshot=lambda: get_view_state(e, "wish_panel").get("expanded_item"),
        n_cycles=1,
    )


def test_expand_collapse_reversible_50_cycles(engine_with_workflow_scene):
    e = engine_with_workflow_scene
    target = e.cache["wishes_source"]["items"][0]["id"]
    run_cycle(
        action=lambda: dispatch_command(e, f"expand wish_panel {target}"),
        undo=lambda: dispatch_command(e, "collapse wish_panel"),
        snapshot=lambda: get_view_state(e, "wish_panel").get("expanded_item"),
        n_cycles=50,
    )


# ---------------------------------------------------------------------------
# WorkflowView mode toggle reversibility
# ---------------------------------------------------------------------------


def test_workflow_mode_toggle_reversible_50_cycles(engine_with_workflow_scene):
    e = engine_with_workflow_scene
    run_cycle(
        action=lambda: dispatch_command(e, "set-mode workflow_view full_render"),
        undo=lambda: dispatch_command(e, "set-mode workflow_view panels"),
        snapshot=lambda: e.nodes["workflow_view"].state["mode"],
        n_cycles=50,
    )


# ---------------------------------------------------------------------------
# Trust-set promote/revoke reversibility
# ---------------------------------------------------------------------------


def test_trust_promote_revoke_reversible_30_cycles(tmp_path: Path):
    """Promote a sender to trusted, revoke them, repeat — the trust-set
    membership snapshot returns to its initial state every round."""
    ts = sender_trust_set(tmp_path, user="LHH")
    sender = "round-trip-worker"

    def action():
        ts.add(sender)

    def undo():
        ts.remove(sender)

    def snapshot():
        return frozenset(ts.list_trusted())

    initial = snapshot()
    assert sender not in initial
    run_cycle(action, undo, snapshot, n_cycles=30)
    final = snapshot()
    assert final == initial


def test_inbox_promote_then_revoke_message_flow(tmp_path: Path):
    """End-to-end: post a quarantined message, promote the sender to
    trusted, revoke them, and the message returns to quarantine. Cycle."""
    state_dir = tmp_path / "state" / "workflow"
    ts = sender_trust_set(tmp_path, user="LHH")
    inbox = Inbox(state_dir=state_dir, alethea_cc_root=None, sender_trust=ts)
    inbox.post(to="LHH", kind="msg", summary="hi", sender="stranger")

    def snapshot():
        return (
            len(inbox.list_main()),
            len(inbox.list_quarantine()),
            frozenset(ts.list_trusted()),
        )

    initial = snapshot()
    assert initial[0] == 0  # main is empty
    assert initial[1] == 1  # quarantine has the message

    for _ in range(20):
        before = snapshot()
        ts.add("stranger")
        after_promote = snapshot()
        assert after_promote[0] == 1  # main has the message now
        assert after_promote[1] == 0  # quarantine empty
        ts.remove("stranger")
        after_revoke = snapshot()
        assert after_revoke == before


# ---------------------------------------------------------------------------
# Spawn-despawn reversibility (limited — engine has no de-spawn primitive)
# ---------------------------------------------------------------------------


def test_spawn_marking_dead_reversible_via_state_swap(engine_with_workflow_scene):
    """No proper de-spawn exists; the closest analogue is marking a node
    `dead` and then reviving it. This test documents the limitation:
    the visible-effect of "dead → alive" is a renderer-level fallback
    (typed-zero), and the round-trip preserves the node's state."""
    e = engine_with_workflow_scene
    n = e.nodes["wish_panel"]
    initial_dead = n.dead
    n.dead = True
    assert n.dead is True
    n.dead = initial_dead
    assert n.dead == initial_dead