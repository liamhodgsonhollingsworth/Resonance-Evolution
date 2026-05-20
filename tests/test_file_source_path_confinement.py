"""
SPEC-079 follow-up: FileSource path confinement (2026-05-20).

Stress-test finding from the post-compact arc named paste-of-FileSource
as an unconfined read primitive: a malicious paste could spawn a
FileSource pointing at any path the process can read. This test
locks in the allow-list gate that confines FileSource to:

- the Apeiron project root
- user workspace dirs (``~/Desktop/Apeiron``, ``~/Desktop/Alethea``,
  ``~/Desktop/Resonance``)
- the temp-import zone at ``<apeiron_root>/state/temp_imports/``
- runtime-registered extras (tests use this for ``tmp_path``)
- ``APEIRON_FILE_SOURCE_EXTRA_ALLOWED_ROOTS`` env-var entries

Rejection raises ``FileSourceOutsideAllowListError`` at build() time
with the resolved real-path and the active allow-list in the message.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent.resolve()
sys.path.insert(0, str(ROOT))

from node_types import file_source  # noqa: E402
from node_types.file_source import FileSourceOutsideAllowListError  # noqa: E402


# ---------------------------------------------------------------------------
# Allow-list contents.
# ---------------------------------------------------------------------------


def test_default_allow_list_contains_project_root():
    roots = file_source.get_allowed_roots()
    assert ROOT in roots, f"project root missing from allow-list: {roots}"


def test_default_allow_list_contains_temp_import_zone():
    roots = file_source.get_allowed_roots()
    expected = (ROOT / "state" / "temp_imports").resolve()
    assert expected in roots, f"temp-import zone missing: {roots}"


def test_default_allow_list_contains_user_workspace_dirs():
    """The cross-project workspace dirs (Apeiron / Alethea / Resonance
    on the user's Desktop) are part of the default allow-list. The
    resolved paths may differ from the configured strings on machines
    where the dirs don't exist — the resolver still includes a
    non-existent absolute path, which is what we assert here."""
    roots = file_source.get_allowed_roots()
    home_desktop = Path.home() / "Desktop"
    for name in ("Apeiron", "Alethea", "Resonance"):
        candidate = (home_desktop / name).resolve()
        assert candidate in roots, (
            f"workspace dir {candidate} missing from allow-list: {roots}"
        )


# ---------------------------------------------------------------------------
# Acceptance (paths INSIDE the allow-list).
# ---------------------------------------------------------------------------


def test_absolute_path_inside_allow_list_is_accepted(tmp_path):
    """An absolute path inside an allow-listed root builds cleanly."""
    f = tmp_path / "data.md"
    f.write_text("- [ ] alpha\n")
    state = file_source.build({"path": str(f), "parser_name": "tasks"})
    assert state["path"] == str(f.resolve())
    assert state["parser_name"] == "tasks"


def test_absolute_path_inside_project_root_is_accepted():
    """A real on-disk path inside the project root (the canonical
    workflow_view scene's tasks.md) builds cleanly."""
    target = ROOT / "tasks.md"
    assert target.exists()
    state = file_source.build({"path": str(target), "parser_name": "tasks"})
    assert state["path"] == str(target.resolve())


def test_relative_path_resolves_against_project_root_and_accepts():
    """Relative paths resolve against the Apeiron root (not the
    process CWD) so production scenes whose FileSources name a
    relative ``tasks.md`` keep working from any CWD."""
    state = file_source.build({"path": "tasks.md", "parser_name": "tasks"})
    expected = (ROOT / "tasks.md").resolve()
    assert state["path"] == str(expected)


# ---------------------------------------------------------------------------
# Rejection (paths OUTSIDE the allow-list).
# ---------------------------------------------------------------------------


@pytest.mark.no_file_source_tmp
def test_tmp_path_outside_allow_list_is_rejected(tmp_path):
    """With the autouse fixture opted out, a tmp_path is NOT in the
    allow-list and must be rejected."""
    f = tmp_path / "data.md"
    f.write_text("- [ ] alpha\n")
    with pytest.raises(FileSourceOutsideAllowListError) as exc:
        file_source.build({"path": str(f), "parser_name": "tasks"})
    msg = str(exc.value)
    # The resolved real-path appears in the message.
    assert str(f.resolve()) in msg
    # The allow-list also appears so the maintainer can diagnose.
    assert "allowed roots" in msg


@pytest.mark.no_file_source_tmp
def test_windows_drive_letter_path_outside_allow_list_rejected():
    """A path under a system directory (e.g. C:\\Windows\\System32 on
    Windows) must be rejected. Skip on non-Windows where the path
    doesn't make sense."""
    if os.name != "nt":
        pytest.skip("Windows-specific drive-letter path")
    target = "C:/Windows/System32/drivers/etc/hosts"
    with pytest.raises(FileSourceOutsideAllowListError) as exc:
        file_source.build({"path": target, "parser_name": "tasks"})
    msg = str(exc.value)
    assert "outside the allow-list" in msg


@pytest.mark.no_file_source_tmp
def test_unix_etc_passwd_path_rejected_on_non_windows():
    """Unix-flavored equivalent of the Windows test. Skips on
    Windows so each platform exercises its own rejection."""
    if os.name == "nt":
        pytest.skip("Unix-specific path")
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source.build({"path": "/etc/passwd", "parser_name": "tasks"})


@pytest.mark.no_file_source_tmp
def test_relative_path_that_escapes_project_root_rejected():
    """A relative path with ../.. that escapes the project root
    after resolution must be rejected on the *resolved* basis.

    We need to construct a relative segment that, when resolved
    against ROOT, lands outside the project. ``..`` from ROOT goes
    to the Desktop directory which IS in the allow-list (user
    workspace), so we need to escape further. Use a relative path
    that resolves into a path NOT covered by any workspace dir.
    """
    # ROOT is C:\Users\Liam\Desktop\Apeiron — going up 3 lands at
    # C:\Users which is NOT in the allow-list.
    rel = "../../../README.md"
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source.build({"path": rel, "parser_name": "tasks"})


# ---------------------------------------------------------------------------
# Symlink resolution.
# ---------------------------------------------------------------------------


@pytest.mark.no_file_source_tmp
def test_symlink_pointing_outside_allow_list_is_rejected(tmp_path):
    """A symlink that LIVES inside an allow-listed dir but POINTS at
    a path outside the allow-list must be rejected on the resolved
    real-path."""
    # Set up: inside tmp_path (NOT in allow-list once autouse opt-out)
    # we create a symlink targeting a known-outside path. The check
    # is on the resolved real-path either way.
    file_source.add_allowed_root(tmp_path)
    try:
        # Create the target outside the allow-list.
        outside_dir = tmp_path.parent / "deliberately_outside"
        outside_dir.mkdir(exist_ok=True)
        outside_target = outside_dir / "secret.txt"
        outside_target.write_text("secret\n")

        link_path = tmp_path / "innocuous_link.md"
        try:
            link_path.symlink_to(outside_target)
        except (OSError, NotImplementedError):
            pytest.skip("symlinks unavailable on this platform / permissions")

        # tmp_path IS allow-listed (we added it), so a non-symlink
        # file would be accepted. The symlink-following step must
        # detect the outside target and reject.
        with pytest.raises(FileSourceOutsideAllowListError) as exc:
            file_source.build({"path": str(link_path), "parser_name": "tasks"})
        msg = str(exc.value)
        assert "symlink" in msg.lower() or "outside" in msg.lower()
    finally:
        file_source.clear_extra_allowed_roots()


# ---------------------------------------------------------------------------
# Empty / whitespace-only path rejection.
# ---------------------------------------------------------------------------


@pytest.mark.no_file_source_tmp
def test_empty_string_path_rejected():
    """Build with explicit empty path. The build accepts empty by
    convention (existing behaviour preserved for the precompute
    "required" error path); test the explicit reject helper directly.

    The contract: when a non-empty path is supplied, confinement runs.
    When path is empty, build returns state with empty path and lets
    precompute report the standard "required" error. This test asserts
    the explicit gate function rejects whitespace-only input."""
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source._resolve_and_check("")
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source._resolve_and_check("   ")


@pytest.mark.no_file_source_tmp
def test_build_with_empty_path_does_not_raise():
    """Empty path remains an informational error at precompute time
    (the existing "path and parser_name both required" message).
    Confinement runs only when a non-empty path is supplied — that
    way the canonical default scene's behaviour is preserved."""
    state = file_source.build({"path": "", "parser_name": "tasks"})
    assert state["path"] == ""


# ---------------------------------------------------------------------------
# Re-instantiation after rejection — no orphan registry entry.
# ---------------------------------------------------------------------------


def test_reinstantiation_after_rejection_does_not_leak_extra_roots(tmp_path):
    """When build() rejects, the runtime-registered allow-list must
    not have accreted entries. This guards the case where a future
    refactor moves add_allowed_root() into the confinement path and
    forgets to roll back on rejection.
    """
    # Snapshot the extras set.
    before = frozenset(file_source._EXTRA_ALLOWED_ROOTS)
    # Try to build a known-bad path with autouse tmp_path admitted, so
    # only an EXPLICITLY-bad path triggers rejection.
    outside_dir = tmp_path.parent / "outside_leak_test"
    outside_dir.mkdir(exist_ok=True)
    bad = outside_dir / "x.md"
    bad.write_text("- [ ] x\n")
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source.build({"path": str(bad), "parser_name": "tasks"})
    after = frozenset(file_source._EXTRA_ALLOWED_ROOTS)
    assert before == after, (
        f"rejection leaked allow-list entries; before={before} after={after}"
    )


def test_engine_spawn_with_disallowed_path_yields_dead_node(tmp_path):
    """End-to-end via the engine: spawning a FileSource with an
    out-of-allow-list path produces a dead node with a clear error,
    and the engine's node registry still tracks it (so the next
    precompute won't crash trying to re-read).

    Use the autouse-admitted tmp_path then point at a sibling outside
    dir for the rejection."""
    from engine import Engine

    e = Engine(root_dir=ROOT)
    e.discover()
    outside_dir = tmp_path.parent / "engine_spawn_outside"
    outside_dir.mkdir(exist_ok=True)
    bad = outside_dir / "x.md"
    bad.write_text("- [ ] x\n")
    e.spawn(
        "bad_src", "FileSource",
        params={"path": str(bad), "parser_name": "tasks"},
    )
    node = e.nodes.get("bad_src")
    assert node is not None
    assert node.dead is True
    assert "outside" in (node.error or "").lower()


# ---------------------------------------------------------------------------
# Runtime allow-list registration round-trip.
# ---------------------------------------------------------------------------


@pytest.mark.no_file_source_tmp
def test_add_allowed_root_admits_subsequently_built_path(tmp_path):
    """Registering an extra root via add_allowed_root admits paths
    inside it. Verified by adding tmp_path then building a file
    inside it that would otherwise be rejected."""
    f = tmp_path / "data.md"
    f.write_text("- [ ] alpha\n")
    # Without the add, rejection.
    with pytest.raises(FileSourceOutsideAllowListError):
        file_source.build({"path": str(f), "parser_name": "tasks"})
    file_source.add_allowed_root(tmp_path)
    try:
        state = file_source.build({"path": str(f), "parser_name": "tasks"})
        assert state["path"] == str(f.resolve())
    finally:
        file_source.clear_extra_allowed_roots()


@pytest.mark.no_file_source_tmp
def test_clear_extra_allowed_roots_removes_registered_entries(tmp_path):
    file_source.add_allowed_root(tmp_path)
    assert tmp_path.resolve() in file_source._EXTRA_ALLOWED_ROOTS
    file_source.clear_extra_allowed_roots()
    assert tmp_path.resolve() not in file_source._EXTRA_ALLOWED_ROOTS


@pytest.mark.no_file_source_tmp
def test_add_allowed_root_rejects_empty_and_none():
    with pytest.raises(ValueError):
        file_source.add_allowed_root(None)
    with pytest.raises(ValueError):
        file_source.add_allowed_root("")
    with pytest.raises(ValueError):
        file_source.add_allowed_root("   ")


# ---------------------------------------------------------------------------
# Env-var override.
# ---------------------------------------------------------------------------


@pytest.mark.no_file_source_tmp
def test_env_var_extends_allow_list(tmp_path, monkeypatch):
    extra = tmp_path / "via_env"
    extra.mkdir()
    monkeypatch.setenv("APEIRON_FILE_SOURCE_EXTRA_ALLOWED_ROOTS", str(extra))
    f = extra / "data.md"
    f.write_text("- [ ] alpha\n")
    state = file_source.build({"path": str(f), "parser_name": "tasks"})
    assert state["path"] == str(f.resolve())
