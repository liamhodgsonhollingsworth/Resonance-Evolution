"""
Pytest fixtures shared across the Apeiron test suite.

Provides two autouse hooks:

1. ``_file_source_tmp_path_allow`` — registers every test's
   ``tmp_path`` with FileSource's allow-list (SPEC-079 follow-up).
   Opt out with ``@pytest.mark.no_file_source_tmp``.

2. ``_node_history_in_tmp`` — redirects every history write triggered
   during the test to ``tmp_path/state/node_history`` so the repo's
   real ``state/node_history`` directory stays clean across the
   suite (SPEC-076).
"""

from __future__ import annotations

import os

import pytest

from node_types import file_source


@pytest.fixture(autouse=True)
def _file_source_tmp_path_allow(request, tmp_path):
    """Autouse: register the test's tmp_path with FileSource's
    allow-list, then clear after the test.

    Tests can opt out with ``@pytest.mark.no_file_source_tmp`` when
    they want to verify the rejection path itself.
    """
    if request.node.get_closest_marker("no_file_source_tmp"):
        # Test wants to drive the allow-list itself. Still clear any
        # leftovers from a previous test, then yield without
        # registering.
        file_source.clear_extra_allowed_roots()
        yield
        file_source.clear_extra_allowed_roots()
        return
    file_source.add_allowed_root(tmp_path)
    yield
    file_source.clear_extra_allowed_roots()


@pytest.fixture(autouse=True)
def _node_history_in_tmp(tmp_path, monkeypatch):
    """Autouse: redirect engine history writes to ``tmp_path`` so the
    repo's ``state/node_history`` directory stays clean across the
    suite (SPEC-076).

    The override is consumed by ``tools.node_history.history_dir``,
    which checks the env var on every call. Cleared by monkeypatch
    teardown.
    """
    monkeypatch.setenv("APEIRON_NODE_HISTORY_ROOT_OVERRIDE", str(tmp_path))
    yield


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "no_file_source_tmp: opt out of the autouse fixture that adds "
        "tmp_path to FileSource's allow-list. Use for tests that "
        "exercise the rejection path itself.",
    )
