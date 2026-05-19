"""
Tests for SPEC-054: Apeiron engine renders only trusted nodes.

Verifies that the engine consults its trust-set during ``discover()``
and ``_load_node_type_file()`` and refuses to import sources that are
not in the trust-set. Untrusted sources are recorded in
``engine.untrusted_encounters`` so the shell can surface a notification.
"""

from __future__ import annotations

import shutil
from pathlib import Path

import pytest

from engine.core import Engine
from tools.workflow.trust import TrustSet, render_trust_set


@pytest.fixture
def apeiron_root() -> Path:
    """The real Apeiron repo root with its node_types/ + renderers/."""
    here = Path(__file__).resolve().parent
    return here.parent


def test_engine_with_no_trust_set_loads_all(apeiron_root: Path):
    engine = Engine(root_dir=apeiron_root)
    engine.discover()
    assert "Cube" in engine.types
    assert engine.untrusted_encounters == []


def test_engine_with_permissive_trust_set_loads_all(apeiron_root: Path, tmp_path: Path):
    ts = render_trust_set(root=apeiron_root)
    engine = Engine(root_dir=apeiron_root, trust_set=ts)
    engine.discover()
    assert "Cube" in engine.types
    assert engine.untrusted_encounters == []
    assert "Cube" in engine.type_sources
    assert engine.type_sources["Cube"] == "node_types/cube.py"


def test_engine_blocks_outside_local_repo(tmp_path: Path):
    """An external .py file outside the default-trust patterns is blocked."""
    fake_root = tmp_path
    (fake_root / "external").mkdir()
    evil_file = fake_root / "external" / "evil.py"
    evil_file.write_text(
        "from engine.node import Manifest\n"
        "def manifest():\n"
        "    return Manifest(name='Evil')\n"
        "def build(params):\n"
        "    return {}\n"
        "def emit(state, view, ctx):\n"
        "    raise RuntimeError('should never run')\n",
        encoding="utf-8",
    )
    (fake_root / "node_types").mkdir()
    (fake_root / "renderers").mkdir()

    ts = render_trust_set(root=fake_root)
    engine = Engine(root_dir=fake_root, trust_set=ts)
    engine._load_node_type_file(evil_file, "external")

    assert "Evil" not in engine.types
    assert "external/evil.py" in engine.untrusted_encounters


def test_engine_loads_explicitly_trusted_external(tmp_path: Path):
    fake_root = tmp_path
    (fake_root / "external").mkdir()
    good_file = fake_root / "external" / "good.py"
    good_file.write_text(
        "from engine.node import Manifest\n"
        "def manifest():\n"
        "    return Manifest(name='Good')\n"
        "def build(params):\n"
        "    return {}\n"
        "def emit(state, view, ctx):\n"
        "    return {}\n",
        encoding="utf-8",
    )
    (fake_root / "node_types").mkdir()
    (fake_root / "renderers").mkdir()

    ts = render_trust_set(root=fake_root)
    ts.add("external/good.py")

    engine = Engine(root_dir=fake_root, trust_set=ts)
    engine._load_node_type_file(good_file, "external")
    assert "Good" in engine.types
    assert engine.untrusted_encounters == []


def test_spawn_unknown_type_marks_dead(apeiron_root: Path):
    """When a scene references a type whose source wasn't loaded
    (because untrusted), spawn falls through to the unknown-type path
    that marks the instance dead. The engine's existing module-isolation
    behavior already provides the typed-zero placeholder for downstream
    rendering."""
    engine = Engine(root_dir=apeiron_root)
    engine.discover()
    node_id = engine.spawn(node_id="phantom", type_name="DoesNotExist")
    inst = engine.nodes[node_id]
    assert inst.dead
    assert "unknown type" in inst.error


def test_source_id_computation_is_relative_posix(apeiron_root: Path):
    engine = Engine(root_dir=apeiron_root)
    cube_path = apeiron_root / "node_types" / "cube.py"
    assert engine._source_id_for(cube_path) == "node_types/cube.py"


def test_source_id_outside_root_falls_back_to_absolute(tmp_path: Path, apeiron_root: Path):
    engine = Engine(root_dir=apeiron_root)
    outside = tmp_path / "outside.py"
    outside.write_text("# unrelated", encoding="utf-8")
    sid = engine._source_id_for(outside)
    assert sid.endswith("outside.py")


def test_untrusted_blocked_at_discover_not_at_spawn(tmp_path: Path):
    """The trust-check runs BEFORE module exec_module, so an attacker's
    top-level code never runs even once.
    """
    fake_root = tmp_path
    (fake_root / "node_types").mkdir()
    (fake_root / "renderers").mkdir()
    (fake_root / "external").mkdir()
    sentinel = fake_root / "sentinel.txt"
    evil_file = fake_root / "external" / "evil.py"
    evil_file.write_text(
        f"open(r'{sentinel}', 'w').write('TOP_LEVEL_RAN')\n",
        encoding="utf-8",
    )

    ts = render_trust_set(root=fake_root)
    engine = Engine(root_dir=fake_root, trust_set=ts)
    engine._load_node_type_file(evil_file, "external")

    assert not sentinel.exists(), (
        "top-level module code RAN — trust-check happened too late"
    )
    assert "external/evil.py" in engine.untrusted_encounters


def test_reload_type_respects_trust_via_load_path(apeiron_root: Path):
    """reload_type calls _load_node_type_file which performs the trust
    check, so reload of a node_types/*.py file still works under a
    render-trust gate."""
    ts = render_trust_set(root=apeiron_root)
    engine = Engine(root_dir=apeiron_root, trust_set=ts)
    engine.discover()
    assert "Cube" in engine.types
    ok = engine.reload_type("Cube")
    assert ok
    assert "Cube" in engine.types
