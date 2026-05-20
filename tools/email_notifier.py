"""
Email side-channel notifier — SPEC-078.

Out-of-band email channel for autonomous Apeiron sessions to reach the
maintainer when blocked, asking for review, completing milestones, or
surfacing security findings. The chat surface is in-band and only
useful while the maintainer is at the workflow GUI; email is out-of-band
and reaches the maintainer's phone.

Phase 1 (this module) ships the chokepoint:

- :class:`EmailNotifier` wraps ``smtplib.SMTP_SSL`` with a single
  ``send(subject_prefix, subject_body, body)`` entry point.
- :func:`load_config` / :func:`save_config` round-trip the non-secret
  config at ``state/email_config.json``. The SMTP password lives in an
  environment variable whose name the config records (default
  ``APEIRON_SMTP_PASSWORD``); the password value itself is never written
  to disk by this module.
- Seven canonical subject prefixes are registered as module constants
  (``BLOCK``, ``REVIEW``, ``HEADS_UP``, ``DONE``, ``SECURITY``,
  ``QUARANTINE``, ``SESSION_READY``) — the maintainer's verbatim
  four extended with three trust/coordination surfaces.
- A trigger registry stub records who would have called ``send`` so the
  Phase 2 wiring lands against a stable surface.
- CLI: ``configure-email``, ``send-test-email``,
  ``list-pending-email-triggers``.
- ``--dry-run`` resolves the SMTP connection without dispatching.

Phases 2 + 3 (deferred — see the design doc at
``notes/designs/spec_078_email_side_channel_2026_05_20.md``) wire the
individual trigger sites (silence watchdog, quarantine high-severity,
ready-check, etc.) and add an optional hosted-service backend
(SendGrid / Postmark).

Subject convention
------------------

Every email's subject is formatted as::

    [apeiron:<prefix>] <body>

where ``<prefix>`` is one of the seven constants. iOS notification
previews truncate after ~50 chars but the bracketed prefix always
appears so the maintainer can recognize the kind of event before
opening the message.

Security posture
----------------

- The SMTP password is read from ``os.environ[smtp_password_env]`` at
  send time. Sessions that do not set the env var get a clear
  :class:`EmailNotifierError` rather than a silent failure.
- The notifier never logs the password value or echoes it to stdout /
  stderr. The CLI ``configure-email`` only writes the env-var *name*.
- A ``--dry-run`` flag short-circuits the actual ``send_message`` call
  so tests / probes never reach a real SMTP server.
- An env override ``APEIRON_EMAIL_DISABLED=1`` suppresses every send;
  ``pytest`` set-ups can flip this to guarantee no test ever emails the
  maintainer.
"""

from __future__ import annotations

import argparse
import json
import os
import smtplib
import ssl
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from email.message import EmailMessage
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Subject-prefix constants (the seven canonical kinds).
# ---------------------------------------------------------------------------


#: Session cannot proceed without maintainer action. Highest urgency —
#: GUI permission prompt, credential needed, ambiguous instruction.
BLOCK = "block"

#: Session made a significant decision the maintainer should weigh in
#: on. Medium urgency — decision is made but can be revised.
REVIEW = "review"

#: Informational; no action needed. Long-running operation in
#: progress, environment drift detected, optional follow-up surfaced.
HEADS_UP = "heads-up"

#: Major milestone landed — PR merged, arc closed, multi-session
#: stream completed.
DONE = "done"

#: Security finding — prompt-injection caught by quarantine scan,
#: credential leak detected by pre-push scanner, untrusted code
#: execution attempted. High urgency.
SECURITY = "security"

#: An untrusted message arrived in the quarantine (SPEC-058) and may
#: need review beyond the GUI's quarantine panel. Out-of-band escalation.
QUARANTINE = "quarantine"

#: A paired session reached a ready gate — passed ready-check,
#: finished a phase, waiting on the maintainer to open the program.
SESSION_READY = "session-ready"

#: Tuple of every recognized prefix. Public so callers can iterate /
#: validate against the canonical set.
SUBJECT_PREFIXES: Tuple[str, ...] = (
    BLOCK, REVIEW, HEADS_UP, DONE, SECURITY, QUARANTINE, SESSION_READY,
)


# ---------------------------------------------------------------------------
# Exceptions, config dataclass, and pending-trigger record.
# ---------------------------------------------------------------------------


class EmailNotifierError(Exception):
    """Raised for any non-recoverable email-notifier failure.

    Callers catch this around ``EmailNotifier.send`` so a broken SMTP
    server never deadlocks a session. The exception carries a one-line
    message safe to log (never contains the password).
    """


#: Default env-var name holding the SMTP password. Configurable per
#: setup via ``EmailConfig.smtp_password_env``.
DEFAULT_PASSWORD_ENV = "APEIRON_SMTP_PASSWORD"

#: Env var that disables every send when set to ``1``. Used by
#: ``pytest`` config + the CI runner so tests never reach real SMTP.
EMAIL_DISABLED_ENV = "APEIRON_EMAIL_DISABLED"


@dataclass
class EmailConfig:
    """Non-secret SMTP configuration for the notifier.

    Stored at ``state/email_config.json`` (gitignored by the existing
    ``state/`` rule). All fields are JSON-serializable.

    Fields:
        from_addr: The ``From:`` header value (e.g. ``"Apeiron Notifier
            <apeiron.notifier@gmail.com>"``).
        smtp_host: SMTP server hostname (e.g. ``"smtp.gmail.com"``).
        smtp_port: SMTP server port. Defaults to 465 (SMTP_SSL).
        smtp_user: SMTP auth username (typically the sending email).
        smtp_password_env: Name of the env var holding the SMTP
            password. Defaults to ``APEIRON_SMTP_PASSWORD``. The password
            *value* is never stored in this dataclass or on disk.
        to_default: Default recipient address (the maintainer's primary
            inbox). ``EmailNotifier.send`` accepts an override.
        enabled: Master switch. Defaults to False so a fresh checkout
            never emails. The maintainer flips this after running
            ``send-test-email`` successfully.
        version: Schema version. Bumped when the on-disk shape changes
            so future code can migrate or refuse to load.
    """

    from_addr: str = ""
    smtp_host: str = ""
    smtp_port: int = 465
    smtp_user: str = ""
    smtp_password_env: str = DEFAULT_PASSWORD_ENV
    to_default: str = ""
    enabled: bool = False
    version: int = 1


@dataclass
class PendingTrigger:
    """One row in the pending-trigger registry.

    Records a trigger event that *would have* called ``send`` if the
    notifier were enabled / not rate-limited. Phase 2 wires the actual
    callers; Phase 1 stubs the registry so the CLI verb has something
    to enumerate.
    """

    ts: str
    subject_prefix: str
    subject_body: str
    reason: str         # "disabled" | "dry-run" | "env-disabled" | "manual"
    source: str = ""    # caller-supplied label, e.g. "silence_watchdog"
    metadata: Dict[str, Any] = field(default_factory=dict)


@dataclass
class SendResult:
    """Outcome of an ``EmailNotifier.send`` call.

    Returned to the caller so the failure path is data, not an
    exception. Callers check ``sent`` and ``reason``; the only thing
    that raises is :class:`EmailNotifierError` for unrecoverable SMTP
    failures (auth error, no network, etc.).
    """

    sent: bool
    subject: str
    reason: str = ""       # "ok" | "dry-run" | "disabled" | "env-disabled"
    smtp_response: Optional[str] = None


# ---------------------------------------------------------------------------
# Config / pending-trigger storage paths.
# ---------------------------------------------------------------------------


CONFIG_FILENAME = "email_config.json"
PENDING_FILENAME = "email_pending.jsonl"
SEND_LOG_FILENAME = "email_send_log.jsonl"


def config_path(state_dir: Optional[Path] = None) -> Path:
    """Return the on-disk path to the email-config file.

    ``state_dir=None`` falls back to ``./state/`` relative to the
    current working directory (tests should always pass an explicit
    path).
    """
    base = Path(state_dir) if state_dir is not None else Path("state")
    return base / CONFIG_FILENAME


def pending_path(state_dir: Optional[Path] = None) -> Path:
    """Return the on-disk path to the pending-triggers JSONL file."""
    base = Path(state_dir) if state_dir is not None else Path("state")
    return base / PENDING_FILENAME


def send_log_path(state_dir: Optional[Path] = None) -> Path:
    """Return the on-disk path to the send-attempt log JSONL file."""
    base = Path(state_dir) if state_dir is not None else Path("state")
    return base / SEND_LOG_FILENAME


# ---------------------------------------------------------------------------
# Config load / save.
# ---------------------------------------------------------------------------


def _now_iso() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


def load_config(state_dir: Optional[Path] = None) -> EmailConfig:
    """Load the email config from disk.

    Returns a disabled default when the file is missing — a fresh
    checkout has no config and the caller should not crash. A malformed
    file (wrong JSON shape, wrong version) raises
    :class:`EmailNotifierError` so the caller can surface the problem
    rather than silently treating it as disabled.
    """
    path = config_path(state_dir)
    if not path.exists():
        return EmailConfig()
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise EmailNotifierError(
            f"email config at {path} is not valid JSON: {exc}"
        )
    if not isinstance(raw, dict):
        raise EmailNotifierError(
            f"email config at {path} is not a JSON object (got {type(raw).__name__})"
        )
    # The forbidden secret field — never store the password on disk.
    # Check this BEFORE the generic unknown-field check so the error
    # message is specific (this is the most likely "danger" footgun).
    if "smtp_password" in raw:
        raise EmailNotifierError(
            f"email config at {path} contains a 'smtp_password' field; "
            f"the password must live in the env var named by "
            f"'smtp_password_env' and never in the JSON. Delete the "
            f"field, move the secret to the env var, and reload."
        )
    # Reject other unknown fields rather than silently dropping them
    # — protects against typos like "smtp_user_name" (which the caller
    # might think works but won't).
    valid_keys = set(asdict(EmailConfig()).keys())
    extra = set(raw.keys()) - valid_keys
    if extra:
        raise EmailNotifierError(
            f"email config at {path} has unknown field(s): {sorted(extra)}"
        )
    try:
        cfg = EmailConfig(**raw)
    except TypeError as exc:
        raise EmailNotifierError(
            f"email config at {path} has wrong field types: {exc}"
        )
    # Light schema-version check so future migrations have a hook.
    if cfg.version != 1:
        raise EmailNotifierError(
            f"email config at {path} has unsupported version "
            f"{cfg.version!r} (this module supports version 1)"
        )
    return cfg


def save_config(
    cfg: EmailConfig,
    state_dir: Optional[Path] = None,
) -> Path:
    """Write the email config to disk atomically.

    Never writes a password field even if the caller tries to slip one
    in — only the documented :class:`EmailConfig` fields are
    serialized. Returns the path that was written.
    """
    path = config_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = asdict(cfg)
    # Defense in depth — strip anything that smells like a password
    # even though dataclass shape should already exclude it.
    for forbidden in ("smtp_password", "password", "secret"):
        payload.pop(forbidden, None)
    tmp = path.with_suffix(path.suffix + f".tmp.{os.getpid()}")
    try:
        tmp.write_text(
            json.dumps(payload, indent=2, sort_keys=True),
            encoding="utf-8",
        )
        os.replace(tmp, path)
    except Exception:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass
        raise
    return path


# ---------------------------------------------------------------------------
# Pending-trigger registry stub (Phase 2 wires real callers).
# ---------------------------------------------------------------------------


def append_pending_trigger(
    subject_prefix: str,
    subject_body: str,
    reason: str,
    *,
    source: str = "",
    metadata: Optional[Dict[str, Any]] = None,
    state_dir: Optional[Path] = None,
) -> PendingTrigger:
    """Record a trigger event that did not produce an actual email.

    Appended to ``state/email_pending.jsonl`` (one row per line). The
    CLI's ``list-pending-email-triggers`` verb reads this file. The
    file is gitignored by the existing ``state/`` rule.
    """
    if subject_prefix not in SUBJECT_PREFIXES:
        raise EmailNotifierError(
            f"unknown subject prefix {subject_prefix!r}; "
            f"expected one of {SUBJECT_PREFIXES}"
        )
    entry = PendingTrigger(
        ts=_now_iso(),
        subject_prefix=subject_prefix,
        subject_body=subject_body,
        reason=reason,
        source=source,
        metadata=dict(metadata or {}),
    )
    path = pending_path(state_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps(asdict(entry)) + "\n")
    return entry


def list_pending_email_triggers(
    state_dir: Optional[Path] = None,
) -> List[PendingTrigger]:
    """Return every pending trigger recorded since the file was created.

    Tolerant of malformed lines: skips invalid rows rather than
    crashing. Returns an empty list when the file does not exist.
    """
    path = pending_path(state_dir)
    if not path.exists():
        return []
    out: List[PendingTrigger] = []
    try:
        content = path.read_text(encoding="utf-8")
    except OSError:
        return []
    for line in content.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            row = json.loads(line)
            if not isinstance(row, dict):
                continue
            valid_keys = set(asdict(PendingTrigger(
                ts="", subject_prefix=BLOCK, subject_body="", reason=""
            )).keys())
            kwargs = {k: v for k, v in row.items() if k in valid_keys}
            out.append(PendingTrigger(**kwargs))
        except (json.JSONDecodeError, TypeError):
            continue
    return out


# ---------------------------------------------------------------------------
# Send-attempt audit log.
# ---------------------------------------------------------------------------


def _append_send_log(
    state_dir: Optional[Path],
    result: SendResult,
    *,
    to_addr: str,
) -> None:
    """Append one row to ``state/email_send_log.jsonl``.

    Audit of every send attempt — successes + skips + failures.
    Tolerant: an IO error here must not derail the caller's session.
    """
    path = send_log_path(state_dir)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        row = {
            "ts": _now_iso(),
            "sent": result.sent,
            "subject": result.subject,
            "reason": result.reason,
            "to": to_addr,
            # Never log the SMTP response verbatim if it could contain
            # credential echoes — store the boolean only.
            "smtp_response_present": result.smtp_response is not None,
        }
        with path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(row) + "\n")
    except Exception:
        pass  # never crash the session because audit logging failed


# ---------------------------------------------------------------------------
# Subject formatting.
# ---------------------------------------------------------------------------


_MAX_SUBJECT_BODY_CHARS = 80
_SUBJECT_PREFIX_FORMAT = "[apeiron:{prefix}] {body}"


def format_subject(subject_prefix: str, subject_body: str) -> str:
    """Format a subject line.

    Validates the prefix is one of the seven canonical kinds, strips
    embedded newlines from the body (no multi-line subjects), and
    truncates a body longer than 80 characters with an ellipsis so the
    full subject stays under ~100 chars across mobile clients.

    Raises :class:`EmailNotifierError` for unknown prefixes.
    """
    if subject_prefix not in SUBJECT_PREFIXES:
        raise EmailNotifierError(
            f"unknown subject prefix {subject_prefix!r}; "
            f"expected one of {SUBJECT_PREFIXES}"
        )
    # Single-line body — replace any whitespace runs with a single space.
    cleaned = " ".join(str(subject_body).split())
    if len(cleaned) > _MAX_SUBJECT_BODY_CHARS:
        cleaned = cleaned[: _MAX_SUBJECT_BODY_CHARS - 1].rstrip() + "…"
    return _SUBJECT_PREFIX_FORMAT.format(prefix=subject_prefix, body=cleaned)


# ---------------------------------------------------------------------------
# The notifier class.
# ---------------------------------------------------------------------------


#: Type alias for an SMTP_SSL factory — tests inject a fake here so
#: they never touch a real server.
SmtpFactory = Callable[..., smtplib.SMTP_SSL]


class EmailNotifier:
    """Thin wrapper around ``smtplib.SMTP_SSL``.

    The single chokepoint that every Apeiron trigger calls. Construct
    with a loaded :class:`EmailConfig` and call :meth:`send` per event.

    Parameters:
        config: A loaded :class:`EmailConfig`.
        state_dir: Where to write the pending-trigger / send-log files.
        smtp_factory: Override ``smtplib.SMTP_SSL`` for tests. The
            factory must accept ``(host, port, context, timeout)`` and
            return a context-manager SMTP_SSL object with
            ``.login(user, password)`` + ``.send_message(msg)`` methods.

    Public API:
        :meth:`send` — dispatch one email.
        :meth:`probe_connection` — connect + login + quit without
            sending. Used by the ready-check probe and the ``--dry-run``
            verb to verify deliverability without spamming.
    """

    def __init__(
        self,
        config: EmailConfig,
        *,
        state_dir: Optional[Path] = None,
        smtp_factory: Optional[SmtpFactory] = None,
    ) -> None:
        self.config = config
        self.state_dir = state_dir
        # Default factory is the real SMTP_SSL. Tests pass a fake.
        self._smtp_factory: SmtpFactory = smtp_factory or smtplib.SMTP_SSL

    # -----------------------------------------------------------------
    # Password resolution (env-var indirection, never on disk).
    # -----------------------------------------------------------------

    def _resolve_password(self) -> str:
        """Read the SMTP password from the configured env var.

        Raises :class:`EmailNotifierError` if the env var is missing or
        empty. The error message names the env var so the caller knows
        what to set, without echoing any partial value.
        """
        env_name = self.config.smtp_password_env or DEFAULT_PASSWORD_ENV
        value = os.environ.get(env_name, "")
        if not value:
            raise EmailNotifierError(
                f"SMTP password not available: env var "
                f"{env_name!r} is unset or empty. Set it via "
                f"`set {env_name}=<password>` (Windows) or "
                f"`export {env_name}=<password>` (POSIX) before "
                f"calling send."
            )
        return value

    # -----------------------------------------------------------------
    # Send — the one public method on the class.
    # -----------------------------------------------------------------

    def send(
        self,
        subject_prefix: str,
        subject_body: str,
        body: str,
        *,
        to_addr: Optional[str] = None,
        dry_run: bool = False,
        source: str = "",
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Send one email.

        ``subject_prefix`` must be one of the seven canonical kinds —
        see :data:`SUBJECT_PREFIXES`. The subject is built via
        :func:`format_subject`; the body is sent verbatim as plain text.

        Parameters:
            subject_prefix: One of ``BLOCK / REVIEW / HEADS_UP / DONE /
                SECURITY / QUARANTINE / SESSION_READY``.
            subject_body: One-line summary (truncated at 80 chars).
            body: Multi-line plain-text body.
            to_addr: Override the recipient. Defaults to
                ``config.to_default``.
            dry_run: If True, resolve the SMTP connection (verify host /
                port / auth would work) but do NOT call
                ``send_message``. Returns a ``SendResult`` with
                ``sent=False, reason="dry-run"``.
            source: Free-form label identifying the caller (e.g.
                ``"silence_watchdog"``). Recorded in the pending /
                send-log files.
            metadata: Optional dict recorded in the pending-trigger
                registry for skips.

        Returns:
            :class:`SendResult` carrying ``sent``, the formatted
            ``subject``, a ``reason`` ("ok" / "dry-run" / "disabled" /
            "env-disabled"), and an optional ``smtp_response``.

        Raises:
            :class:`EmailNotifierError` for unrecoverable SMTP failures
            (auth error, host unreachable). Soft failures
            (disabled config, dry-run) return a result with ``sent=False``
            rather than raising.
        """
        subject = format_subject(subject_prefix, subject_body)

        # Env-level disable — pytest sets this so no test ever emails.
        if os.environ.get(EMAIL_DISABLED_ENV) == "1":
            result = SendResult(sent=False, subject=subject, reason="env-disabled")
            append_pending_trigger(
                subject_prefix, subject_body, "env-disabled",
                source=source, metadata=metadata,
                state_dir=self.state_dir,
            )
            _append_send_log(
                self.state_dir, result,
                to_addr=to_addr or self.config.to_default,
            )
            return result

        # Config-level disable — fresh checkout has enabled=False.
        if not self.config.enabled and not dry_run:
            result = SendResult(sent=False, subject=subject, reason="disabled")
            append_pending_trigger(
                subject_prefix, subject_body, "disabled",
                source=source, metadata=metadata,
                state_dir=self.state_dir,
            )
            _append_send_log(
                self.state_dir, result,
                to_addr=to_addr or self.config.to_default,
            )
            return result

        recipient = to_addr or self.config.to_default
        if not recipient:
            raise EmailNotifierError(
                "no recipient address: pass to_addr= or set "
                "config.to_default before calling send"
            )
        if not self.config.smtp_host or not self.config.smtp_port:
            raise EmailNotifierError(
                "SMTP host/port not configured: run `configure-email` "
                "to write state/email_config.json before calling send"
            )

        password = self._resolve_password()

        msg = EmailMessage()
        msg["Subject"] = subject
        msg["From"] = self.config.from_addr or self.config.smtp_user
        msg["To"] = recipient
        msg.set_content(body or "")

        context = ssl.create_default_context()

        if dry_run:
            # Probe-only: connect, login, quit. Never send.
            try:
                with self._smtp_factory(
                    self.config.smtp_host,
                    self.config.smtp_port,
                    context=context,
                    timeout=10,
                ) as smtp:
                    smtp.login(self.config.smtp_user, password)
            except smtplib.SMTPException as exc:
                # Re-raise as our error type with the password redacted
                # — smtplib exceptions can echo the password in
                # SMTPAuthenticationError messages.
                raise EmailNotifierError(
                    f"SMTP probe failed: {type(exc).__name__}: "
                    f"{_redact_password(str(exc), password)}"
                )
            except OSError as exc:
                raise EmailNotifierError(
                    f"SMTP probe failed: {type(exc).__name__}: {exc}"
                )
            result = SendResult(sent=False, subject=subject, reason="dry-run")
            append_pending_trigger(
                subject_prefix, subject_body, "dry-run",
                source=source, metadata=metadata,
                state_dir=self.state_dir,
            )
            _append_send_log(self.state_dir, result, to_addr=recipient)
            return result

        # Real send.
        try:
            with self._smtp_factory(
                self.config.smtp_host,
                self.config.smtp_port,
                context=context,
                timeout=30,
            ) as smtp:
                smtp.login(self.config.smtp_user, password)
                response = smtp.send_message(msg)
        except smtplib.SMTPException as exc:
            raise EmailNotifierError(
                f"SMTP send failed: {type(exc).__name__}: "
                f"{_redact_password(str(exc), password)}"
            )
        except OSError as exc:
            raise EmailNotifierError(
                f"SMTP send failed: {type(exc).__name__}: {exc}"
            )

        result = SendResult(
            sent=True,
            subject=subject,
            reason="ok",
            smtp_response=str(response) if response else None,
        )
        _append_send_log(self.state_dir, result, to_addr=recipient)
        return result

    # -----------------------------------------------------------------
    # Probe — what the ready-check verb calls.
    # -----------------------------------------------------------------

    def probe_connection(self) -> Tuple[bool, str]:
        """Verify the SMTP server accepts our credentials.

        Performs ``connect`` + ``login`` + ``quit`` without sending.
        Returns ``(True, message)`` on success, ``(False, message)`` on
        any failure (network, auth, missing env var). Never raises.
        """
        if not self.config.enabled:
            return (
                True,
                "email notifier disabled in config; probe skipped",
            )
        if not self.config.smtp_host or not self.config.smtp_port:
            return False, "SMTP host/port not configured"
        try:
            password = self._resolve_password()
        except EmailNotifierError as exc:
            return False, str(exc)
        context = ssl.create_default_context()
        try:
            with self._smtp_factory(
                self.config.smtp_host,
                self.config.smtp_port,
                context=context,
                timeout=10,
            ) as smtp:
                smtp.login(self.config.smtp_user, password)
        except smtplib.SMTPException as exc:
            return False, (
                f"SMTP probe failed: {type(exc).__name__}: "
                f"{_redact_password(str(exc), password)}"
            )
        except OSError as exc:
            return False, f"SMTP probe failed: {type(exc).__name__}: {exc}"
        return True, (
            f"SMTP ready: {self.config.smtp_host}:{self.config.smtp_port} "
            f"as {self.config.smtp_user}"
        )


def _redact_password(message: str, password: str) -> str:
    """Replace any occurrence of the password in ``message`` with
    ``"<redacted>"``. Defensive: smtplib can include credentials in
    error strings (especially with custom servers)."""
    if not password:
        return message
    return message.replace(password, "<redacted>")


# ---------------------------------------------------------------------------
# Convenience constructor.
# ---------------------------------------------------------------------------


def build_notifier(
    *,
    state_dir: Optional[Path] = None,
    smtp_factory: Optional[SmtpFactory] = None,
) -> EmailNotifier:
    """Load config from disk and return a notifier.

    Convenience wrapper used by the CLI + ready-check probe. Raises
    :class:`EmailNotifierError` on a malformed config (per
    :func:`load_config`).
    """
    cfg = load_config(state_dir)
    return EmailNotifier(cfg, state_dir=state_dir, smtp_factory=smtp_factory)


# ---------------------------------------------------------------------------
# CLI verbs.
# ---------------------------------------------------------------------------


def _cli_configure_email(args: argparse.Namespace) -> int:
    """Write ``state/email_config.json``.

    Defensible defaults: ``enabled=False`` (the maintainer flips after a
    successful test send), ``to_default`` is required so the notifier
    knows where to send, password env-var name defaults to
    ``APEIRON_SMTP_PASSWORD`` but is configurable.
    """
    state_dir = Path(args.state_dir) if args.state_dir else None
    cfg = EmailConfig(
        from_addr=args.from_addr,
        smtp_host=args.smtp_host,
        smtp_port=int(args.smtp_port),
        smtp_user=args.smtp_user or args.from_addr,
        smtp_password_env=args.password_env or DEFAULT_PASSWORD_ENV,
        to_default=args.to_default,
        enabled=bool(args.enable),
    )
    path = save_config(cfg, state_dir=state_dir)
    print(f"wrote {path}")
    print(
        f"  smtp: {cfg.smtp_user}@{cfg.smtp_host}:{cfg.smtp_port}, "
        f"to_default={cfg.to_default}, enabled={cfg.enabled}"
    )
    print(
        f"  password env var: {cfg.smtp_password_env} "
        f"(currently {'set' if os.environ.get(cfg.smtp_password_env) else 'UNSET'})"
    )
    if not os.environ.get(cfg.smtp_password_env):
        print(
            f"  NOTE: set {cfg.smtp_password_env} in your environment "
            f"before send-test-email will work."
        )
    return 0


def _cli_send_test_email(args: argparse.Namespace) -> int:
    """Send a fixed-body ``[apeiron:heads-up]`` test email.

    Exits 0 on send, 1 on SMTP failure, 2 on disabled config.
    """
    state_dir = Path(args.state_dir) if args.state_dir else None
    try:
        cfg = load_config(state_dir)
    except EmailNotifierError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    if not cfg.enabled and not args.dry_run:
        print(
            "error: email notifier disabled in config (enabled=false); "
            "edit state/email_config.json or pass --dry-run to probe",
            file=sys.stderr,
        )
        return 2
    notifier = EmailNotifier(cfg, state_dir=state_dir)
    body = (
        f"This is a test email from the Apeiron notifier (SPEC-078).\n\n"
        f"Sent at: {_now_iso()}\n"
    )
    try:
        result = notifier.send(
            HEADS_UP,
            "test email from apeiron notifier",
            body,
            to_addr=args.to or None,
            dry_run=bool(args.dry_run),
            source="cli:send-test-email",
        )
    except EmailNotifierError as exc:
        print(f"send failed: {exc}", file=sys.stderr)
        return 1
    print(
        f"{'(dry-run) ' if args.dry_run else ''}"
        f"{'sent' if result.sent else 'NOT sent'}: subject={result.subject!r} "
        f"reason={result.reason!r}"
    )
    return 0 if (result.sent or args.dry_run) else 2


def _cli_list_pending_email_triggers(args: argparse.Namespace) -> int:
    """List trigger events that would have fired but were suppressed."""
    state_dir = Path(args.state_dir) if args.state_dir else None
    pending = list_pending_email_triggers(state_dir)
    if not pending:
        print("(no pending email triggers)")
        return 0
    print(f"pending email triggers ({len(pending)}):")
    for entry in pending:
        print(
            f"  {entry.ts}  [apeiron:{entry.subject_prefix}] "
            f"reason={entry.reason!r}  source={entry.source!r}  "
            f"body={entry.subject_body!r}"
        )
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(
        prog="tools.email_notifier",
        description="Email side-channel notifier (SPEC-078, phase 1).",
    )
    parser.add_argument(
        "--state-dir",
        default=None,
        help="Override the state dir holding email_config.json + log files.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_cfg = sub.add_parser(
        "configure-email",
        help="Write state/email_config.json (no password — env var only).",
    )
    p_cfg.add_argument("from_addr", help="From header value")
    p_cfg.add_argument("smtp_host")
    p_cfg.add_argument("smtp_port")
    p_cfg.add_argument(
        "--smtp-user",
        default=None,
        help="SMTP auth user (defaults to from_addr).",
    )
    p_cfg.add_argument(
        "--password-env",
        default=None,
        help=f"Env var holding the SMTP password "
             f"(default {DEFAULT_PASSWORD_ENV!r}).",
    )
    p_cfg.add_argument(
        "--to-default",
        default="",
        help="Default recipient (the maintainer's primary inbox).",
    )
    p_cfg.add_argument(
        "--enable",
        action="store_true",
        help="Flip enabled=True. Default off so a fresh setup never emails.",
    )

    p_send = sub.add_parser(
        "send-test-email",
        help="Send a fixed test email to confirm the SMTP setup.",
    )
    p_send.add_argument(
        "to",
        nargs="?",
        default="",
        help="Recipient address (defaults to config.to_default).",
    )
    p_send.add_argument(
        "--dry-run",
        action="store_true",
        help="Probe SMTP without dispatching the message.",
    )

    sub.add_parser(
        "list-pending-email-triggers",
        help="List trigger events that did not produce an actual send.",
    )

    args = parser.parse_args(argv)

    if args.cmd == "configure-email":
        return _cli_configure_email(args)
    if args.cmd == "send-test-email":
        return _cli_send_test_email(args)
    if args.cmd == "list-pending-email-triggers":
        return _cli_list_pending_email_triggers(args)

    parser.error(f"unknown command: {args.cmd}")
    return 2


__all__ = [
    "BLOCK", "REVIEW", "HEADS_UP", "DONE",
    "SECURITY", "QUARANTINE", "SESSION_READY",
    "SUBJECT_PREFIXES",
    "DEFAULT_PASSWORD_ENV", "EMAIL_DISABLED_ENV",
    "EmailNotifier", "EmailNotifierError",
    "EmailConfig", "PendingTrigger", "SendResult",
    "format_subject", "load_config", "save_config",
    "build_notifier",
    "append_pending_trigger", "list_pending_email_triggers",
    "config_path", "pending_path", "send_log_path",
    "main",
]


if __name__ == "__main__":
    raise SystemExit(main())
