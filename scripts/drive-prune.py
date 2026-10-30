#!/usr/bin/env python3
"""drive-prune: find, review and quarantine junk in the local Google Drive archive.

Every command takes --account ALIAS (default main), meaning <root> = /srv/prepko/Drive/ALIAS,
or --root DIR directly.

  drive-prune scan                  list candidates in <root>/.prune/candidates.json
  drive-prune rule GLOB [LABEL]     flag every file whose name matches GLOB on each scan
  drive-prune review                decide each candidate group in fzf (keys in its header)
  drive-prune apply [--dry-run]     move deletes into <root>/.pruned/, kept files back out
  drive-prune restore PATH          change PATH's decision to keep and apply
  drive-prune purge [--dry-run]     send every pruned file you own to Drive's trash

<root> is one Google account's archive: a directory per drive-pull side (mine/,
shared/), each with the .listing.json drive-pull writes; that listing is how a local
file maps back to its Drive ID, which is what purge deletes by. Scan reads only; it never
moves or deletes anything. Each candidate group carries the reason it was flagged and
a suggested action per file, which review starts from. Review records keep/delete per
file in <root>/.prune/decisions.tsv, keyed by Drive ID, so it only ever asks once.
Apply makes the files match the decisions and writes each side's .prune-exclude (rclone
filters) and .prune-ids (Drive IDs) so drive-pull stops fetching what was pruned. Nothing
is erased: .pruned/ is a quarantine, and its IDs are what purge sends to Drive's trash.
Purge signs in with write access through a gdrive-rw remote that exists only for the run;
the nightly gdrive remote stays read-only.
"""
import argparse
import fnmatch
import hashlib
import html
import json
import os
import re
import shlex
import subprocess
import sys
import textwrap
import zipfile
from datetime import datetime

ROOT = "/srv/prepko/Drive"
SIDES = ("mine", "shared")
# drive-pull names every member of a same-named group "name (<last 8 of id>).ext".
ID_SUFFIX = re.compile(r" \((?P<tail>[A-Za-z0-9_-]{8})\)$")
# Only zip-based formats: an old binary .doc can contain a stray zip header of its own.
OFFICE_EXT = {".docx", ".xlsx", ".pptx", ".odt", ".ods", ".odp"}
OFFICE_PARTS = re.compile(
    r"(word/(document|header\d*|footer\d*)|xl/sharedStrings|xl/worksheets/sheet\d+|ppt/slides/slide\d+|content)\.xml")
# Below this many non-space characters a document counts as empty.
EMPTY_CHARS = 10
# Drafts are found by shared text, not names: "April 3" and "April 14" are different
# pieces, "ATPF" and "ATPFWrewrite" are one. A pair is linked when this share of the
# smaller one's 5-word runs also appears in the larger, so a snippet joins its full text.
SHINGLE = 5
CONTAINMENT = 0.5
# Below this many 5-word runs there's too little text to call two files drafts.
MIN_SHINGLES = 30
# A poem inside a compiled collection isn't a draft of it; linking those chains every
# poem in the collection into one group.
MIN_SIZE_RATIO = 0.25
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".gif", ".webp", ".heic", ".bmp", ".tif", ".tiff"}
PLAIN_EXT = {".txt", ".md", ".csv", ".tsv", ".json", ".html", ".xml"}


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def office_text(path):
    """(text, has_media) of a zip-based office file, or (None, False) for anything else."""
    if os.path.splitext(path)[1].lower() not in OFFICE_EXT:
        return None, False
    try:
        with zipfile.ZipFile(path) as z:
            names = z.namelist()
            parts = [n for n in names if OFFICE_PARTS.fullmatch(n)]
            media = any(re.match(r"(word|ppt|xl)/media/|Pictures/", n) for n in names)
            xml = {n: z.read(n).decode("utf-8", "replace") for n in parts}
    except (zipfile.BadZipFile, OSError, KeyError):
        return None, False
    # xlsx cells of type "s" hold an index into sharedStrings, not the text itself.
    shared = [re.sub(r"<[^>]+>", "", si)
              for si in re.findall(r"<si>(.*?)</si>", xml.pop("xl/sharedStrings.xml", ""), re.DOTALL)]

    def cell(m):
        v = re.search(r"<v>(\d+)</v>", m["body"])
        if re.search(r'\bt="s"', m["attrs"]) and v and int(v[1]) < len(shared):
            return f"<c>{shared[int(v[1])]}</c>"
        return m[0]

    # [^>/]: an empty cell is self-closing; letting it match would scan ahead to the next
    # cell's </c>, once per empty cell (minutes on a large formatted sheet).
    raw = "\n".join(re.sub(r"(?s)<c\b(?P<attrs>[^>/]*)>(?P<body>.*?)</c>", cell, x) if n.startswith("xl/worksheets/") else x
                    for n, x in xml.items())
    # Runs split words mid-tag, so most tags vanish; paragraphs, rows and cells don't.
    raw = re.sub(r"</(w:p|a:p|text:p|text:h|row|table:table-row)>", "\n", raw)
    raw = re.sub(r"</(c|w:tc|table:table-cell)>|<w:tab/>|<w:br/>|<text:tab/>", " ", raw)
    lines = (" ".join(ln.split()) for ln in html.unescape(re.sub(r"<[^>]+>", "", raw)).splitlines())
    return "\n".join(ln for ln in lines if ln), media


def load_listing(side_dir):
    try:
        with open(os.path.join(side_dir, ".listing.json")) as fh:
            return json.load(fh)
    except (OSError, json.JSONDecodeError):
        return []


def drive_ids(listing):
    """rel path -> Drive ID, for unique names and for drive-pull's "name (<id8>)" copies.
    The plain-named copy of a same-named group is left out: which member rclone kept is
    unknown, and it's byte-identical to one of the ID-named copies anyway."""
    by_path = {}
    for e in listing:
        by_path.setdefault(e["Path"], []).append(e)
    ids = {}
    for path, entries in by_path.items():
        if len(entries) == 1:
            ids[path] = entries[0]["ID"]
            continue
        stem, ext = os.path.splitext(path) if "." in os.path.basename(path) else (path, "")
        for e in entries:
            ids[f"{stem} ({e['ID'][-8:]}){ext}"] = e["ID"]
    return ids


def walk(root):
    for side in SIDES:
        side_dir = os.path.join(root, side)
        ids = drive_ids(load_listing(side_dir))
        for d, dirs, files in os.walk(side_dir):
            dirs[:] = sorted(x for x in dirs if not x.startswith("."))
            for f in sorted(files):
                if f.startswith("."):
                    continue
                full = os.path.join(d, f)
                rel = os.path.relpath(full, side_dir)
                st = os.stat(full)
                yield {
                    "path": os.path.join(side, rel),
                    "id": ids.get(rel),
                    "size": st.st_size,
                    "mtime": datetime.fromtimestamp(st.st_mtime).strftime("%Y-%m-%d"),
                }


def shingles(text):
    words = re.findall(r"\w+", text.lower())
    return {hash(tuple(words[i:i + SHINGLE])) for i in range(len(words) - SHINGLE + 1)}


def keep_first(files, key):
    files = sorted(files, key=key)
    return [dict(f, suggest="keep" if i == 0 else "delete") for i, f in enumerate(files)]


def find_dups(files):
    by_hash = {}
    for f in files:
        by_hash.setdefault(f["sha"], []).append(f)
    # Keep the plain-named copy over drive-pull's "(id8)" ones, then the shortest name.
    return [
        {"reason": "duplicate", "detail": "identical contents", "files":
         keep_first(g, lambda f: (bool(ID_SUFFIX.search(os.path.splitext(f["path"])[0])), len(f["path"]), f["path"]))}
        for g in by_hash.values() if len(g) > 1
    ]


def find_empty(files):
    out = []
    for f in files:
        if f["text"] is not None and not f["media"] and len("".join(f["text"].split())) < EMPTY_CHARS:
            out.append({"reason": "empty", "detail": f"{len(f['text'])} chars of text",
                        "files": [dict(f, suggest="delete")]})
    return out


def find_versions(files):
    """Group documents that share text, as connected components of linked pairs."""
    docs = [(f, sh) for f in files if f["text"] and len(sh := shingles(f["text"])) >= MIN_SHINGLES]
    parent = list(range(len(docs)))

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    best = {}
    for i, (_, a) in enumerate(docs):
        for j in range(i + 1, len(docs)):
            b = docs[j][1]
            small, large = sorted((len(a), len(b)))
            if small / large < MIN_SIZE_RATIO:
                continue
            share = len(a & b) / small
            if share >= CONTAINMENT:
                parent[find(j)] = find(i)
                best[i] = max(best.get(i, 0), share)
                best[j] = max(best.get(j, 0), share)
    groups = {}
    for i, (f, _) in enumerate(docs):
        groups.setdefault(find(i), []).append(dict(f, overlap=round(best.get(i, 0), 2)))
    out = []
    for g in groups.values():
        # One content in many places is a duplicate, not a lineage.
        if len({f["sha"] for f in g}) < 2:
            continue
        # Newest kept; the rest are left for review, never suggested for deletion.
        g = sorted(g, key=lambda f: f["mtime"], reverse=True)
        out.append({"reason": "versions", "detail": f"{len(g)} drafts sharing text",
                    "files": [dict(f, suggest="keep" if i == 0 else "review") for i, f in enumerate(g)]})
    return out


def find_rules(files, rules):
    out = []
    for glob, label in rules:
        hit = [f for f in files if fnmatch.fnmatch(os.path.basename(f["path"]).lower(), glob.lower())]
        if hit:
            out.append({"reason": "rule", "detail": f"{label or glob} ({glob})",
                        "files": [dict(f, suggest="delete") for f in hit]})
    return out


def load_rules(state):
    try:
        with open(os.path.join(state, "rules")) as fh:
            lines = [ln.rstrip("\n") for ln in fh if ln.strip() and not ln.startswith("#")]
    except OSError:
        return []
    return [tuple((ln.split("\t", 1) + [""])[:2]) for ln in lines]


def scan(root):
    state = os.path.join(root, ".prune")
    files = list(walk(root))
    for f in files:
        full = os.path.join(root, f["path"])
        f["sha"] = sha256(full)
        f["text"], f["media"] = office_text(full)
    dups = find_dups(files)
    # Drafts are judged among what survives dedupe, so one file isn't flagged twice.
    gone = {f["path"] for g in dups for f in g["files"] if f["suggest"] == "delete"}
    groups = (find_rules(files, load_rules(state)) + dups + find_empty(files)
              + find_versions([f for f in files if f["path"] not in gone]))
    for g in groups:
        for f in g["files"]:
            f.pop("text", None)
            f.pop("media", None)
    os.makedirs(state, exist_ok=True)
    with open(os.path.join(state, "candidates.json"), "w") as fh:
        json.dump(groups, fh, indent=1)
    return files, groups


def human(n):
    for unit in ("B", "K", "M", "G"):
        if n < 1024:
            return f"{n:.0f}{unit}"
        n /= 1024
    return f"{n:.1f}T"


def summary(files, groups):
    print(f"{len(files)} files scanned")
    for reason in ("rule", "duplicate", "empty", "versions"):
        gs = [g for g in groups if g["reason"] == reason]
        if not gs:
            continue
        fs = [f for g in gs for f in g["files"]]
        dels = [f for f in fs if f["suggest"] == "delete"]
        print(f"  {reason:<10} {len(gs):>4} groups  {len(fs):>4} files  "
              f"{len(dels):>4} suggested delete ({human(sum(f['size'] for f in dels))})")


def key(f):
    return f["id"] or f"path:{f['path']}"


def load_log(state):
    """key -> (decision, path); a later line wins, so re-deciding is just appending."""
    out = {}
    try:
        with open(os.path.join(state, "decisions.tsv")) as fh:
            for ln in fh:
                k, decision, path, *_ = ln.rstrip("\n").split("\t")
                out[k] = (decision, path)
    except OSError:
        pass
    return out


def load_decisions(state):
    return {k: d for k, (d, _) in load_log(state).items()}


def append(state, rows):
    today = datetime.now().strftime("%Y-%m-%d")
    with open(os.path.join(state, "decisions.tsv"), "a") as fh:
        fh.writelines(f"{k}\t{decision}\t{path}\t{reason}\t{today}\n" for k, decision, path, reason in rows)


def record(state, group, delete):
    append(state, [(key(f), "delete" if f["path"] in delete else "keep", f["path"], group["reason"])
                   for f in group["files"]])


def is_id_copy(k, rel):
    """drive-pull's "name (<last 8 of id>)" copy of a same-named file, judged by the ID it
    was recorded under, so a file merely named "Notes (20240101)" isn't mistaken for one."""
    return not k.startswith("path:") and os.path.splitext(rel)[0].endswith(f" ({k[-8:]})")


def rclone_filter(rel):
    """An --exclude-from line matching exactly this path under the side's root."""
    return "/" + re.sub(r"([\\*?\[\]{}])", r"\\\1", rel)


def apply(root, dry_run=False):
    """Move files into or out of .pruned/ to match decisions, then rewrite skip lists."""
    state = os.path.join(root, ".prune")
    log = load_log(state)
    moved = restored = 0
    size = 0
    for decision, rel in log.values():
        live, held = os.path.join(root, rel), os.path.join(root, ".pruned", rel)
        src, dst = (live, held) if decision == "delete" else (held, live)
        if not os.path.exists(src) or os.path.exists(dst):
            continue
        if decision == "delete":
            moved += 1
            size += os.path.getsize(src)
        else:
            restored += 1
        print(f"{'pruned  ' if decision == 'delete' else 'restored'} {rel}")
        if not dry_run:
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            os.rename(src, dst)
    for side in SIDES:
        rels = [(k, rel.split("/", 1)[1]) for k, (d, rel) in log.items() if d == "delete" and rel.startswith(side + "/")]
        # A same-named copy is fetched by ID, so it's skipped by ID; every other path by filter.
        excl = sorted(rclone_filter(r) for k, r in rels if not is_id_copy(k, r))
        ids = sorted(k for k, _ in rels if not k.startswith("path:"))
        side_dir = os.path.join(root, side)
        if dry_run or not os.path.isdir(side_dir):
            continue
        for name, lines in ((".prune-exclude", excl), (".prune-ids", ids)):
            with open(os.path.join(side_dir, name), "w") as fh:
                fh.writelines(ln + "\n" for ln in lines)
    verb = "would move" if dry_run else "moved"
    print(f"{verb} {moved} to .pruned/ ({human(size)}), {restored} back")


def restore(root, rel):
    state = os.path.join(root, ".prune")
    rel = rel.removeprefix(".pruned/")
    hits = [k for k, (d, p) in load_log(state).items() if p == rel]
    if not hits:
        sys.exit(f"drive-prune: no decision for {rel}")
    append(state, [(k, "keep", rel, "restore") for k in hits])
    apply(root)


def fingerprint(path):
    """Text for office files, bytes otherwise: Drive re-exports a native Google Doc with
    fresh zip timestamps on every pull, so two exports of one doc never hash alike."""
    text, _ = office_text(path)
    return ("text", text) if text else ("sha", sha256(path))


def group_twin(root, k, rel, gone):
    """For an ID copy being purged whose plain-named sibling was kept: does that kept file
    still exist on Drive afterwards? The plain copy *is* one member of the same-named
    group, so purging every ID in the group would take the kept file off Drive too.
    Returns None when nothing needs sparing, the ID to spare, or "?" when unsure."""
    stem, ext = os.path.splitext(rel)
    plain = stem.removesuffix(f" ({k[-8:]})") + ext
    if not os.path.exists(os.path.join(root, plain)):
        return None
    want = fingerprint(os.path.join(root, plain))
    sib = re.compile(re.escape(os.path.basename(stem.removesuffix(f" ({k[-8:]})"))) + r" \([A-Za-z0-9_-]{8}\)"
                     + re.escape(ext))
    d = os.path.dirname(plain)
    for name in sorted(os.listdir(os.path.join(root, d))):
        if sib.fullmatch(name) and fingerprint(os.path.join(root, d, name)) == want:
            return None
    for gk, grel in sorted(gone.items()):
        if os.path.dirname(grel) == d and sib.fullmatch(os.path.basename(grel)):
            held = os.path.join(root, ".pruned", grel)
            if os.path.exists(held) and fingerprint(held) == want:
                return gk
    return "?"


def purge_targets(root):
    """([(id, rel, size)] to trash, shared rels to remove by hand, notes)."""
    state = os.path.join(root, ".prune")
    done = {ln.split("\t", 1)[0] for ln in open_lines(os.path.join(state, "purged.tsv"))}
    gone = {k: rel for k, (d, rel) in load_log(state).items()
            if d == "delete" and not k.startswith("path:") and k not in done}
    spare, notes = set(), []
    for k, rel in sorted(gone.items(), key=lambda kv: kv[1]):
        if rel.startswith("mine/") and is_id_copy(k, rel):
            twin = group_twin(root, k, rel, gone)
            if twin == "?":
                spare.add(k)
                notes.append(f"kept: {rel} (its kept same-named copy matches nothing on disk)")
            elif twin and twin not in spare:
                spare.add(twin)
                notes.append(f"kept: {gone[twin]} (it is the Drive file behind a copy you kept)")
    targets, manual = [], []
    for k, rel in sorted(gone.items(), key=lambda kv: kv[1]):
        if k in spare:
            continue
        if not rel.startswith("mine/"):
            manual.append(rel)
            continue
        held = os.path.join(root, ".pruned", rel)
        targets.append((k, rel, os.path.getsize(held) if os.path.exists(held) else 0))
    return targets, manual, notes


def open_lines(path):
    try:
        with open(path) as fh:
            return [ln.rstrip("\n") for ln in fh if ln.strip()]
    except OSError:
        return []


def rclone(*args, check=True):
    return subprocess.run(["rclone", *args], check=check)


def purge(root, account, dry_run=False):
    targets, manual, notes = purge_targets(root)
    for k, rel, size in targets:
        print(f"  {human(size):>5}  {rel}")
    for n in notes:
        print(f"  {n}")
    print(f"{len(targets)} files ({human(sum(t[2] for t in targets))}) to Drive's trash")
    if manual:
        print("shared with you, not yours to trash; remove these from 'Shared with me' by hand:")
        for rel in manual:
            print(f"  {rel}")
    if dry_run or not targets:
        return
    if input("type 'trash' to send these to Drive's trash (restorable for 30 days): ").strip() != "trash":
        sys.exit("nothing changed")
    created = "gdrive-rw:" not in subprocess.run(["rclone", "listremotes"], capture_output=True, text=True,
                                                  check=True).stdout.split()
    if created:
        print(f"sign in as the Google account you call '{account}', allowing full Drive access (this run only)")
        # stdout gets the finished remote, live token included; the sign-in link is on stderr.
        subprocess.run(["rclone", "config", "create", "gdrive-rw", "drive", "scope=drive"],
                       stdout=subprocess.DEVNULL, check=True)
    folder = f"drive-prune-trash-{datetime.now():%Y-%m-%d-%H%M%S}"
    state = os.path.join(root, ".prune")
    try:
        moved = []
        for k, rel, _ in targets:
            # One folder per run, then one trash call: rclone can move by ID but not delete by ID.
            name = f"{k[-8:]} {os.path.basename(rel)}"
            if rclone("backend", "moveid", "gdrive-rw:", k, f"gdrive-rw:{folder}/{name}", check=False).returncode:
                print(f"  failed, left in place: {rel}")
                continue
            moved.append((k, rel))
        if moved:
            rclone("purge", "--drive-use-trash", f"gdrive-rw:{folder}")
            today = datetime.now().strftime("%Y-%m-%d")
            with open(os.path.join(state, "purged.tsv"), "a") as fh:
                fh.writelines(f"{k}\t{rel}\t{folder}\t{today}\n" for k, rel in moved)
        print(f"sent {len(moved)} files to Drive's trash (folder {folder})")
    finally:
        if created:
            rclone("config", "delete", "gdrive-rw", check=False)


def fzf_lines(group):
    # Suggested deletes first: the load binding pre-selects that many rows from the top.
    files = sorted(group["files"], key=lambda f: f["suggest"] != "delete")
    return [f"{f['path']}\t{f['suggest']:<6}  {human(f['size']):>5}  {f['mtime']}  {f['path'].split('/', 1)[1]}"
            for f in files]


def fzf_args(group, n, total, preview):
    pre = sum(f["suggest"] == "delete" for f in group["files"])
    start = "+".join(["toggle+down"] * pre + ["first"])
    return [
        "fzf", "--multi", "--layout=reverse", "--delimiter=\t", "--with-nth=2", "--expect=ctrl-s",
        (f"--header=[{n}/{total}] {group['reason']}: {group['detail']}\n"
         "tab: toggle delete   enter: selected=delete, rest=keep   ctrl-s: skip   esc: stop"),
        "--header-first", f"--preview={preview} {{1}}", "--preview-window=right,60%,wrap",
        f"--bind=load:{start}",
        # fzf prints the cursor row when nothing is selected; that must mean "delete nothing".
        "--bind=enter:transform:[ \"$FZF_SELECT_COUNT\" -eq 0 ] && echo \"become(true)\" || echo accept",
    ]


def parse_fzf(out):
    """fzf output -> ('skip', set()) or ('decide', paths to delete)."""
    lines = out.splitlines()
    if lines and lines[0] == "ctrl-s":
        return "skip", set()
    return "decide", {ln.split("\t", 1)[0] for ln in lines[1:] if ln}


def review(root):
    state = os.path.join(root, ".prune")
    try:
        with open(os.path.join(state, "candidates.json")) as fh:
            groups = json.load(fh)
    except OSError:
        sys.exit("drive-prune: no candidates; run `drive-prune scan` first")
    decided = load_decisions(state)
    todo = [g for g in groups if any(key(f) not in decided for f in g["files"])]
    preview = f"{shlex.quote(sys.executable)} {shlex.quote(os.path.abspath(__file__))} --root {shlex.quote(root)} preview"
    for n, g in enumerate(todo, 1):
        r = subprocess.run(fzf_args(g, n, len(todo), preview), input="\n".join(fzf_lines(g)),
                           stdout=subprocess.PIPE, text=True, check=False)
        if r.returncode == 130:
            print(f"stopped at {n}/{len(todo)}; run review again to continue")
            return
        action, delete = parse_fzf(r.stdout)
        if action == "decide":
            record(state, g, delete)
    print(f"reviewed {len(todo)} groups")


def preview(root, rel):
    full = os.path.join(root, rel)
    st = os.stat(full)
    cols = int(os.environ.get("FZF_PREVIEW_COLUMNS", "80"))
    rows = int(os.environ.get("FZF_PREVIEW_LINES", "40"))
    # Flushed: pdftotext/chafa write straight to the terminal, ahead of anything buffered.
    print(f"{rel}\n{human(st.st_size)}  {datetime.fromtimestamp(st.st_mtime):%Y-%m-%d}\n", flush=True)
    ext = os.path.splitext(full)[1].lower()
    text, media = office_text(full)
    if text is None and ext in PLAIN_EXT:
        with open(full, errors="replace") as fh:
            text = fh.read(20000)
    if text is not None:
        if media:
            print("(contains images)\n")
        for para in text.splitlines()[:300]:
            print(textwrap.fill(para, cols) if para else "")
        if not text.strip():
            print("(no text)")
    elif ext == ".pdf":
        subprocess.run(["pdftotext", "-l", "3", "-layout", full, "-"], check=False)
    elif ext in IMAGE_EXT:
        subprocess.run(["chafa", f"--size={cols}x{rows - 4}", full], check=False)
    else:
        print("(no preview for this type)")


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--account", default="main")
    ap.add_argument("--root")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("scan")
    sub.add_parser("review")
    p = sub.add_parser("preview")
    p.add_argument("path")
    a = sub.add_parser("apply")
    a.add_argument("--dry-run", action="store_true")
    rs = sub.add_parser("restore")
    rs.add_argument("path")
    pg = sub.add_parser("purge")
    pg.add_argument("--dry-run", action="store_true")
    r = sub.add_parser("rule")
    r.add_argument("glob")
    r.add_argument("label", nargs="?", default="")
    args = ap.parse_args()
    args.root = args.root or os.path.join(ROOT, args.account)

    if args.cmd == "preview":
        preview(args.root, args.path)
        return
    if args.cmd == "apply":
        apply(args.root, args.dry_run)
        return
    if args.cmd == "purge":
        purge(args.root, args.account, args.dry_run)
        return
    if args.cmd == "restore":
        restore(args.root, args.path)
        return
    if args.cmd == "review":
        review(args.root)
        return
    if args.cmd == "rule":
        state = os.path.join(args.root, ".prune")
        os.makedirs(state, exist_ok=True)
        with open(os.path.join(state, "rules"), "a") as fh:
            fh.write(f"{args.glob}\t{args.label}\n")
        print(f"added rule {args.glob!r}; run `drive-prune scan` to apply")
        return
    if not any(os.path.isdir(os.path.join(args.root, s)) for s in SIDES):
        sys.exit(f"drive-prune: nothing under {args.root}; run drive-pull first")
    summary(*scan(args.root))


if __name__ == "__main__":
    main()
