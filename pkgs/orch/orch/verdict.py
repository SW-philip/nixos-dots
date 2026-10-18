import json
from dataclasses import dataclass

SEVERITIES = ("blocker", "major", "minor")


@dataclass(frozen=True)
class Finding:
    severity: str
    file: str | None
    line: int | None
    text: str


@dataclass(frozen=True)
class Verdict:
    verdict: str
    summary: str
    findings: tuple


REVIEW_SCHEMA = {
    "type": "object",
    "properties": {
        "verdict": {"type": "string", "enum": ["approve", "changes"]},
        "summary": {"type": "string"},
        "findings": {
            "type": "array",
            "items": {
                "type": "object",
                "properties": {
                    "severity": {"type": "string", "enum": list(SEVERITIES)},
                    "file": {"type": ["string", "null"]},
                    "line": {"type": ["integer", "null"]},
                    "text": {"type": "string"},
                },
                "required": ["severity", "file", "line", "text"],
                "additionalProperties": False,
            },
        },
    },
    "required": ["verdict", "summary", "findings"],
    "additionalProperties": False,
}

_NO_VERDICT_TEXT = "reviewer returned no verdict"
NO_VERDICT = Verdict("changes", _NO_VERDICT_TEXT, (Finding("blocker", None, None, _NO_VERDICT_TEXT),))


def extract_json(text: str) -> dict | None:
    best = None
    depth, start, in_str, esc = 0, 0, False, False
    for i, ch in enumerate(text):
        if in_str:
            if esc:
                esc = False
            elif ch == "\\":
                esc = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"' and depth > 0:
            in_str = True
        elif ch == "{":
            if depth == 0:
                start = i
            depth += 1
        elif ch == "}" and depth > 0:
            depth -= 1
            if depth == 0:
                try:
                    obj = json.loads(text[start:i + 1])
                except (ValueError, RecursionError):
                    continue
                if isinstance(obj, dict) and "verdict" in obj:
                    best = obj
    return best


def _parse_finding(f) -> Finding | None:
    if not isinstance(f, dict):
        return None
    sev, text, file, line = f.get("severity"), f.get("text"), f.get("file"), f.get("line")
    if sev not in SEVERITIES or not isinstance(text, str):
        return None
    # The schema cannot enforce minLength under strict structured output.
    text = text if text.strip() else "(no description)"
    if file is not None and not isinstance(file, str):
        return None
    if line is not None and (isinstance(line, bool) or not isinstance(line, int)):
        return None
    return Finding(sev, file, line, text)


def parse_verdict(raw) -> Verdict:
    if isinstance(raw, str):
        raw = extract_json(raw)
    if not isinstance(raw, dict):
        return NO_VERDICT
    verdict = raw.get("verdict")
    summary = raw.get("summary", "")
    findings = raw.get("findings", [])
    if verdict not in ("approve", "changes") or not isinstance(summary, str):
        return NO_VERDICT
    if not isinstance(findings, list):
        return NO_VERDICT
    parsed = [_parse_finding(f) for f in findings]
    if any(f is None for f in parsed):
        return NO_VERDICT
    return Verdict(verdict, summary, tuple(parsed))


def must_fix(v: Verdict) -> list[Finding]:
    return [f for f in v.findings if f.severity in ("blocker", "major")]


def approved(v: Verdict) -> bool:
    return v.verdict == "approve" and not must_fix(v)


def format_findings(findings) -> str:
    lines = []
    for f in findings:
        loc = ""
        if f.file:
            loc = f" {f.file}" + (f":{f.line}" if f.line is not None else "")
        lines.append(f"- [{f.severity}]{loc} {f.text}")
    return "\n".join(lines)
