"""Tests for ``tools.workflow.diagnose_inbox_loop`` — guard against the
self-match regression where a ping file matched as its own reply because
the body contained the literal string ``to: diagnose-inbox-loop`` as
part of an instructional template.
"""

from __future__ import annotations

from pathlib import Path

import pytest

from tools.workflow.diagnose_inbox_loop import (
    _TO_DIAG_FRONTMATTER_RE,
    _find_reply,
)


def _write(p: Path, body: str) -> Path:
    p.write_text(body, encoding="utf-8")
    return p


# ----- regex unit tests -----


def test_regex_matches_real_frontmatter():
    text = (
        "---\n"
        "to: diagnose-inbox-loop\n"
        "from: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "kind: chat\n"
        "summary: \"diag-reply abc123\"\n"
        "---\n\n"
        "abc123\n"
    )
    assert _TO_DIAG_FRONTMATTER_RE.search(text) is not None


def test_regex_does_not_match_body_instruction():
    """A ping file's body contains ``  to: diagnose-inbox-loop`` (with
    leading whitespace) as part of the reply-template instruction. That
    must NOT match because the regex anchors at line start."""
    text = (
        "---\n"
        "to: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "from: diagnose-inbox-loop\n"
        "kind: chat\n"
        "summary: \"ping abc123\"\n"
        "---\n\n"
        "Please reply by writing an inbox file with:\n"
        "  to: diagnose-inbox-loop\n"
        "  from: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "Token: abc123\n"
    )
    assert _TO_DIAG_FRONTMATTER_RE.search(text) is None


def test_regex_does_not_match_to_uuid():
    text = "to: 779de374-e203-4f36-bebb-b7486037fa40\n"
    assert _TO_DIAG_FRONTMATTER_RE.search(text) is None


# ----- _find_reply integration -----


def test_find_reply_returns_real_reply(tmp_path):
    ping = _write(
        tmp_path / "inbox_msg_20260521_120000_ping.md",
        "---\n"
        "to: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "from: diagnose-inbox-loop\n"
        "kind: chat\n"
        "summary: \"ping\"\n"
        "---\n\n"
        "Please reply with token in body.\n"
        "  to: diagnose-inbox-loop\n"
        "Token: abc123\n",
    )
    reply = _write(
        tmp_path / "inbox_msg_20260521_120010_reply.md",
        "---\n"
        "to: diagnose-inbox-loop\n"
        "from: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "kind: chat\n"
        "summary: \"diag-reply abc123\"\n"
        "---\n\n"
        "abc123\n",
    )
    found = _find_reply(tmp_path, "abc123", since_ts=0)
    assert found == reply


def test_find_reply_does_not_self_match(tmp_path):
    """The ping file's own body contains the token AND the literal string
    ``to: diagnose-inbox-loop`` (as part of the reply template). The
    regex anchoring AND the exclude_paths set both defend against this.
    """
    ping = _write(
        tmp_path / "inbox_msg_20260521_120000_ping.md",
        "---\n"
        "to: 779de374-e203-4f36-bebb-b7486037fa40\n"
        "from: diagnose-inbox-loop\n"
        "kind: chat\n"
        "summary: \"ping with token abc123\"\n"
        "---\n\n"
        "Please reply by writing an inbox file with:\n"
        "  to: diagnose-inbox-loop\n"
        "Token: abc123\n",
    )
    # Regex anchoring alone defends — even without exclude_paths.
    found = _find_reply(tmp_path, "abc123", since_ts=0)
    assert found is None
    # exclude_paths is defense-in-depth: if a future template change
    # accidentally puts ``to: diagnose-inbox-loop`` at column 0 in the
    # body, the exclusion still protects.
    found = _find_reply(tmp_path, "abc123", since_ts=0, exclude_paths={ping})
    assert found is None


def test_find_reply_ignores_older_files(tmp_path):
    old = _write(
        tmp_path / "inbox_msg_20260520_120000_old_reply.md",
        "---\n"
        "to: diagnose-inbox-loop\n"
        "from: someone\n"
        "summary: \"old\"\n"
        "---\n\n"
        "abc123\n",
    )
    # Backdate the file by setting mtime to 1 hour ago.
    import os, time
    one_hour_ago = time.time() - 3600
    os.utime(old, (one_hour_ago, one_hour_ago))
    found = _find_reply(tmp_path, "abc123", since_ts=time.time() - 60)
    assert found is None
