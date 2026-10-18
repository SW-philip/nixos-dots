import json
import unittest
from pathlib import Path

from orch.verdict import (
    NO_VERDICT,
    REVIEW_SCHEMA,
    Finding,
    Verdict,
    approved,
    extract_json,
    format_findings,
    must_fix,
    parse_verdict,
)

GOOD = {"verdict": "approve", "summary": "ok", "findings": []}


class ExtractJson(unittest.TestCase):
    def test_bare(self):
        self.assertEqual(extract_json(json.dumps(GOOD)), GOOD)

    def test_fenced_with_prose(self):
        text = "Here you go:\n```json\n" + json.dumps(GOOD) + "\n```\nthanks"
        self.assertEqual(extract_json(text), GOOD)

    def test_last_wins(self):
        a = {"verdict": "changes", "summary": "a", "findings": []}
        text = json.dumps(a) + "\nactually:\n" + json.dumps(GOOD)
        self.assertEqual(extract_json(text), GOOD)

    def test_braces_in_string(self):
        obj = {"verdict": "approve", "summary": "has } and { and \" quote", "findings": []}
        self.assertEqual(extract_json("x " + json.dumps(obj) + " y"), obj)

    def test_unrelated_braces_ignored(self):
        text = "use {} or {a: 1} here " + json.dumps(GOOD)
        self.assertEqual(extract_json(text), GOOD)

    def test_none(self):
        self.assertIsNone(extract_json("no json {} at all"))


class ParseVerdict(unittest.TestCase):
    def test_dict(self):
        self.assertEqual(parse_verdict(GOOD), Verdict("approve", "ok", ()))

    def test_string(self):
        self.assertEqual(parse_verdict(json.dumps(GOOD)).verdict, "approve")

    def test_fenced(self):
        self.assertEqual(parse_verdict("hi\n```json\n" + json.dumps(GOOD) + "\n```").verdict, "approve")

    def test_findings_parsed(self):
        raw = {"verdict": "changes", "summary": "s",
               "findings": [{"severity": "major", "file": "a.py", "line": 3, "text": "bad"},
                            {"severity": "minor", "text": "nit"}]}
        v = parse_verdict(raw)
        self.assertEqual(v.findings, (Finding("major", "a.py", 3, "bad"), Finding("minor", None, None, "nit")))

    def test_invalid(self):
        bad = [
            None,
            {},
            {"verdict": "maybe"},
            {"verdict": "changes", "findings": [{"severity": "huge", "text": "x"}]},
            {"verdict": "changes", "findings": [{"severity": "minor"}]},
            {"verdict": "changes", "findings": [{"severity": "minor", "text": None}]},
            {"verdict": "changes", "findings": [{"severity": "minor", "text": "x", "line": True}]},
            {"verdict": "changes", "findings": "nope"},
            "not json",
        ]
        for raw in bad:
            with self.subTest(raw=raw):
                self.assertEqual(parse_verdict(raw), NO_VERDICT)

class Deep(unittest.TestCase):
    def test_deep_nesting_no_raise(self):
        text = '{"verdict": "approve", "x": ' + '{"a":' * 100000 + "1" + "}" * 100000 + "}"
        self.assertEqual(parse_verdict(text), NO_VERDICT)


class Helpers(unittest.TestCase):
    def test_approved(self):
        minor = Finding("minor", None, None, "n")
        self.assertTrue(approved(Verdict("approve", "", (minor,))))
        self.assertFalse(approved(Verdict("approve", "", (Finding("blocker", None, None, "b"),))))
        self.assertFalse(approved(Verdict("changes", "", ())))

    def test_must_fix(self):
        fs = (Finding("blocker", None, None, "a"), Finding("minor", None, None, "b"),
              Finding("major", None, None, "c"))
        self.assertEqual([f.text for f in must_fix(Verdict("changes", "", fs))], ["a", "c"])

    def test_format(self):
        out = format_findings([Finding("major", "a.py", 3, "bad"), Finding("minor", None, None, "nit"),
                               Finding("minor", "b.py", None, "x")])
        self.assertEqual(out, "- [major] a.py:3 bad\n- [minor] nit\n- [minor] b.py x")

    def test_schema_strict_structured_output(self):
        def walk(node):
            if isinstance(node, dict):
                self.assertNotIn("minLength", node)
                if node.get("type") == "object":
                    self.assertEqual(sorted(node["required"]), sorted(node["properties"]))
                    self.assertIs(node["additionalProperties"], False)
                for v in node.values():
                    walk(v)
            elif isinstance(node, list):
                for v in node:
                    walk(v)
        walk(REVIEW_SCHEMA)
        items = REVIEW_SCHEMA["properties"]["findings"]["items"]
        self.assertEqual(sorted(items["required"]), ["file", "line", "severity", "text"])
        self.assertEqual(REVIEW_SCHEMA["required"], ["verdict", "summary", "findings"])

    def test_parser_still_accepts_missing_file_line(self):
        v = parse_verdict({"verdict": "changes", "summary": "s",
                           "findings": [{"severity": "major", "text": "t"}]})
        self.assertEqual(v.findings, (Finding("major", None, None, "t"),))

    def test_empty_finding_text_gets_placeholder(self):
        for text in ("", "  \n\t"):
            v = parse_verdict({"verdict": "changes", "summary": "s", "findings": [
                {"severity": "major", "file": None, "line": None, "text": text},
                {"severity": "minor", "text": "real"}]})
            self.assertEqual([f.text for f in v.findings], ["(no description)", "real"])
            self.assertEqual(v.findings[0].severity, "major")
        self.assertEqual(parse_verdict({"verdict": "changes", "summary": "s", "findings": [
            {"severity": "bogus", "text": ""}]}), NO_VERDICT)

    def test_schema_file(self):
        path = Path(__file__).resolve().parent.parent / "orch" / "schemas" / "review.json"
        self.assertEqual(json.loads(path.read_text()), REVIEW_SCHEMA)


if __name__ == "__main__":
    unittest.main()
