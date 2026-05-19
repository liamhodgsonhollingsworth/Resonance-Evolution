"""
Quarantine — scan untrusted inbox messages before any LLM sees them.

SPEC-058. Untrusted messages (per SPEC-057's sender filter) land in
quarantine. The scanner annotates each with structured findings across
four categories:

- ``prompt_injection`` — known phrases designed to override or hijack
  downstream LLM instructions.
- ``url_safety`` — URLs whose domains contain non-ASCII or mixed-script
  characters (homoglyph attack shape).
- ``character_class`` — zero-width, RTL-override, and bidi control
  characters that hide text or reverse rendering order.
- ``anomaly`` — composite signals: extreme length, unusual char-class
  ratio, etc.

The scanner is conservative and minimal by design. Rule additions are
accumulator-pattern deliverables: each new attack pattern observed
should land here with a test demonstrating the catch. SPEC-058 notes:
*"Scan rules begin minimal and grow as patterns are observed."*

The scanner MUST run BEFORE any LLM reads the message. LLMs are not
safe scanners of attacks designed against themselves.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, List, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from .inbox import Inbox, InboxMessage
    from .trust import TrustSet


SEVERITY_LOW = "LOW"
SEVERITY_MEDIUM = "MEDIUM"
SEVERITY_HIGH = "HIGH"
SEVERITY_RANK = {SEVERITY_LOW: 1, SEVERITY_MEDIUM: 2, SEVERITY_HIGH: 3}

_PROMPT_INJECTION_PATTERNS = [
    (re.compile(r"ignore\s+(all\s+)?previous\s+instructions?", re.I), SEVERITY_HIGH, "ignore-previous-instructions"),
    (re.compile(r"disregard\s+(the\s+)?(above|prior|previous)", re.I), SEVERITY_HIGH, "disregard-above"),
    (re.compile(r"forget\s+(everything|all)\s+(you'?ve\s+been\s+told|above)", re.I), SEVERITY_HIGH, "forget-everything"),
    (re.compile(r"you\s+are\s+now\s+(a|an)\s+[a-z]", re.I), SEVERITY_HIGH, "role-hijack-you-are-now"),
    (re.compile(r"new\s+(system\s+)?instructions?\s*:", re.I), SEVERITY_HIGH, "new-instructions-marker"),
    (re.compile(r"<\|im_start\|>|<\|im_end\|>"), SEVERITY_HIGH, "chatml-control-tokens"),
    (re.compile(r"<<\s*SYS\s*>>|<</\s*SYS\s*>>"), SEVERITY_HIGH, "llama-system-tokens"),
    (re.compile(r"\[INST\]|\[/INST\]"), SEVERITY_HIGH, "mistral-instruct-tokens"),
    (re.compile(r"\[\s*SYSTEM\s*\]|\[\s*ASSISTANT\s*\]|\[\s*USER\s*\]"), SEVERITY_MEDIUM, "role-tag-marker"),
    (re.compile(r"override\s+(your|the)\s+(safety|guidelines|rules)", re.I), SEVERITY_HIGH, "safety-override"),
    (re.compile(r"jailbreak", re.I), SEVERITY_MEDIUM, "jailbreak-keyword"),
    (re.compile(r"(reveal|show|print|output)\s+(your|the)\s+(system\s+)?prompt", re.I), SEVERITY_HIGH, "prompt-extraction"),
    (re.compile(r"do\s+anything\s+now|DAN\s+mode", re.I), SEVERITY_HIGH, "dan-jailbreak"),
]

_URL_RE = re.compile(r"https?://[^\s<>\"')]+", re.I)
_DOMAIN_RE = re.compile(r"^https?://([^/\s:]+)", re.I)

_ZERO_WIDTH_CHARS = {
    "​",  # zero-width space
    "‌",  # zero-width non-joiner
    "‍",  # zero-width joiner
    "⁠",  # word joiner
    "﻿",  # zero-width no-break space (BOM)
}

_RTL_OVERRIDE_CHARS = {
    "‪",  # LRE
    "‫",  # RLE
    "‬",  # PDF (pop directional formatting)
    "‭",  # LRO
    "‮",  # RLO
    "⁦",  # LRI
    "⁧",  # RLI
    "⁨",  # FSI
    "⁩",  # PDI
}


@dataclass
class ScanFinding:
    severity: str
    category: str
    detail: str
    excerpt: str = ""


@dataclass
class ScanReport:
    findings: List[ScanFinding] = field(default_factory=list)
    overall_severity: str = SEVERITY_LOW
    anomaly_score: float = 0.0

    def has_high(self) -> bool:
        return any(f.severity == SEVERITY_HIGH for f in self.findings)

    def has_any(self) -> bool:
        return bool(self.findings)

    def as_dict(self) -> dict:
        return {
            "overall_severity": self.overall_severity,
            "anomaly_score": round(self.anomaly_score, 3),
            "findings": [
                {
                    "severity": f.severity,
                    "category": f.category,
                    "detail": f.detail,
                    "excerpt": f.excerpt,
                }
                for f in self.findings
            ],
        }


def scan_for_prompt_injection(text: str) -> List[ScanFinding]:
    """Match known prompt-injection patterns. Returns one ScanFinding per match."""
    out: List[ScanFinding] = []
    if not text:
        return out
    for pattern, severity, detail in _PROMPT_INJECTION_PATTERNS:
        for m in pattern.finditer(text):
            excerpt = _excerpt_around(text, m.start(), m.end())
            out.append(ScanFinding(
                severity=severity,
                category="prompt_injection",
                detail=detail,
                excerpt=excerpt,
            ))
    return out


def scan_urls(text: str) -> List[ScanFinding]:
    """Find URLs and flag domains with non-ASCII or mixed-script chars."""
    out: List[ScanFinding] = []
    if not text:
        return out
    for m in _URL_RE.finditer(text):
        url = m.group(0)
        domain_match = _DOMAIN_RE.match(url)
        if not domain_match:
            continue
        domain = domain_match.group(1)
        if not domain.isascii():
            out.append(ScanFinding(
                severity=SEVERITY_HIGH,
                category="url_safety",
                detail="non-ascii-domain",
                excerpt=url[:200],
            ))
            continue
        scripts = _scripts_in(domain)
        if len(scripts) > 1:
            out.append(ScanFinding(
                severity=SEVERITY_HIGH,
                category="url_safety",
                detail=f"mixed-script-domain ({'+'.join(sorted(scripts))})",
                excerpt=url[:200],
            ))
    return out


def scan_character_classes(text: str) -> List[ScanFinding]:
    """Flag zero-width and RTL-override characters."""
    out: List[ScanFinding] = []
    if not text:
        return out
    zw_chars = [c for c in text if c in _ZERO_WIDTH_CHARS]
    if zw_chars:
        out.append(ScanFinding(
            severity=SEVERITY_MEDIUM,
            category="character_class",
            detail=f"zero-width-chars (count={len(zw_chars)})",
            excerpt=_first_occurrence_excerpt(text, _ZERO_WIDTH_CHARS),
        ))
    rtl_chars = [c for c in text if c in _RTL_OVERRIDE_CHARS]
    if rtl_chars:
        out.append(ScanFinding(
            severity=SEVERITY_HIGH,
            category="character_class",
            detail=f"rtl-override-chars (count={len(rtl_chars)})",
            excerpt=_first_occurrence_excerpt(text, _RTL_OVERRIDE_CHARS),
        ))
    if text and len(text) > 0:
        non_ascii_ratio = sum(1 for c in text if ord(c) > 127) / len(text)
        if non_ascii_ratio > 0.4 and len(text) > 50:
            out.append(ScanFinding(
                severity=SEVERITY_LOW,
                category="character_class",
                detail=f"high-non-ascii-ratio ({non_ascii_ratio:.2f})",
                excerpt=text[:120],
            ))
    return out


def scan_anomaly(text: str) -> List[ScanFinding]:
    """Length-based + composite anomaly signals."""
    out: List[ScanFinding] = []
    if not text:
        return out
    if len(text) > 50_000:
        out.append(ScanFinding(
            severity=SEVERITY_LOW,
            category="anomaly",
            detail=f"large-message ({len(text)} bytes)",
            excerpt=text[:120],
        ))
    return out


def scan_text(text: str) -> ScanReport:
    """Run every scanner against a single text blob and aggregate."""
    findings: List[ScanFinding] = []
    findings.extend(scan_for_prompt_injection(text))
    findings.extend(scan_urls(text))
    findings.extend(scan_character_classes(text))
    findings.extend(scan_anomaly(text))

    severity = SEVERITY_LOW
    for f in findings:
        if SEVERITY_RANK[f.severity] > SEVERITY_RANK[severity]:
            severity = f.severity
    anomaly = sum(SEVERITY_RANK[f.severity] for f in findings) / max(1, len(text) / 1000)
    return ScanReport(
        findings=findings,
        overall_severity=severity,
        anomaly_score=anomaly,
    )


def scan_message(msg: "InboxMessage") -> ScanReport:
    """Scan a full ``InboxMessage`` — body + summary + sender fields."""
    parts = [msg.summary or "", msg.body or "", msg.sender or "", msg.kind or ""]
    combined = "\n".join(parts)
    return scan_text(combined)


def quarantine_delete(msg: "InboxMessage") -> None:
    """Delete the message file. Removes the read-marker entry too."""
    try:
        Path(msg.path).unlink()
    except FileNotFoundError:
        pass


def quarantine_promote_sender(msg: "InboxMessage", trust_set: "TrustSet") -> None:
    """Add ``msg.sender`` to the trust-set so future messages route to main."""
    trust_set.add(msg.sender)


def _excerpt_around(text: str, start: int, end: int, window: int = 40) -> str:
    s = max(0, start - window)
    e = min(len(text), end + window)
    snippet = text[s:e].replace("\n", " ")
    return snippet[:240]


def _first_occurrence_excerpt(text: str, charset) -> str:
    for i, c in enumerate(text):
        if c in charset:
            return _excerpt_around(text, i, i + 1)
    return ""


def _scripts_in(s: str) -> set:
    """Return the set of Unicode scripts present in s (rough — uses
    name prefix heuristic so we don't need the unicodedata2 package).
    """
    scripts = set()
    for c in s:
        if not c.isalpha():
            continue
        try:
            name = unicodedata.name(c)
        except ValueError:
            scripts.add("unknown")
            continue
        if name.startswith("LATIN"):
            scripts.add("latin")
        elif name.startswith("CYRILLIC"):
            scripts.add("cyrillic")
        elif name.startswith("GREEK"):
            scripts.add("greek")
        elif name.startswith("HEBREW"):
            scripts.add("hebrew")
        elif name.startswith("ARABIC"):
            scripts.add("arabic")
        elif name.startswith("CJK") or name.startswith("HIRAGANA") or name.startswith("KATAKANA"):
            scripts.add("cjk")
        else:
            scripts.add("other")
    return scripts
