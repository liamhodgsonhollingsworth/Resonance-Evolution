"""Regression test — the Wave 2 dispatcher must still pass every Wave 1 case.

Schema-version: 1
Filed: 2026-05-29 per MVP plan Wave 2.

The Wave 1 evaluation gate built a 12-case adversarial set against the
baseline at `tools/weavemind_eval/drag_drop_dispatcher_baseline.py` +
`drag_drop_dispatcher.weft`. Wave 2 lifts the baseline to production with
the registry wired through. This file is the receipt: every case the
baseline passed, the production dispatcher must also pass.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

APEIRON_ROOT = Path(__file__).resolve().parents[3]
if str(APEIRON_ROOT) not in sys.path:
    sys.path.insert(0, str(APEIRON_ROOT))

import pytest

from tools.renderer_registry.drag_drop_dispatcher import (
    dispatch,
    event_from_dict,
    graph_from_dict,
    result_to_dict,
)


WAVE1_TEST_CASES = APEIRON_ROOT / "tools" / "weavemind_eval" / "test_cases.json"


def _load_cases():
    if not WAVE1_TEST_CASES.exists():
        pytest.skip(f"Wave 1 test cases not found at {WAVE1_TEST_CASES}")
    return json.loads(WAVE1_TEST_CASES.read_text(encoding="utf-8"))["cases"]


@pytest.mark.parametrize(
    "case",
    _load_cases(),
    ids=lambda c: c["name"],
)
def test_wave1_case_passes(case):
    """Every Wave 1 baseline case must still pass against the Wave 2 dispatcher."""
    event = event_from_dict(case["event"])
    graph = graph_from_dict(case.get("initial_graph", {}))
    result = dispatch(event, graph)
    actual = result_to_dict(result)
    expected = case["expected"]

    if expected.get("edit") is None:
        assert actual["edit"] is None, (
            f"{case['name']}: expected no edit, got {actual['edit']}"
        )
    else:
        assert actual["edit"] is not None, (
            f"{case['name']}: expected an edit, got None ({actual['rejection']})"
        )
        for field_name in ("operation", "source", "relation", "target"):
            assert actual["edit"][field_name] == expected["edit"][field_name], (
                f"{case['name']}: field {field_name} mismatch — "
                f"expected {expected['edit'][field_name]}, "
                f"got {actual['edit'][field_name]}"
            )

    if expected.get("rejection_kind") is not None:
        assert actual["rejection"] is not None, (
            f"{case['name']}: expected rejection {expected['rejection_kind']}, got accept"
        )
        assert actual["rejection"].startswith(expected["rejection_kind"]), (
            f"{case['name']}: rejection mismatch — "
            f"expected prefix {expected['rejection_kind']}, "
            f"got {actual['rejection']!r}"
        )
