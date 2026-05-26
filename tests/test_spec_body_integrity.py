"""Tests for the SPEC body integrity check — the fifth input stream
for the workflow-management auto-review routine.

Closes deferred-concerns #28 (A6-4). The wave-I-2-relief gutting of
multiple SPEC bodies was not caught by the auto-review's existing
four input streams; PR #175 (Apeiron splitter-safety fix) prevents
gutting at the splitter level but the auto-review still wouldn't
notice manual destructive edits. This module ships the fifth
stream.

Tests cover:

  - Baseline file gets created on first run (with the current
    per-spec line counts).
  - Subsequent runs compute deltas vs the recorded baseline.
  - Alert fires when a SPEC body shrinks past the threshold.
  - No alert when the shrink is below the threshold.
  - New SPECs (added between runs) appear as ``new_specs``, not
    alerts.
  - Baseline updates after each run so a maintainer-accepted
    shrink doesn't keep re-alerting.
  - The threshold is configurable.
  - The check is resilient to missing Alethea checkouts (returns
    empty result rather than crashing).
  - The check uses ``tmp_path`` so it never touches the real
    apeiron state dir.
  - The render-alerts shape matches the auto-review's observation
    dict convention.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Tuple

import pytest

from tools import spec_body_integrity


# ---------------------------------------------------------------------
# Helpers — build a fake Alethea repo on disk with a few SPECs.
# ---------------------------------------------------------------------


def _make_spec(path: Path, body_lines: int, *, spec_id: int = 1) -> None:
    """Write a SPEC node file with frontmatter + a body of
    ``body_lines`` lines."""
    path.parent.mkdir(parents=True, exist_ok=True)
    frontmatter = (
        "---\n"
        f"title: \"SPEC-{spec_id:03d} — Test fixture\"\n"
        "type: spec\n"
        f"alias: \"spec_{spec_id:03d}\"\n"
        f"spec_id: {spec_id}\n"
        "status: \"in-progress\"\n"
        "priority: \"must\"\n"
        "---\n"
        "\n"
    )
    body = "\n".join(f"Line {i}." for i in range(body_lines)) + "\n"
    path.write_text(frontmatter + body, encoding="utf-8")


def _build_fake_alethea(
    tmp_path: Path, specs: dict[int, int],
) -> Path:
    """Build a fake Alethea repo with ``specs[spec_id] = body_lines``.
    Returns the alethea-root path the helper can be pointed at.
    """
    alethea = tmp_path / "Alethea"
    nodes_dir = alethea / "Alethea-cc" / "nodes"
    nodes_dir.mkdir(parents=True, exist_ok=True)
    for sid, body_lines in specs.items():
        path = nodes_dir / f"spec_{sid:03d}_test_fixture.md"
        _make_spec(path, body_lines, spec_id=sid)
    return alethea


# ---------------------------------------------------------------------
# Body-line counting tests.
# ---------------------------------------------------------------------


def test_count_body_lines_skips_frontmatter(tmp_path: Path) -> None:
    """Body counter ignores YAML frontmatter; counts only the lines
    after the closing ``---``."""
    path = tmp_path / "spec_001_x.md"
    _make_spec(path, body_lines=10)
    # Body = 10 content lines + 1 leading blank line (from the
    # frontmatter spacer) + 1 trailing newline = 11 lines.
    count = spec_body_integrity._count_body_lines(path)
    assert count == 11


def test_count_body_lines_handles_no_frontmatter(tmp_path: Path) -> None:
    """Files without frontmatter count the whole file as body."""
    path = tmp_path / "plain.md"
    path.write_text("one\ntwo\nthree\n", encoding="utf-8")
    assert spec_body_integrity._count_body_lines(path) == 3


def test_count_body_lines_handles_unreadable_path(tmp_path: Path) -> None:
    """Missing file returns 0 silently — best-effort."""
    missing = tmp_path / "does-not-exist.md"
    assert spec_body_integrity._count_body_lines(missing) == 0


def test_count_body_lines_malformed_frontmatter(tmp_path: Path) -> None:
    """Frontmatter without a closing marker → whole-file count."""
    path = tmp_path / "malformed.md"
    path.write_text("---\nfoo: bar\nno closing\n", encoding="utf-8")
    # Three lines total; no closing ``---``.
    assert spec_body_integrity._count_body_lines(path) == 3


# ---------------------------------------------------------------------
# First-run + baseline creation.
# ---------------------------------------------------------------------


def test_first_run_creates_baseline(tmp_path: Path) -> None:
    """No baseline file exists; the first run captures the current
    counts + writes the baseline + emits no alerts (nothing to
    compare against yet)."""
    alethea = _build_fake_alethea(tmp_path, {1: 20, 2: 30, 3: 40})
    state_dir = tmp_path / "state"

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir,
        alethea_root=alethea,
    )

    assert result.first_run is True
    assert result.observed == 3
    assert result.alerts == []
    assert result.baseline_updated is True

    baseline_path = state_dir / "spec_body_baselines.json"
    assert baseline_path.exists()
    baseline = json.loads(baseline_path.read_text(encoding="utf-8"))
    assert set(baseline["counts"].keys()) == {"spec_001", "spec_002", "spec_003"}
    assert all(isinstance(v, int) and v > 0 for v in baseline["counts"].values())


def test_subsequent_run_compares_against_baseline(tmp_path: Path) -> None:
    """Second run picks up the baseline and computes deltas."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    # First run captures the baseline.
    first = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir,
        alethea_root=alethea,
    )
    assert first.first_run is True
    assert first.alerts == []

    # No mutation; second run sees identical counts → no alerts.
    second = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir,
        alethea_root=alethea,
    )
    assert second.first_run is False
    assert second.observed == 1
    assert second.alerts == []


# ---------------------------------------------------------------------
# Alert firing.
# ---------------------------------------------------------------------


def test_alert_fires_on_shrink_past_threshold(tmp_path: Path) -> None:
    """Body shrinks from 100 lines → 30 lines (70% shrink) → alert
    fires at the default 50% threshold."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    # First run captures baseline (~100 body lines).
    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )

    # Mutate: rewrite SPEC-001 with much less content.
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=20)

    # Second run flags the shrink.
    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert len(result.alerts) == 1
    alert = result.alerts[0]
    assert alert.spec_id == "spec_001"
    assert alert.old_lines > alert.new_lines
    # Old body was ~101 lines (100 + frontmatter spacer + trailing
    # newline → 101). New body is ~21 lines. delta_pct > 0.5.
    assert alert.delta_pct > 0.5


def test_no_alert_for_small_shrink(tmp_path: Path) -> None:
    """Shrink below the threshold (40% in this test) does not fire."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    # 100 → 70 ≈ 30% shrink.
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=70)

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert result.alerts == []


def test_no_alert_on_growth(tmp_path: Path) -> None:
    """Body growing (the maintainer added content) does not fire."""
    alethea = _build_fake_alethea(tmp_path, {1: 50})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=200)

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert result.alerts == []


def test_threshold_is_configurable(tmp_path: Path) -> None:
    """Pass a higher threshold (0.9) — a 70% shrink no longer fires."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, shrink_threshold=0.9,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=30)  # 70% shrink

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, shrink_threshold=0.9,
    )
    assert result.alerts == []


def test_low_threshold_catches_small_shrink(tmp_path: Path) -> None:
    """Pass a lower threshold (0.2) — a 25% shrink fires."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, shrink_threshold=0.2,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=70)  # ~30% shrink

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, shrink_threshold=0.2,
    )
    assert len(result.alerts) == 1


# ---------------------------------------------------------------------
# Baseline behavior across runs.
# ---------------------------------------------------------------------


def test_baseline_updates_after_each_run(tmp_path: Path) -> None:
    """A run that fired an alert STILL updates the baseline so the
    next run doesn't re-fire on the same shrink (the maintainer
    either accepted it as a baseline or reverted it; either way the
    next run compares against the now-current state)."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=20)

    first = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert len(first.alerts) == 1

    # Second run on the SAME shrunk state → no re-fire (baseline updated).
    second = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert second.alerts == []


def test_read_only_mode_does_not_update_baseline(tmp_path: Path) -> None:
    """``update_baseline=False`` keeps the baseline file frozen so
    the next run still alerts (useful for tests + read-only
    probes)."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=20)

    first = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, update_baseline=False,
    )
    assert len(first.alerts) == 1
    assert first.baseline_updated is False

    # Second read-only run still alerts because the baseline is unchanged.
    second = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea, update_baseline=False,
    )
    assert len(second.alerts) == 1


def test_new_specs_recorded_not_alerted(tmp_path: Path) -> None:
    """A SPEC added between runs has no baseline → reported in
    ``new_specs`` (not alerts) so the maintainer doesn't see a
    false-positive on legitimate new SPECs."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )

    # Add a new SPEC.
    new_path = (
        alethea / "Alethea-cc" / "nodes" / "spec_002_brand_new.md"
    )
    _make_spec(new_path, body_lines=50, spec_id=2)

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert result.alerts == []
    assert result.new_specs == ["spec_002"]
    assert result.observed == 2


# ---------------------------------------------------------------------
# Edge cases.
# ---------------------------------------------------------------------


def test_missing_alethea_returns_empty_result(tmp_path: Path) -> None:
    """When the Alethea root doesn't exist, the run returns empty
    (no alerts, no crash, no baseline write since there were no
    specs to baseline)."""
    state_dir = tmp_path / "state"

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir,
        alethea_root=tmp_path / "no-such-alethea",
    )
    assert result.alerts == []
    assert result.observed == 0
    assert result.baseline_updated is False


def test_render_alerts_shape(tmp_path: Path) -> None:
    """``render_alerts`` projects each alert onto the observation-
    dict shape the auto-review's Step 1 gather expects."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    spec_path = alethea / "Alethea-cc" / "nodes" / "spec_001_test_fixture.md"
    _make_spec(spec_path, body_lines=20)

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    observations = spec_body_integrity.render_alerts(result)
    assert len(observations) == 1
    obs = observations[0]
    for key in (
        "source", "kind", "spec_id", "path",
        "old_lines", "new_lines", "delta_pct", "message",
    ):
        assert key in obs
    assert obs["source"] == "spec_body_integrity"
    assert obs["kind"] == "alert"
    assert obs["spec_id"] == "spec_001"
    assert "SPEC body shrunk" in obs["message"]


def test_render_alerts_empty_for_no_alerts(tmp_path: Path) -> None:
    """No alerts → empty observation list."""
    alethea = _build_fake_alethea(tmp_path, {1: 100})
    state_dir = tmp_path / "state"

    first = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert spec_body_integrity.render_alerts(first) == []


def test_default_state_dir_honors_env_var(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path,
) -> None:
    """``APEIRON_STATE_DIR`` set → ``<env>/auto_review/`` returned."""
    monkeypatch.setenv("APEIRON_STATE_DIR", str(tmp_path / "alt-state"))
    resolved = spec_body_integrity.default_state_dir()
    assert resolved == tmp_path / "alt-state" / "auto_review"


def test_default_state_dir_falls_back_to_apeiron_root(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """No env var → ``<apeiron-root>/state/auto_review/`` derived
    from the module's location."""
    monkeypatch.delenv("APEIRON_STATE_DIR", raising=False)
    resolved = spec_body_integrity.default_state_dir()
    assert resolved.name == "auto_review"
    assert resolved.parent.name == "state"


def test_spec_id_extraction_from_path(tmp_path: Path) -> None:
    """The ``spec_<N>_<slug>.md`` convention extracts ``spec_<N>``."""
    assert (
        spec_body_integrity._spec_id_from_path(
            Path("spec_001_one_click_gui_launch_from_desktop.md")
        )
        == "spec_001"
    )
    assert (
        spec_body_integrity._spec_id_from_path(Path("spec_042_x.md"))
        == "spec_042"
    )
    # Defensive fallback.
    assert (
        spec_body_integrity._spec_id_from_path(Path("not-a-spec.md"))
        == "not-a-spec"
    )


# ---------------------------------------------------------------------
# Test isolation — pin that no real state-dir is touched.
# ---------------------------------------------------------------------


def test_run_uses_tmp_state_dir_only(tmp_path: Path) -> None:
    """The check uses tmp_path for state; no real apeiron state-dir
    write happens. The test asserts the baseline file is INSIDE
    tmp_path (defense against an accidental absolute-path
    regression in default_state_dir).
    """
    alethea = _build_fake_alethea(tmp_path, {1: 50})
    state_dir = tmp_path / "isolated-state"

    result = spec_body_integrity.run_spec_body_integrity_check(
        state_dir=state_dir, alethea_root=alethea,
    )
    assert Path(result.baseline_path).is_relative_to(tmp_path)
