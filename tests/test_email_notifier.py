"""
Tests for the email side-channel notifier — SPEC-078, phase 1.

Discipline: NO test ever reaches a real SMTP server. Every test that
exercises the send path uses a fake SMTP factory that records the call
or raises a controlled exception. The maintainer's inbox stays empty
during ``pytest``.
"""

from __future__ import annotations

import json
import os
import smtplib
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import pytest

from tools import email_notifier
from tools.email_notifier import (
    BLOCK,
    DEFAULT_PASSWORD_ENV,
    DONE,
    EMAIL_DISABLED_ENV,
    HEADS_UP,
    QUARANTINE,
    REVIEW,
    SECURITY,
    SESSION_READY,
    SUBJECT_PREFIXES,
    EmailConfig,
    EmailNotifier,
    EmailNotifierError,
    PendingTrigger,
    SendResult,
    append_pending_trigger,
    build_notifier,
    config_path,
    format_subject,
    list_pending_email_triggers,
    load_config,
    save_config,
)


# ---------------------------------------------------------------------------
# Fake SMTP infrastructure — every send-path test uses this, never a
# real server.
# ---------------------------------------------------------------------------


class _RecordedCall:
    def __init__(self) -> None:
        self.host: str = ""
        self.port: int = 0
        self.user: str = ""
        self.password_present: bool = False
        self.password_value: str = ""  # captured only so tests can assert redaction
        self.send_message_called: bool = False
        self.sent_subject: Optional[str] = None
        self.sent_from: Optional[str] = None
        self.sent_to: Optional[str] = None
        self.login_raises: Optional[Exception] = None
        self.send_raises: Optional[Exception] = None
        self.quit_called: bool = False


class _FakeSMTP:
    """Context-manager fake matching ``smtplib.SMTP_SSL``'s surface.

    Records calls into a shared :class:`_RecordedCall` and optionally
    raises pre-injected exceptions to exercise failure paths.
    """

    def __init__(self, host: str, port: int, context=None, timeout=None,
                 *, recorder: _RecordedCall) -> None:
        self._recorder = recorder
        self._recorder.host = host
        self._recorder.port = port

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        self._recorder.quit_called = True
        return False

    def login(self, user, password):
        self._recorder.user = user
        self._recorder.password_present = bool(password)
        self._recorder.password_value = password
        if self._recorder.login_raises:
            raise self._recorder.login_raises
        return (235, b"Authentication successful")

    def send_message(self, msg):
        if self._recorder.send_raises:
            raise self._recorder.send_raises
        self._recorder.send_message_called = True
        self._recorder.sent_subject = msg["Subject"]
        self._recorder.sent_from = msg["From"]
        self._recorder.sent_to = msg["To"]
        return {}


def _make_factory(recorder: _RecordedCall):
    def factory(host, port, context=None, timeout=None):
        return _FakeSMTP(host, port, context=context, timeout=timeout,
                         recorder=recorder)
    return factory


def _baseline_config(**overrides) -> EmailConfig:
    base = dict(
        from_addr="Apeiron <apeiron.notifier@example.com>",
        smtp_host="smtp.example.com",
        smtp_port=465,
        smtp_user="apeiron.notifier@example.com",
        smtp_password_env="APEIRON_SMTP_PASSWORD_TEST",
        to_default="liamnhodgson@example.com",
        enabled=True,
    )
    base.update(overrides)
    return EmailConfig(**base)


@contextmanager
def _env(**kvs: str):
    """Temporarily set/unset env vars; restore on exit."""
    sentinel = object()
    prev: Dict[str, Any] = {}
    for k, v in kvs.items():
        prev[k] = os.environ.get(k, sentinel)
        if v is None:
            os.environ.pop(k, None)
        else:
            os.environ[k] = v
    try:
        yield
    finally:
        for k, v in prev.items():
            if v is sentinel:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


@pytest.fixture(autouse=True)
def _isolate_env():
    """Strip the env-disable flag + the password env around every test."""
    with _env(
        APEIRON_EMAIL_DISABLED=None,
        APEIRON_SMTP_PASSWORD=None,
        APEIRON_SMTP_PASSWORD_TEST="hunter2-test-only",
    ):
        yield


# ---------------------------------------------------------------------------
# Constant + prefix tests.
# ---------------------------------------------------------------------------


class TestSubjectPrefixConstants:
    def test_seven_prefix_constants_exist(self):
        """Every documented prefix is exported as a module constant."""
        # Each constant is a plain string (not an Enum) per the spec.
        assert BLOCK == "block"
        assert REVIEW == "review"
        assert HEADS_UP == "heads-up"
        assert DONE == "done"
        assert SECURITY == "security"
        assert QUARANTINE == "quarantine"
        assert SESSION_READY == "session-ready"

    def test_subject_prefixes_tuple_contains_all_seven(self):
        assert set(SUBJECT_PREFIXES) == {
            BLOCK, REVIEW, HEADS_UP, DONE,
            SECURITY, QUARANTINE, SESSION_READY,
        }
        assert len(SUBJECT_PREFIXES) == 7

    def test_constants_are_str(self):
        for p in SUBJECT_PREFIXES:
            assert isinstance(p, str)
            assert p == p.lower(), f"prefix {p!r} not lowercased"


# ---------------------------------------------------------------------------
# Subject formatting.
# ---------------------------------------------------------------------------


class TestSubjectFormatting:
    @pytest.mark.parametrize("prefix", list(SUBJECT_PREFIXES))
    def test_format_subject_each_prefix(self, prefix):
        subj = format_subject(prefix, "hello world")
        assert subj.startswith(f"[apeiron:{prefix}] ")
        assert "hello world" in subj

    def test_format_subject_truncates_long_body(self):
        body = "x" * 200
        subj = format_subject(BLOCK, body)
        # Bracketed prefix + truncated body + ellipsis stays well under 110.
        assert len(subj) <= 110
        assert "…" in subj

    def test_format_subject_strips_newlines(self):
        subj = format_subject(BLOCK, "line one\nline two\nline three")
        assert "\n" not in subj
        assert "line one line two line three" in subj

    def test_format_subject_unknown_prefix_raises(self):
        with pytest.raises(EmailNotifierError) as exc:
            format_subject("not-a-real-prefix", "body")
        assert "unknown subject prefix" in str(exc.value)


# ---------------------------------------------------------------------------
# Config load / save.
# ---------------------------------------------------------------------------


class TestEmailConfig:
    def test_load_missing_file_returns_disabled_default(self, tmp_path):
        cfg = load_config(tmp_path)
        assert cfg.enabled is False
        assert cfg.smtp_password_env == DEFAULT_PASSWORD_ENV
        assert cfg.from_addr == ""

    def test_save_then_load_round_trips(self, tmp_path):
        cfg = _baseline_config()
        save_config(cfg, tmp_path)
        loaded = load_config(tmp_path)
        assert loaded == cfg

    def test_save_never_writes_password(self, tmp_path):
        """Even if the dataclass dict were corrupted, save_config strips.

        The legitimate ``smtp_password_env`` field IS present (it names
        the env var, not the value). What must never appear: the actual
        password string, or any non-env-namespaced password / secret
        field.
        """
        cfg = _baseline_config()
        path = save_config(cfg, tmp_path)
        text = path.read_text(encoding="utf-8")
        # The password VALUE never appears on disk.
        assert "hunter2-test-only" not in text
        # The forbidden bare keys never appear (`smtp_password` would be
        # the bug; `smtp_password_env` is fine because it's an env-var
        # name, not the secret).
        data = json.loads(text)
        for forbidden_key in ("smtp_password", "password", "secret"):
            assert forbidden_key not in data, (
                f"forbidden key {forbidden_key!r} appeared in saved config"
            )

    def test_load_rejects_password_field_in_json(self, tmp_path):
        """Defensive: someone hand-edits the JSON with a password."""
        path = config_path(tmp_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "from_addr": "a@b",
            "smtp_host": "x",
            "smtp_port": 465,
            "smtp_user": "u",
            "smtp_password_env": "X",
            "smtp_password": "leaked-secret",  # noqa: this is the test input
            "to_default": "t",
            "enabled": True,
            "version": 1,
        }))
        with pytest.raises(EmailNotifierError) as exc:
            load_config(tmp_path)
        msg = str(exc.value).lower()
        assert "smtp_password" in msg
        assert "env var" in msg

    def test_load_rejects_malformed_json(self, tmp_path):
        path = config_path(tmp_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("{not valid json", encoding="utf-8")
        with pytest.raises(EmailNotifierError) as exc:
            load_config(tmp_path)
        assert "not valid JSON" in str(exc.value)

    def test_load_rejects_non_object_json(self, tmp_path):
        path = config_path(tmp_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("[1, 2, 3]")
        with pytest.raises(EmailNotifierError) as exc:
            load_config(tmp_path)
        assert "JSON object" in str(exc.value)

    def test_load_rejects_unknown_field(self, tmp_path):
        path = config_path(tmp_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "from_addr": "a@b", "smtp_host": "x", "smtp_port": 465,
            "smtp_user": "u", "smtp_password_env": DEFAULT_PASSWORD_ENV,
            "to_default": "t", "enabled": False, "version": 1,
            "typo_field": "oops",
        }))
        with pytest.raises(EmailNotifierError) as exc:
            load_config(tmp_path)
        assert "typo_field" in str(exc.value)

    def test_load_rejects_unsupported_version(self, tmp_path):
        path = config_path(tmp_path)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({
            "from_addr": "a@b", "smtp_host": "x", "smtp_port": 465,
            "smtp_user": "u", "smtp_password_env": DEFAULT_PASSWORD_ENV,
            "to_default": "t", "enabled": False, "version": 99,
        }))
        with pytest.raises(EmailNotifierError) as exc:
            load_config(tmp_path)
        assert "version" in str(exc.value)


# ---------------------------------------------------------------------------
# Env-var password lookup.
# ---------------------------------------------------------------------------


class TestPasswordLookup:
    def test_resolve_password_reads_from_configured_env(self, tmp_path):
        cfg = _baseline_config()
        notifier = EmailNotifier(cfg, state_dir=tmp_path)
        # The fixture sets APEIRON_SMTP_PASSWORD_TEST=hunter2-test-only.
        assert notifier._resolve_password() == "hunter2-test-only"

    def test_resolve_password_missing_env_raises_clear_error(self, tmp_path):
        cfg = _baseline_config(smtp_password_env="APEIRON_NEVER_SET_ME")
        notifier = EmailNotifier(cfg, state_dir=tmp_path)
        with pytest.raises(EmailNotifierError) as exc:
            notifier._resolve_password()
        msg = str(exc.value)
        assert "APEIRON_NEVER_SET_ME" in msg
        assert "unset or empty" in msg
        # Never leak any partial real password.
        assert "hunter2" not in msg

    def test_resolve_password_empty_env_var_raises(self, tmp_path):
        cfg = _baseline_config(smtp_password_env="APEIRON_EMPTY_VAR")
        notifier = EmailNotifier(cfg, state_dir=tmp_path)
        with _env(APEIRON_EMPTY_VAR=""):
            with pytest.raises(EmailNotifierError):
                notifier._resolve_password()


# ---------------------------------------------------------------------------
# Send path — dry-run, disabled, env-disabled.
# ---------------------------------------------------------------------------


class TestSendDryRun:
    def test_dry_run_does_not_call_send_message(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        result = notifier.send(
            HEADS_UP, "dry-run probe", "body", dry_run=True,
        )
        assert result.sent is False
        assert result.reason == "dry-run"
        assert recorder.send_message_called is False
        # Connection + auth still happened.
        assert recorder.host == "smtp.example.com"
        assert recorder.port == 465
        assert recorder.user == "apeiron.notifier@example.com"
        assert recorder.password_present is True
        assert recorder.quit_called is True

    def test_dry_run_records_pending_trigger(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        notifier.send(REVIEW, "review me", "body", dry_run=True,
                      source="probe")
        pending = list_pending_email_triggers(tmp_path)
        assert any(p.reason == "dry-run" and p.subject_prefix == REVIEW
                   for p in pending)

    def test_dry_run_works_even_when_disabled(self, tmp_path):
        """Dry-run probes the wiring; it's the one path that ignores
        the disabled flag (so a fresh setup can be tested)."""
        recorder = _RecordedCall()
        cfg = _baseline_config(enabled=False)
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        result = notifier.send(BLOCK, "blocked", "body", dry_run=True)
        assert result.sent is False
        assert result.reason == "dry-run"
        assert recorder.send_message_called is False


class TestSendDisabledPaths:
    def test_send_when_disabled_does_not_dispatch(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(enabled=False)
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        result = notifier.send(BLOCK, "x", "body")
        assert result.sent is False
        assert result.reason == "disabled"
        assert recorder.send_message_called is False

    def test_disabled_records_pending(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(enabled=False)
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        notifier.send(DONE, "merged", "body", source="ci")
        pending = list_pending_email_triggers(tmp_path)
        assert len(pending) == 1
        assert pending[0].subject_prefix == DONE
        assert pending[0].reason == "disabled"
        assert pending[0].source == "ci"

    def test_env_disable_blocks_even_enabled_config(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(enabled=True)
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with _env(APEIRON_EMAIL_DISABLED="1"):
            result = notifier.send(BLOCK, "x", "body")
        assert result.sent is False
        assert result.reason == "env-disabled"
        assert recorder.send_message_called is False


# ---------------------------------------------------------------------------
# Send path — happy path via mock SMTP.
# ---------------------------------------------------------------------------


class TestSendHappyPath:
    def test_send_dispatches_through_mock_smtp(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        result = notifier.send(SECURITY, "injection caught", "body details")
        assert result.sent is True
        assert result.reason == "ok"
        assert recorder.send_message_called is True
        assert recorder.sent_subject is not None
        assert recorder.sent_subject.startswith("[apeiron:security] ")
        assert recorder.sent_to == "liamnhodgson@example.com"

    def test_send_uses_to_override(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        notifier.send(HEADS_UP, "fyi", "body",
                      to_addr="someone-else@example.com")
        assert recorder.sent_to == "someone-else@example.com"

    def test_send_log_appended_on_success(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        notifier.send(QUARANTINE, "aggregate", "body")
        log_path = email_notifier.send_log_path(tmp_path)
        assert log_path.exists()
        rows = [json.loads(line) for line in log_path.read_text().splitlines() if line]
        assert rows[-1]["sent"] is True
        assert rows[-1]["subject"].startswith("[apeiron:quarantine] ")


# ---------------------------------------------------------------------------
# Send path — failure modes raise EmailNotifierError.
# ---------------------------------------------------------------------------


class TestSendFailureModes:
    def test_auth_failure_raises_email_notifier_error(self, tmp_path):
        recorder = _RecordedCall()
        recorder.login_raises = smtplib.SMTPAuthenticationError(
            535, b"5.7.8 Username and Password not accepted"
        )
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with pytest.raises(EmailNotifierError) as exc:
            notifier.send(BLOCK, "x", "body")
        assert "SMTP send failed" in str(exc.value)
        # The password value should NEVER appear in the error message
        # even when SMTP echoes back something containing it.
        assert "hunter2-test-only" not in str(exc.value)

    def test_password_redacted_in_smtp_error_messages(self, tmp_path):
        recorder = _RecordedCall()
        # An SMTP exception whose message literally contains the password.
        recorder.login_raises = smtplib.SMTPException(
            "auth failed for hunter2-test-only on server"
        )
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with pytest.raises(EmailNotifierError) as exc:
            notifier.send(BLOCK, "x", "body")
        msg = str(exc.value)
        assert "hunter2-test-only" not in msg
        assert "<redacted>" in msg

    def test_send_without_to_addr_raises(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(to_default="")
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with pytest.raises(EmailNotifierError) as exc:
            notifier.send(BLOCK, "x", "body")
        assert "recipient" in str(exc.value).lower()

    def test_send_without_smtp_host_raises(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(smtp_host="")
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with pytest.raises(EmailNotifierError) as exc:
            notifier.send(BLOCK, "x", "body")
        assert "SMTP host" in str(exc.value)

    def test_send_without_password_env_raises(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(smtp_password_env="APEIRON_NEVER_SET_ME")
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        with pytest.raises(EmailNotifierError) as exc:
            notifier.send(BLOCK, "x", "body")
        assert "APEIRON_NEVER_SET_ME" in str(exc.value)


# ---------------------------------------------------------------------------
# Probe — what the ready-check verb calls.
# ---------------------------------------------------------------------------


class TestProbeConnection:
    def test_probe_skipped_when_disabled(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config(enabled=False)
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        ok, msg = notifier.probe_connection()
        assert ok is True
        assert "disabled" in msg
        assert recorder.user == ""  # never even connected

    def test_probe_ok_with_valid_credentials(self, tmp_path):
        recorder = _RecordedCall()
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        ok, msg = notifier.probe_connection()
        assert ok is True
        assert "SMTP ready" in msg
        assert recorder.send_message_called is False  # probe never sends

    def test_probe_returns_false_on_auth_failure(self, tmp_path):
        recorder = _RecordedCall()
        recorder.login_raises = smtplib.SMTPAuthenticationError(535, b"bad pw")
        cfg = _baseline_config()
        notifier = EmailNotifier(
            cfg, state_dir=tmp_path, smtp_factory=_make_factory(recorder),
        )
        ok, msg = notifier.probe_connection()
        assert ok is False
        assert "SMTP probe failed" in msg
        # Probe never raises — it returns (False, reason).

    def test_probe_returns_false_when_password_env_missing(self, tmp_path):
        cfg = _baseline_config(smtp_password_env="APEIRON_NEVER_SET_ME")
        notifier = EmailNotifier(cfg, state_dir=tmp_path)
        ok, msg = notifier.probe_connection()
        assert ok is False
        assert "APEIRON_NEVER_SET_ME" in msg


# ---------------------------------------------------------------------------
# Pending-trigger registry.
# ---------------------------------------------------------------------------


class TestPendingTriggers:
    def test_append_and_list(self, tmp_path):
        append_pending_trigger(BLOCK, "stuck", "manual",
                               source="test", state_dir=tmp_path)
        append_pending_trigger(REVIEW, "decision", "manual",
                               source="test", state_dir=tmp_path)
        rows = list_pending_email_triggers(tmp_path)
        assert len(rows) == 2
        assert rows[0].subject_prefix == BLOCK
        assert rows[1].subject_prefix == REVIEW

    def test_unknown_prefix_rejected(self, tmp_path):
        with pytest.raises(EmailNotifierError):
            append_pending_trigger("not-a-prefix", "x", "manual",
                                   state_dir=tmp_path)

    def test_list_tolerant_of_malformed_lines(self, tmp_path):
        append_pending_trigger(BLOCK, "ok", "manual", state_dir=tmp_path)
        # Corrupt the file with a malformed row.
        path = email_notifier.pending_path(tmp_path)
        with path.open("a", encoding="utf-8") as fh:
            fh.write("not-valid-json\n")
            fh.write("{\"not\": \"a trigger row\"}\n")
        rows = list_pending_email_triggers(tmp_path)
        # The good row survives; the malformed lines are dropped silently
        # but the second row is "valid JSON, wrong shape" — gets accepted
        # as PendingTrigger with mostly empty fields. Either is fine as
        # long as the parser doesn't raise + the good row is present.
        assert any(r.subject_prefix == BLOCK for r in rows)


# ---------------------------------------------------------------------------
# CLI verbs — subprocess invocation.
# ---------------------------------------------------------------------------


def _cli(*args: str, env_extra: Optional[Dict[str, str]] = None) -> subprocess.CompletedProcess:
    """Run ``python -m tools.email_notifier`` with the given args."""
    env = os.environ.copy()
    env["PYTHONPATH"] = str(Path(__file__).parent.parent)
    env["APEIRON_EMAIL_DISABLED"] = "1"  # belt-and-suspenders
    if env_extra:
        env.update(env_extra)
    return subprocess.run(
        [sys.executable, "-m", "tools.email_notifier", *args],
        capture_output=True, text=True, env=env, timeout=30,
    )


class TestCLI:
    def test_configure_email_writes_config(self, tmp_path):
        result = _cli(
            "--state-dir", str(tmp_path),
            "configure-email",
            "Apeiron <a@b>",
            "smtp.example.com",
            "465",
            "--to-default", "liam@example.com",
        )
        assert result.returncode == 0, result.stderr
        cfg = load_config(tmp_path)
        assert cfg.smtp_host == "smtp.example.com"
        assert cfg.to_default == "liam@example.com"
        assert cfg.enabled is False

    def test_configure_email_with_enable_flag(self, tmp_path):
        result = _cli(
            "--state-dir", str(tmp_path),
            "configure-email",
            "Apeiron <a@b>", "smtp.example.com", "465",
            "--to-default", "liam@example.com",
            "--enable",
        )
        assert result.returncode == 0
        assert load_config(tmp_path).enabled is True

    def test_configure_email_never_writes_password(self, tmp_path):
        _cli(
            "--state-dir", str(tmp_path),
            "configure-email",
            "Apeiron <a@b>", "smtp.example.com", "465",
            "--to-default", "liam@example.com",
            env_extra={"APEIRON_SMTP_PASSWORD": "secret-pw-123"},
        )
        text = config_path(tmp_path).read_text(encoding="utf-8")
        assert "secret-pw-123" not in text

    def test_send_test_email_with_disabled_config_exits_2(self, tmp_path):
        # Write a disabled config first.
        save_config(_baseline_config(enabled=False), tmp_path)
        result = _cli(
            "--state-dir", str(tmp_path),
            "send-test-email",
        )
        assert result.returncode == 2
        assert "disabled" in result.stderr.lower()

    def test_list_pending_email_triggers_lists_appended(self, tmp_path):
        append_pending_trigger(BLOCK, "test summary", "manual",
                               source="unit-test", state_dir=tmp_path)
        result = _cli(
            "--state-dir", str(tmp_path),
            "list-pending-email-triggers",
        )
        assert result.returncode == 0
        assert "apeiron:block" in result.stdout
        assert "unit-test" in result.stdout

    def test_list_pending_email_triggers_empty(self, tmp_path):
        result = _cli(
            "--state-dir", str(tmp_path),
            "list-pending-email-triggers",
        )
        assert result.returncode == 0
        assert "no pending" in result.stdout.lower()


# ---------------------------------------------------------------------------
# text-API verbs (SPEC-081 obligation).
# ---------------------------------------------------------------------------


class TestTextApiVerbs:
    """The text-API verbs route through ``tools.text_test.dispatch_command``.

    Each verb must dispatch cleanly + propagate failures with an ERR:
    prefix per the existing convention.
    """

    def test_send_test_email_verb_with_disabled_config(self, tmp_path):
        save_config(_baseline_config(enabled=False), tmp_path)
        from engine import Engine
        from tools.text_test import dispatch_command
        e = Engine(root_dir=Path(__file__).parent.parent)
        # The verb takes the state-dir via a flag in the command string.
        msg, _ = dispatch_command(
            e, f"send-test-email someone@example.com --state-dir {tmp_path}"
        )
        # Disabled config → ERR with "disabled" reason.
        assert "ERR" in msg
        assert "disabled" in msg.lower()

    def test_send_test_email_verb_dry_run_succeeds(self, tmp_path,
                                                    monkeypatch):
        save_config(_baseline_config(), tmp_path)
        # Inject a fake smtp factory globally so the dry-run probe never
        # touches a real server. monkeypatch handles teardown.
        recorder = _RecordedCall()
        monkeypatch.setattr(
            email_notifier.smtplib, "SMTP_SSL",
            _make_factory(recorder),
        )
        from engine import Engine
        from tools.text_test import dispatch_command
        e = Engine(root_dir=Path(__file__).parent.parent)
        msg, _ = dispatch_command(
            e,
            f"send-test-email someone@example.com --state-dir {tmp_path} --dry-run",
        )
        assert "OK" in msg or "dry-run" in msg.lower()
        assert recorder.send_message_called is False

    def test_list_pending_email_triggers_verb_works(self, tmp_path):
        append_pending_trigger(SECURITY, "scan flagged", "manual",
                               source="test", state_dir=tmp_path)
        from engine import Engine
        from tools.text_test import dispatch_command
        e = Engine(root_dir=Path(__file__).parent.parent)
        msg, _ = dispatch_command(
            e, f"list-pending-email-triggers --state-dir {tmp_path}",
        )
        assert "apeiron:security" in msg

    def test_configure_email_verb_writes_config(self, tmp_path):
        from engine import Engine
        from tools.text_test import dispatch_command
        e = Engine(root_dir=Path(__file__).parent.parent)
        msg, _ = dispatch_command(
            e,
            f"configure-email a@b smtp.example.com 465 --state-dir {tmp_path}",
        )
        assert "OK" in msg
        cfg = load_config(tmp_path)
        assert cfg.smtp_host == "smtp.example.com"
        assert cfg.smtp_port == 465

    def test_text_api_verbs_listed_in_list_commands(self):
        """SPEC-081: every GUI / text-API verb is enumerable so headless
        callers can discover it."""
        from engine import Engine
        from tools.text_test import dispatch_command
        e = Engine(root_dir=Path(__file__).parent.parent)
        msg, _ = dispatch_command(e, "list-commands")
        assert "send-test-email" in msg
        assert "list-pending-email-triggers" in msg
        assert "configure-email" in msg


# ---------------------------------------------------------------------------
# Ready-check probe.
# ---------------------------------------------------------------------------


class TestReadyCheckProbe:
    def test_probe_function_exists_and_is_callable(self):
        from tools.ready_check import _check_email_side_channel
        assert callable(_check_email_side_channel)

    def test_probe_registered_in_CHECKS(self):
        """SPEC-064: the probe must be in the master CHECKS list."""
        from tools.ready_check import CHECKS
        names = {name for name, _ in CHECKS}
        assert "email_side_channel" in names

    def test_probe_returns_ok_when_no_config(self, monkeypatch, tmp_path):
        """Fresh checkout: no email_config.json. Probe should pass
        (email is optional) with a skip message."""
        from tools import ready_check
        monkeypatch.setattr(ready_check, "ROOT", tmp_path)
        ok, msg = ready_check._check_email_side_channel(verbose=False)
        assert ok is True
        assert "skipped" in msg.lower() or "not present" in msg.lower()

    def test_probe_passes_with_enabled_config_and_mock_smtp(
        self, monkeypatch, tmp_path
    ):
        """Enabled config + a fake SMTP that accepts credentials → OK.

        Verifies the probe uses dry-run (never sends) and reports a
        success message naming the host.
        """
        # Save config into tmp_path/state to mirror the real layout.
        save_config(_baseline_config(), tmp_path / "state")
        recorder = _RecordedCall()
        monkeypatch.setattr(
            email_notifier.smtplib, "SMTP_SSL",
            _make_factory(recorder),
        )
        from tools import ready_check
        monkeypatch.setattr(ready_check, "ROOT", tmp_path)
        ok, msg = ready_check._check_email_side_channel(verbose=False)
        assert ok is True, f"probe failed unexpectedly: {msg}"
        assert "smtp" in msg.lower() or "ready" in msg.lower()
        # Critically: the probe must not have sent anything.
        assert recorder.send_message_called is False

    def test_probe_returns_false_on_auth_failure(
        self, monkeypatch, tmp_path
    ):
        save_config(_baseline_config(), tmp_path / "state")
        recorder = _RecordedCall()
        recorder.login_raises = smtplib.SMTPAuthenticationError(
            535, b"5.7.8 Username and Password not accepted"
        )
        monkeypatch.setattr(
            email_notifier.smtplib, "SMTP_SSL",
            _make_factory(recorder),
        )
        from tools import ready_check
        monkeypatch.setattr(ready_check, "ROOT", tmp_path)
        ok, msg = ready_check._check_email_side_channel(verbose=False)
        assert ok is False
        # The password value must never leak into the failure message.
        assert "hunter2-test-only" not in msg

    def test_probe_returns_true_when_present_but_disabled(
        self, monkeypatch, tmp_path
    ):
        save_config(_baseline_config(enabled=False), tmp_path / "state")
        from tools import ready_check
        monkeypatch.setattr(ready_check, "ROOT", tmp_path)
        ok, msg = ready_check._check_email_side_channel(verbose=False)
        assert ok is True
        assert "disabled" in msg.lower() or "enabled=false" in msg.lower()


# ---------------------------------------------------------------------------
# Trigger registry stub — verifies the seven prefixes are surfaceable
# from a single registry (Phase 2 wires the actual senders).
# ---------------------------------------------------------------------------


class TestTriggerRegistry:
    def test_each_prefix_can_be_appended_as_pending(self, tmp_path):
        for prefix in SUBJECT_PREFIXES:
            append_pending_trigger(prefix, f"summary for {prefix}", "stub",
                                   source="test_stub", state_dir=tmp_path)
        rows = list_pending_email_triggers(tmp_path)
        seen = {r.subject_prefix for r in rows}
        assert seen == set(SUBJECT_PREFIXES)

    def test_build_notifier_reads_disk_config(self, tmp_path):
        save_config(_baseline_config(), tmp_path)
        notifier = build_notifier(state_dir=tmp_path)
        assert isinstance(notifier, EmailNotifier)
        assert notifier.config.smtp_host == "smtp.example.com"
