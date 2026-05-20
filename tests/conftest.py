"""
Pytest fixtures shared across the Apeiron test suite.

Currently provides one autouse hook: every test's ``tmp_path`` is
registered with FileSource's allow-list at setup and the registry is
cleared at teardown. Without this, the path-confinement gate added in
the SPEC-079 follow-up (2026-05-20) would reject every test that
constructs a FileSource against a ``tmp_path`` fixture.

The autouse fixture is opt-out via ``@pytest.mark.no_file_source_tmp``
in case a test wants to assert rejection of a tmp_path that ISN'T in
the allow-list. The path-confinement tests in
``tests/test_file_source_path_confinement.py`` use that marker to keep
the gate behavior exercise-able from inside the suite.
"""

from __future__ import annotations

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


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "no_file_source_tmp: opt out of the autouse fixture that adds "
        "tmp_path to FileSource's allow-list. Use for tests that "
        "exercise the rejection path itself.",
    )
