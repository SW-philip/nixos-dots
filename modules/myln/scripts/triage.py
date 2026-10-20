#!/usr/bin/env python3
"""
triage.py — deterministic helpers around the myln-diagnose LLM pass

  split        match normalized error lines against known-issue tables; matched
               lines become a markdown section, the rest go to the model
  check-paths  mark absolute paths in the model's "Check:" clauses that don't
               exist on this host

Table format, one rule per line, tab-separated, '#' comments:
    <python regex>  <action|watch|benign>  <note>  [<cleared-by regex>]
First matching rule wins. Input lines may carry a "(xN) " repeat prefix.
A rule with a cleared-by regex is shown as resolved when the journal has a
line matching it after the rule's last match (e.g. a later successful switch).

A table ending in .md is a hand-written ISSUES.md instead; every other line is prose:
    - `<python regex>` <action|watch|benign>: <note>
      cleared by `<regex>`            (optional, on the next line)
"""

import argparse
import glob
import re
import subprocess
import sys

ORDER = {"action": 0, "watch": 1, "benign": 2}
RESOLVED = 3
JOURNAL_LINE = re.compile(r"^(\d+)\.\d+ \S+ ([^\[:\s]+)(?:\[\d+\])?: (.*)$")
COUNT = re.compile(r"^\(x(\d+)\) ")
MD_RULE = re.compile(r"^[-*] `(.+)` +(action|watch|benign):? *(.*)$")
MD_CLEARED = re.compile(r"^\s+cleared by `(.+)`\s*$")
CHECK_PATH = re.compile(r"(?<![\w/])(/[\w@%+=:,.\-/*]+)")


def load_rules(paths):
    rules = []
    for path in paths:
        try:
            lines = open(path, encoding="utf-8").read().splitlines()
        except FileNotFoundError:
            continue
        if path.endswith(".md"):
            lines = md_to_tsv(lines)
        for n, line in enumerate(lines, 1):
            if not line.strip() or line.lstrip().startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) not in (3, 4) or parts[1] not in ORDER:
                print(f"{path}:{n}: skipped, want pattern<TAB>action|watch|benign<TAB>note[<TAB>cleared-by]",
                      file=sys.stderr)
                continue
            try:
                cleared = re.compile(parts[3]) if len(parts) == 4 and parts[3] else None
                rules.append((re.compile(parts[0]), parts[1], parts[2], cleared))
            except re.error as e:
                print(f"{path}:{n}: skipped, bad regex ({e})", file=sys.stderr)
    return rules


def md_to_tsv(lines):
    """Rewrite ISSUES.md rule bullets as table lines, prose as blanks (keeps line numbers)."""
    out = []
    for line in lines:
        m, c = MD_RULE.match(line), MD_CLEARED.match(line)
        if m:
            out.append("\t".join(m.groups()))
        elif c and out and out[-1].count("\t") == 2:
            out[-1] += "\t" + c.group(1)
            out.append("")
        else:
            out.append("")
    return out


def split(args):
    rules = load_rules(args.table)
    hits = {}
    rest = []
    for raw in open(args.lines, encoding="utf-8"):
        line = raw.rstrip("\n")
        if not line:
            continue
        m = COUNT.match(line)
        n = int(m.group(1)) if m else 1
        text = line[m.end():] if m else line
        for i, (rx, _, _, _) in enumerate(rules):
            if rx.search(text):
                rec = hits.setdefault(i, [0, text])
                rec[0] += n
                break
        else:
            rest.append(line)

    resolved = find_resolved(rules, hits, args.since)

    def rank(i):
        return (RESOLVED if i in resolved else ORDER[rules[i][1]], i)

    with open(args.known_out, "w", encoding="utf-8") as f:
        for i in sorted(hits, key=rank):
            _, verdict, note, _ = rules[i]
            count, sample = hits[i]
            sample = sample if len(sample) <= 90 else sample[:87] + "..."
            if i in resolved:
                verdict, note = "resolved", f"A later success cleared this ({note})"
            f.write(f"- **{verdict}**: {note} _(seen {count}x, e.g. `{sample}`)_\n")

    with open(args.rest_out, "w", encoding="utf-8") as f:
        for line in rest:
            f.write(line + "\n")


def find_resolved(rules, hits, since):
    """Indexes of matched rules whose cleared-by line appears in the journal after their last match."""
    watch = [i for i in hits if rules[i][3] is not None]
    if not watch:
        return set()
    last_hit, last_clear = {}, {}
    try:
        proc = subprocess.Popen(
            ["journalctl", "--since", since, "--no-pager", "-o", "short-unix"],
            stdout=subprocess.PIPE, text=True, errors="replace",
        )
    except OSError as e:
        print(f"journalctl unavailable, nothing marked resolved ({e})", file=sys.stderr)
        return set()
    for raw in proc.stdout:
        m = JOURNAL_LINE.match(raw.rstrip("\n"))
        if not m:
            continue
        ts, text = int(m.group(1)), f"{m.group(2)}: {m.group(3)}"
        for i in watch:
            if rules[i][0].search(text):
                last_hit[i] = ts
            if rules[i][3].search(text):
                last_clear[i] = ts
    proc.wait()
    return {i for i in watch if i in last_hit and last_clear.get(i, 0) > last_hit[i]}


def check_paths(_args):
    def mark(m):
        path = m.group(1).rstrip(".,;:")
        trail = m.group(1)[len(path):]
        ok = not path.startswith("/nix/store/") and bool(glob.glob(path))
        return m.group(1) if ok else f"{path} (unverified){trail}"

    for line in sys.stdin:
        head, sep, tail = line.partition("Check:")
        sys.stdout.write(head + sep + CHECK_PATH.sub(mark, tail) if sep else line)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("split")
    s.add_argument("--lines", required=True)
    s.add_argument("--table", action="append", default=[])
    s.add_argument("--known-out", required=True)
    s.add_argument("--rest-out", required=True)
    s.add_argument("--since", default="today", help="journalctl --since for cleared-by checks")
    s.set_defaults(fn=split)
    c = sub.add_parser("check-paths")
    c.set_defaults(fn=check_paths)
    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
