# Apeiron tests

Default `pytest` run covers unit and integration tests. Specialised
categories live alongside them but are excluded from the default run via
pytest marks declared in `pyproject.toml` (`tool.pytest.ini_options.addopts
= "-m 'not supervisor'"`).

## Categories

| Category | Mark | Files | How to run |
|---|---|---|---|
| Default suite | _(none)_ | `tests/test_*.py` | `pytest` |
| Supervisor-level (real subprocesses, OS-level lifecycle) | `supervisor` | `tests/test_streamjson_orphan_cleanup.py` | `pytest -m supervisor` |

## Supervisor-level tests

These spawn real child processes and exercise OS-level lifecycle events
(`taskkill /F` on Windows, `SIGKILL` on POSIX). They are slower and can
leave orphaned processes if interrupted, so they sit out of the default
run. Each supervisor test must self-isolate via a `finally` block that
kills any subprocesses it spawned before returning.

The pattern: a child Python harness constructs the subject (e.g.
`SessionManager`), spawns the subprocess of interest, publishes the PIDs
to a temp file, then sleeps. The test reads the PIDs, kills the harness
with a non-catchable signal, then probes the OS process table to see
whether the subprocess survived. Origin: deferred-concerns entry #20
(SPEC-022 stream-json subprocess orphan cleanup).

Add new supervisor tests by giving them `pytestmark = pytest.mark.supervisor`
at module level and following the spawn-publish-kill-probe shape used in
`test_streamjson_orphan_cleanup.py`.
