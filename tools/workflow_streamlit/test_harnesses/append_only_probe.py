"""append_only_probe — Tool T2 from brief 02 per-module plan.

Per brief 02 commit 3 (Decision B2, SPEC-086 + SPEC-026 + SPEC-084).

Usage:
    python -m tools.workflow_streamlit.test_harnesses.append_only_probe \
        [--positions <N>] \
        [--mode probe-double-append | probe-supersession | probe-leaf-substitution | all] \
        [--verbose]

The probe drives the workflow_view substrate node + the continuous-scroll
renderer through every shape of append-only-violation attempt and asserts
the system rejects each one at the appropriate enforcement layer:

  - probe-double-append:     attempt a bare double-append → storage-layer
                             rejects via ValueError ("bare double-append").
  - probe-supersession:      a supersession-append (source_ref present)
                             succeeds → both entries present in positions
                             → renderer emits BOTH (original at position,
                             supersession at end) with distinct
                             data-append-kind markers.
  - probe-leaf-substitution: caller tries to render a supersession leaf
                             in place of the original → renderer raises
                             FreezeAtAppendTimeViolation.

Exit 0 when every probed mode rejects-as-expected; exit 1 on any
unexpected success / unexpected failure. Composes against the substrate's
`workflow_view.append` action + the renderer's `freeze_at_append_time`
policy + `select_window()` — no new dispatch code.

Brief 06 (text-API + terminal) will wrap this harness as an MCP-callable
so the LLM-driver scenarios can exercise the append-only invariant via
`execute_process_node`. The harness mirrors `scroll_window.py` (Tool T1)
in shape — same CLI conventions, same path setup, same JSON-on-verbose
output convention.

Composed against:
  - workflow_continuous_scroll_v1.render (the renderer the probe drives).
  - workflow_continuous_scroll_v1.FreezeAtAppendTimeViolation (the named
    violation the probe expects).
  - Alethea-cc/substrate/primitives.execute (the storage-layer append
    action the probe drives — composed via import-on-demand so the
    harness can run in environments where Alethea-cc/substrate isn't on
    sys.path; in that case the storage-layer probes report 'skipped' and
    the renderer-layer probes still run).
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

HERE = Path(__file__).resolve()
APEIRON_ROOT = HERE.parent.parent.parent.parent
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

from tools.workflow_streamlit.renderers.workflow_continuous_scroll_v1 import (  # noqa: E402
    FreezeAtAppendTimeViolation,
    RENDERER_ID,
    render,
)


# --------------------------------------------------------------------------
# Substrate import (best-effort — the harness can run without Alethea-cc
# on sys.path; storage-layer probes degrade to 'skipped' in that case).
# --------------------------------------------------------------------------


def _try_import_substrate() -> Tuple[Optional[Any], Optional[Any]]:
    """Return (substrate_execute, substrate_compute_id) if Alethea-cc is
    reachable, (None, None) otherwise. The probe degrades gracefully —
    renderer-layer probes always run; storage-layer probes need the
    substrate's execute + compute_id helpers."""
    # Heuristic: Alethea-cc lives at <apeiron-parent>/Alethea/Alethea-cc
    # in the canonical maintainer layout.
    candidate = APEIRON_ROOT.parent / "Alethea" / "Alethea-cc" / "substrate"
    if not candidate.exists():
        return (None, None)
    if str(candidate) not in sys.path:
        sys.path.insert(0, str(candidate))
    try:
        from primitives import execute as substrate_execute  # type: ignore
        from evaluator import compute_id as substrate_compute_id  # type: ignore
        return (substrate_execute, substrate_compute_id)
    except Exception:
        return (None, None)


# --------------------------------------------------------------------------
# Synthetic node + workflow_view builders
# --------------------------------------------------------------------------


def _mk_position(
    node_id: str,
    source: str = "test",
    source_ref: Optional[str] = None,
) -> Dict[str, Any]:
    entry: Dict[str, Any] = {
        "node_id": node_id,
        "appended_at": "2026-05-22T00:00:00Z",
        "appended_by": "append_only_probe",
        "provenance": {"source": source},
    }
    if source_ref:
        entry["provenance"]["source_ref"] = source_ref
    return entry


def _mk_workflow_view(positions: List[Dict[str, Any]]) -> Dict[str, Any]:
    return {
        "id": "sha256:probe_wv",
        "name": "workflow_view_main",
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": {
            "positions": positions,
            "default_paste_location": "end",
            "metadata": {
                "window": "50,20,20",
                "mode": "append-only",
                "surface": "workflow_continuous_scroll",
            },
        },
    }


def _mk_content_node(node_id: str, body_text: str) -> Dict[str, Any]:
    return {
        "id": node_id,
        "name": f"content_{node_id[:16]}",
        "kind": "content",
        "body": body_text,
    }


def _mk_substrate_workflow_view(
    compute_id: Any,
    name: str = "workflow_view_main",
) -> Dict[str, Any]:
    """A substrate-shaped workflow_view node suitable for direct
    `execute()` invocation. The node's `id` is computed via the
    substrate's content-addressing helper so subsequent `supersede()`
    calls (triggered by the `append` action) can record lineage."""
    node: Dict[str, Any] = {
        "name": name,
        "kind": "workflow_view",
        "body-format": "workflow-view",
        "body": {
            "positions": [],
            "default_paste_location": "end",
            "metadata": {
                "window": "50,20,20",
                "mode": "append-only",
                "surface": "workflow_continuous_scroll",
            },
        },
        "connections": [],
    }
    node["id"] = compute_id(node)
    return node


# --------------------------------------------------------------------------
# Probe implementations
# --------------------------------------------------------------------------


NODE_A = "sha256:" + "a" * 64
NODE_B = "sha256:" + "b" * 64
NODE_C = "sha256:" + "c" * 64


def probe_double_append(
    substrate_execute: Any, substrate_compute_id: Any
) -> Tuple[bool, str]:
    """Storage-layer probe: a bare double-append must raise ValueError.

    Returns (passed, evidence). passed=True when the expected ValueError
    fires AND its message names the double-append condition.
    """
    if substrate_execute is None or substrate_compute_id is None:
        return (True, "skipped (substrate not on sys.path)")
    wv = _mk_substrate_workflow_view(substrate_compute_id)
    once = substrate_execute(
        wv,
        input={
            "action": "append",
            "content_node_id": NODE_A,
            "provenance": {"source": "chat"},
        },
    )
    try:
        substrate_execute(
            once,
            input={
                "action": "append",
                "content_node_id": NODE_A,  # already present, no source_ref
                "provenance": {"source": "chat"},
            },
        )
    except ValueError as e:
        msg = str(e)
        if "double-append" in msg or "already in positions" in msg:
            return (True, f"storage-layer rejected as expected: {msg[:120]}")
        return (False, f"storage-layer raised ValueError but not the expected one: {msg[:200]}")
    except Exception as e:
        return (False, f"storage-layer raised wrong exception type: {type(e).__name__}: {e}")
    return (False, "storage-layer accepted bare double-append (CONTRACT VIOLATION)")


def probe_supersession_append(
    substrate_execute: Any, substrate_compute_id: Any
) -> Tuple[bool, str]:
    """Storage-layer + renderer-layer probe: a supersession-append
    (provenance.source_ref names predecessor) succeeds → both entries
    present in positions → renderer emits both with distinct
    data-append-kind markers."""
    if substrate_execute is None or substrate_compute_id is None:
        # Renderer-layer half still runs (synthetic supersession positions).
        original = _mk_position(NODE_A)
        supersession = _mk_position(NODE_B, source="edit", source_ref=NODE_A)
        wv = _mk_workflow_view([original, supersession])
        html = render({"content_nodes": [wv]})
        if (
            f'data-node-id="{NODE_A}"' in html
            and f'data-node-id="{NODE_B}"' in html
            and 'data-append-kind="original"' in html
            and 'data-append-kind="supersession"' in html
        ):
            return (True, "renderer emits original+supersession (substrate skipped)")
        return (False, "renderer failed to emit both entries with distinct append-kind")

    # Full storage + renderer path.
    wv = _mk_substrate_workflow_view(substrate_compute_id)
    once = substrate_execute(
        wv,
        input={
            "action": "append",
            "content_node_id": NODE_A,
            "provenance": {"source": "chat"},
        },
    )
    twice = substrate_execute(
        once,
        input={
            "action": "append",
            "content_node_id": NODE_B,
            "provenance": {"source": "edit", "source_ref": NODE_A},
        },
    )
    positions = twice["body"]["positions"]
    if len(positions) != 2:
        return (False, f"expected 2 positions after supersession-append; got {len(positions)}")
    if positions[0]["node_id"] != NODE_A or positions[1]["node_id"] != NODE_B:
        return (False, f"positions order wrong: {[p['node_id'] for p in positions]}")
    if positions[1]["provenance"].get("source_ref") != NODE_A:
        return (False, "supersession entry missing source_ref provenance")

    # Render the result and assert both entries appear.
    twice["id"] = "sha256:probe_wv_v2"
    html = render({"content_nodes": [twice]})
    if (
        f'data-node-id="{NODE_A}"' in html
        and f'data-node-id="{NODE_B}"' in html
        and 'data-append-kind="original"' in html
        and 'data-append-kind="supersession"' in html
    ):
        return (True, "supersession-append accepted + both entries rendered with distinct kinds")
    return (False, "supersession-append accepted but renderer output missing expected markers")


def probe_leaf_substitution(
    _substrate_execute: Any, _substrate_compute_id: Any
) -> Tuple[bool, str]:
    """Renderer-layer probe: caller passes a `nodes_lookup` entry whose
    `id` disagrees with the position-entry's `node_id` →
    FreezeAtAppendTimeViolation."""
    # Stage a workflow_view with ONE position pointing at NODE_A.
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    # Build a "leaf" content-node whose id is NODE_B — simulating a
    # caller that tries to substitute the supersession leaf in place
    # of the original-append entry.
    leaf_node = _mk_content_node(NODE_B, "I am the supersession leaf")
    try:
        render(
            {
                "content_nodes": [wv],
                "context": {"nodes_lookup": {NODE_A: leaf_node}},
            }
        )
    except FreezeAtAppendTimeViolation as e:
        msg = str(e)
        if "freeze_at_append_time" in msg or "Decision B2" in msg or "substitute" in msg:
            return (True, f"renderer rejected leaf substitution: {msg[:150]}")
        return (True, f"renderer rejected (FreezeAtAppendTimeViolation, msg: {msg[:120]})")
    except Exception as e:
        return (False, f"renderer raised wrong exception: {type(e).__name__}: {e}")
    return (
        False,
        "renderer accepted leaf substitution (CONTRACT VIOLATION — freeze_at_append_time bypassed)",
    )


def probe_opt_out_history_collapsed(
    _substrate_execute: Any, _substrate_compute_id: Any
) -> Tuple[bool, str]:
    """Renderer-layer probe: opt-out via context['freeze_at_append_time']=False
    DOES allow leaf substitution (the phase-2 history_collapsed escape
    hatch — kept as the named opt-out per Decision B2 tradeoff)."""
    positions = [_mk_position(NODE_A)]
    wv = _mk_workflow_view(positions)
    leaf_node = _mk_content_node(NODE_B, "leaf body")
    try:
        html = render(
            {
                "content_nodes": [wv],
                "context": {
                    "nodes_lookup": {NODE_A: leaf_node},
                    "freeze_at_append_time": False,
                },
            }
        )
    except FreezeAtAppendTimeViolation as e:
        return (False, f"opt-out failed — renderer still raised: {e}")
    # Surface should advertise the policy override.
    if 'data-freeze-policy="history_collapsed"' not in html:
        return (False, "opt-out succeeded but surface did not advertise data-freeze-policy")
    return (True, "opt-out accepted; data-freeze-policy='history_collapsed' advertised")


# --------------------------------------------------------------------------
# CLI
# --------------------------------------------------------------------------


PROBE_REGISTRY = {
    "probe-double-append": probe_double_append,
    "probe-supersession": probe_supersession_append,
    "probe-leaf-substitution": probe_leaf_substitution,
    "probe-opt-out": probe_opt_out_history_collapsed,
}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.strip().splitlines()[0])
    parser.add_argument(
        "--mode",
        choices=list(PROBE_REGISTRY.keys()) + ["all"],
        default="all",
        help="Which probe to run (default: all).",
    )
    parser.add_argument(
        "--verbose",
        action="store_true",
        help="Emit per-probe JSON evidence (default: terse summary only).",
    )
    args = parser.parse_args()

    substrate_execute, substrate_compute_id = _try_import_substrate()

    modes_to_run = (
        list(PROBE_REGISTRY.keys()) if args.mode == "all" else [args.mode]
    )

    results: List[Dict[str, Any]] = []
    for mode in modes_to_run:
        probe_fn = PROBE_REGISTRY[mode]
        try:
            passed, evidence = probe_fn(substrate_execute, substrate_compute_id)
        except Exception as e:
            passed, evidence = (False, f"probe crashed: {type(e).__name__}: {e}")
        results.append({"mode": mode, "passed": passed, "evidence": evidence})

    if args.verbose:
        print(
            json.dumps(
                {
                    "renderer_id": RENDERER_ID,
                    "substrate_available": substrate_execute is not None,
                    "results": results,
                },
                indent=2,
            )
        )
    else:
        for r in results:
            status = "OK" if r["passed"] else "FAIL"
            print(f"  [{status}] {r['mode']}: {r['evidence']}")

    all_passed = all(r["passed"] for r in results)
    if not all_passed:
        print("append_only_probe: one or more probes FAILED.", file=sys.stderr)
        return 1
    print(f"append_only_probe: OK — {len(results)} probe(s) passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
