#!/usr/bin/env python3
"""secrets: one place to see, set and replace every sops secret the fleet declares.
Design: docs/superpowers/specs/2026-10-27-secrets-hardening-design.md

  secrets                      pick a secret in fzf, then set it or change its expiry
  secrets list                 every declared secret: hosts, set/missing, age, expiry countdown
  secrets set NAME [-m] [--from-file PATH]
                               prompt (hidden) for a value and write it; replacing counts as a rotation
  secrets expire NAME DATE     YYYY-MM-DD, +Nd, or none
  secrets add NAME [--hosts desktop,surface] [--desc TEXT] [-m] [--from-file PATH]
                               a new secret of your own, at /run/secrets/NAME on those hosts
  secrets rm NAME              delete an orphan, or a secret you added
  secrets passwd NAME          new login password for a *_password_hash (asked twice, stored hashed)

NAME is the sops key, or file:key when two files hold the same key.
Values only ever travel over stdin and live in memory: never argv, a temp file, or the screen.
Writes use the passphrase-encrypted editor key (scripts/sops-editor-key.sh), asked for once.
"""

import datetime as dt
import getpass
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile
import termios

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.environ.get("SECRETS_REPO") or os.path.dirname(HERE)
HOSTS = ["desktop", "surface", "retro", "pi"]
EDITOR_KEY = os.environ.get("SECRETS_EDITOR_KEY", os.path.expanduser("~/.config/sops/age/editor.age"))
# Tests swap in `cat`: age reads passphrases only from a terminal.
DECRYPT = os.environ.get("SECRETS_DECRYPT", "age -d").split()
META = "secrets/meta.json"
REGISTRY = "secrets/registry.json"
# Which file a secret of your own lands in, by the hosts that read it (roles/sops-registry.nix).
FILE_FOR = {
    ("desktop", "surface"): "secrets/shared.yaml",
    ("desktop",): "secrets/desktop.yaml",
    ("surface",): "secrets/surface.yaml",
}
# Values that are whole files (env blocks, WireGuard confs, PEM) are pasted, not typed.
MULTILINE = re.compile(r"(_env|_conf|_cert|syncthing_.*_key)$")


def today():
    return dt.date.fromisoformat(os.environ["SECRETS_TODAY"]) if "SECRETS_TODAY" in os.environ else dt.date.today()


def die(msg):
    print(f"secrets: {msg}", file=sys.stderr)
    sys.exit(1)


def git(*args):
    return subprocess.run(["git", "-C", REPO, *args], capture_output=True, text=True, check=False).stdout


def declarations():
    """(host, file, key) for every sops.secrets entry every host evaluates."""
    if "SECRETS_DECLS" in os.environ:
        with open(os.environ["SECRETS_DECLS"]) as fh:
            lines = fh.read().splitlines()
        # stands in for the eval, which includes roles/sops-registry.nix
        lines += [f"{h}\t{e['file']}\t{e['name']}" for e in load_registry() for h in e["hosts"]]
    else:
        lines = []
        apply = (
            'm: builtins.concatStringsSep "" (map (s: "${toString s.sopsFile}\\t${s.key}\\n") (builtins.attrValues m))'
        )
        for h in HOSTS:
            out = subprocess.run(
                ["nix", "eval", "--raw", f"{REPO}#nixosConfigurations.{h}.config.sops.secrets", "--apply", apply],
                capture_output=True,
                text=True,
                check=False,
            )
            if out.returncode:
                die(f"evaluating {h} failed:\n{out.stderr}")
            # sopsFile stringifies to the flake's store copy; strip that back to a repo path.
            lines += [h + "\t" + re.sub(r"^/nix/store/[^/]+/", "", line) for line in out.stdout.splitlines()]
    return [tuple(line.split("\t")) for line in lines if line.strip()]


def file_keys(path):
    """Top-level keys of a sops yaml and whether each holds a real value (names are plaintext)."""
    keys = {}
    with open(os.path.join(REPO, path)) as fh:
        for line in fh:
            m = re.match(r"^([A-Za-z0-9_.-]+):(.*)$", line)
            if m and m.group(1) != "sops":
                keys[m.group(1)] = "placeholder" if "ENC[REDACTED]" in m.group(2) else "set"
    return keys


def load_meta():
    try:
        with open(os.path.join(REPO, META)) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return {}


def load_registry():
    try:
        with open(os.path.join(REPO, REGISTRY)) as fh:
            return json.load(fh)
    except FileNotFoundError:
        return []


def save_registry(registry):
    with open(os.path.join(REPO, REGISTRY), "w") as fh:
        json.dump(sorted(registry, key=lambda e: e["name"]), fh, indent=2)
        fh.write("\n")


def save_meta(meta):
    with open(os.path.join(REPO, META), "w") as fh:
        json.dump(dict(sorted(meta.items())), fh, indent=2)
        fh.write("\n")


def first_seen(path, key):
    """Date a key first appeared in git — the best "added" there is for secrets older than meta.json."""
    dates = git("log", "--reverse", "--format=%as", "-G", f"^{re.escape(key)}:", "--", path).split()
    return dates[0] if dates else None


def inventory():
    """One row per file:key, declared or not (undeclared ones are orphans)."""
    rows = {}
    for host, path, key in declarations():
        key = key.split("/")[0]
        rows.setdefault(f"{path}:{key}", {"file": path, "key": key, "hosts": []})["hosts"].append(host)
    files = sorted({r["file"] for r in rows.values()} | set(git("ls-files", "secrets/*.yaml").split()))
    meta = load_meta()
    for path in files:
        present = file_keys(path) if os.path.exists(os.path.join(REPO, path)) else {}
        for key in present:
            rows.setdefault(f"{path}:{key}", {"file": path, "key": key, "hosts": []})
        for ref, row in rows.items():
            if row["file"] == path:
                row["status"] = present.get(row["key"], "missing")
                if not row["hosts"]:
                    row["status"] = "orphan"
    for ref, row in rows.items():
        m = meta.get(ref, {})
        row["added"] = m.get("added") or (first_seen(row["file"], row["key"]) if row["status"] != "missing" else None)
        row["rotated"] = m.get("rotated")
        row["expires"] = m.get("expires")
    return dict(sorted(rows.items(), key=lambda kv: (kv[1]["key"], kv[0])))


def ago(date):
    if not date:
        return "—"
    days = (today() - dt.date.fromisoformat(date)).days
    return "today" if days == 0 else f"{days}d ago"


def countdown(date):
    if not date:
        return ""
    days = (dt.date.fromisoformat(date) - today()).days
    if days < 0:
        return f"EXPIRED {-days}d ago"
    return "expires today" if days == 0 else f"expires in {days}d"


MARK = {"set": "✓ set", "missing": "✗ missing", "placeholder": "✗ placeholder", "orphan": "· orphan"}


def format_rows(rows):
    out = []
    for r in rows.values():
        hosts = ",".join(r["hosts"]) or "nobody"
        out.append(
            f"{r['key']:<28} {r['file'].removeprefix('secrets/'):<15} {hosts:<28} {MARK[r['status']]:<14}"
            f" added {ago(r['added']):<9} rotated {ago(r['rotated']):<9} {countdown(r['expires'])}".rstrip()
        )
    return out


def resolve(rows, name, orphans=False):
    """file:key for NAME. A key can sit in several files (an active copy plus leftovers), so
    set/expire prefer the declared copy and rm (orphans=True) the leftovers."""
    if name in rows:
        return name
    hits = [ref for ref, r in rows.items() if r["key"] == name]
    if not hits:
        die(f"no secret named {name} (secrets list shows them all)")
    preferred = [ref for ref in hits if bool(rows[ref]["hosts"]) != orphans]
    if len(preferred) == 1:
        return preferred[0]
    if len(hits) == 1:
        return hits[0]
    die(f"{name} is in several files; say which: " + ", ".join(preferred or hits))


def read_value(multiline, from_file):
    if from_file:
        with open(from_file) as fh:
            return fh.read()
    if not multiline:
        value = getpass.getpass("value (hidden): ")
        if getpass.getpass("again: ") != value:
            die("the two entries differ, nothing written")
        return value
    print("paste the value (hidden), then Ctrl-D on an empty line:", file=sys.stderr)
    fd = sys.stdin.fileno()
    old = termios.tcgetattr(fd)
    new = termios.tcgetattr(fd)
    new[3] &= ~termios.ECHO
    try:
        termios.tcsetattr(fd, termios.TCSADRAIN, new)
        value = sys.stdin.read()
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, old)
    return value if value.endswith("\n") else value + "\n"


def check_value(value):
    """Refuse values that can't work: a provider's masked copy, or a WireGuard conf without its private key."""
    if not value.strip():
        die("empty value, nothing written")
    if re.search(r"(^|=)\s*\*{3,}\s*$", value, re.MULTILINE):
        die("the value has a masked field (*****) — a redacted copy, not the real thing; nothing written")
    if "[Interface]" in value and not re.search(r"^PrivateKey\s*=\s*[A-Za-z0-9+/]{43}=\s*$", value, re.MULTILINE):
        die("WireGuard config without a valid PrivateKey; download it from the creation pop-up; nothing written")


def fingerprint(value):
    lines = value.count("\n") + (0 if value.endswith("\n") else 1)
    return f"{len(value)} chars, {lines} line(s), sha256 {hashlib.sha256(value.encode()).hexdigest()[:8]}"


def editor_identity():
    if not os.path.exists(EDITOR_KEY):
        die(f"{EDITOR_KEY} missing (scripts/sops-editor-key.sh; copy it from desktop)")
    out = subprocess.run([*DECRYPT, EDITOR_KEY], stdout=subprocess.PIPE, check=False)
    if out.returncode:
        die("couldn't decrypt the editor key")
    return out.stdout.decode()


def sops(args, identity, stdin=None):
    # An empty HOME keeps sops from reaching for any other key; values only ever go in on stdin.
    with tempfile.TemporaryDirectory() as home:
        env = {"PATH": os.environ["PATH"], "HOME": home, "SOPS_AGE_KEY": identity}
        out = subprocess.run(["sops", *args], input=stdin, env=env, cwd=REPO, capture_output=True, check=False)
    if out.returncode:
        die(f"sops {args[0]} failed: {out.stderr.decode().strip()}")


def sops_set(path, key, value, identity):
    sops(["set", "--value-stdin", path, json.dumps([key])], identity, json.dumps(value).encode())


def read_checked(key, multiline, from_file):
    if not from_file and not multiline and MULTILINE.search(key):
        multiline = input("looks like a whole file — paste multi-line? [Y/n] ").strip().lower() != "n"
    value = read_value(multiline, from_file)
    check_value(value)
    print(f"got {fingerprint(value)}")
    if input("write it? [y/N] ").strip().lower() != "y":
        die("nothing written")
    return value


def flag(args, name):
    """Value of --name in args, and args without it."""
    if name not in args:
        return None, args
    i = args.index(name)
    if i + 1 >= len(args):
        die(f"{name} needs a value")
    return args[i + 1], args[:i] + args[i + 2 :]


def cmd_list(_args):
    rows = inventory()
    print("\n".join(format_rows(rows)))
    missing = sum(r["status"] in ("missing", "placeholder") for r in rows.values())
    expired = sum(bool(r["expires"]) and r["expires"] < today().isoformat() for r in rows.values())
    print(f"\n{len(rows)} secrets, {missing} need a value, {expired} expired")


def cmd_set(args, rows=None):
    from_file, args = flag(args, "--from-file")
    multiline = "-m" in args
    names = [a for a in args if not a.startswith("-")]
    if len(names) != 1:
        die("usage: secrets set NAME [-m] [--from-file PATH]")
    rows = rows or inventory()
    ref = resolve(rows, names[0])
    row = rows[ref]
    if row["status"] == "orphan":
        die(f"{ref} isn't declared by any host; nothing would read it")
    replacing = row["status"] == "set"
    print(
        f"{'replacing' if replacing else 'setting'} {row['key']} in {row['file']} (read by {', '.join(row['hosts'])})"
    )
    write(ref, row, read_checked(row["key"], multiline, from_file), replacing)


def write(ref, row, value, replacing):
    print("editor key passphrase:")
    identity = editor_identity()
    sops_set(row["file"], row["key"], value, identity)
    del identity, value

    meta = load_meta()
    entry = meta.setdefault(ref, {})
    stamp = today().isoformat()
    entry.setdefault("added", row["added"] if replacing and row["added"] else stamp)
    if replacing:
        entry["rotated"] = stamp
    save_meta(meta)
    # secrets/ is gitignored but tracked; the flake only sees what git has.
    git("add", "-f", row["file"], META)
    print(f"written and staged. deploy to pick it up: {', '.join(row['hosts'])}")


def cmd_passwd(args):
    if len(args) != 1:
        die("usage: secrets passwd NAME")
    rows = inventory()
    ref = resolve(rows, args[0])
    row = rows[ref]
    if not row["key"].endswith("_password_hash"):
        die(f"{row['key']} isn't a *_password_hash")
    print(f"new login password behind {row['key']} (used on {', '.join(row['hosts'])})")
    # mkpasswd asks once; a typo here is a password nobody knows, and root has none to fall back on.
    password = getpass.getpass("new password (hidden): ")
    if getpass.getpass("again: ") != password:
        die("the two entries differ, nothing written")
    if len(password) < 8 and input("shorter than 8 characters — use it anyway? [y/N] ").strip().lower() != "y":
        die("nothing written")
    out = subprocess.run(
        ["mkpasswd", "--method=yescrypt", "--stdin"], input=password.encode(), capture_output=True, check=False
    )
    del password
    if out.returncode:
        die(f"mkpasswd failed: {out.stderr.decode().strip()}")
    value = out.stdout.decode().strip()
    if not value.startswith("$y$"):
        die("mkpasswd didn't return a yescrypt hash, nothing written")
    if input("write it? [y/N] ").strip().lower() != "y":
        die("nothing written")
    write(ref, row, value, True)
    print(
        "before deploying: keep a root shell open (sudo -i) on each of those hosts until\n"
        "`sudo -k && sudo true` accepts the new password there — a wrong hash locks sudo out"
    )


def cmd_expire(args):
    if len(args) != 2:
        die("usage: secrets expire NAME YYYY-MM-DD|+Nd|none")
    rows = inventory()
    ref = resolve(rows, args[0])
    when = args[1]
    meta = load_meta()
    entry = meta.setdefault(ref, {})
    if when == "none":
        entry.pop("expires", None)
    else:
        m = re.fullmatch(r"\+(\d+)d", when)
        try:
            date = today() + dt.timedelta(days=int(m.group(1))) if m else dt.date.fromisoformat(when)
        except ValueError:
            die(f"not a date: {when}")
        entry["expires"] = date.isoformat()
    if rows[ref]["added"]:
        entry.setdefault("added", rows[ref]["added"])
    save_meta(meta)
    git("add", "-f", META)
    print(f"{ref}: {countdown(entry.get('expires')) or 'no expiry'}")


def cmd_add(args):
    from_file, args = flag(args, "--from-file")
    hosts_arg, args = flag(args, "--hosts")
    desc, args = flag(args, "--desc")
    multiline = "-m" in args
    names = [a for a in args if not a.startswith("-")]
    name = names[0] if names else input("name (lowercase, e.g. github_token): ").strip()
    if not re.fullmatch(r"[a-z][a-z0-9_]*", name):
        die(f"{name!r}: use lowercase letters, digits and _")
    rows = inventory()
    if any(r["key"] == name for r in rows.values()):
        die(f"{name} already exists (secrets list)")
    if hosts_arg is None:
        hosts_arg = input("read by which hosts? [desktop,surface] ").strip() or "desktop,surface"
    hosts = tuple(h for h in ("desktop", "surface") if h in hosts_arg.replace(" ", "").split(","))
    if not hosts or set(hosts_arg.replace(" ", "").split(",")) - set(hosts):
        die("hosts can be desktop, surface or both (retro and pi have no secrets file of their own yet)")
    if desc is None:
        desc = input("what is it for? ").strip()
    path = FILE_FOR[hosts]
    print(f"adding {name} to {path} (read by {', '.join(hosts)})")
    value = read_checked(name, multiline, from_file)
    print("editor key passphrase:")
    identity = editor_identity()
    sops_set(path, name, value, identity)
    del identity, value

    # value first, then the declaration: a declared secret with no value would fail secrets-lint
    registry = load_registry()
    registry.append({"name": name, "file": path, "hosts": list(hosts), "description": desc})
    save_registry(registry)
    meta = load_meta()
    meta[f"{path}:{name}"] = {"added": today().isoformat()}
    save_meta(meta)
    git("add", "-f", path, REGISTRY, META)
    print(f"written and staged. after a deploy to {', '.join(hosts)} it's at /run/secrets/{name} (owner: you)")


def cmd_rm(args):
    if len(args) != 1:
        die("usage: secrets rm NAME")
    rows = inventory()
    ref = resolve(rows, args[0], orphans=True)
    row = rows[ref]
    registry = load_registry()
    mine = [e for e in registry if e["name"] == row["key"] and e["file"] == row["file"]]
    if row["status"] != "orphan" and not mine:
        die(f"{ref} is declared in the nix config; remove it there first, then it shows up as an orphan here")
    what = "an orphan nothing reads" if row["status"] == "orphan" else f"read by {', '.join(row['hosts'])}"
    if input(f"delete {ref} ({what})? [y/N] ").strip().lower() != "y":
        die("nothing deleted")
    print("editor key passphrase:")
    identity = editor_identity()
    sops(["unset", row["file"], json.dumps([row["key"]])], identity)
    del identity

    staged = [row["file"]]
    if mine:
        save_registry([e for e in registry if e not in mine])
        staged.append(REGISTRY)
    meta = load_meta()
    if meta.pop(ref, None) is not None:
        save_meta(meta)
        staged.append(META)
    git("add", "-f", *staged)
    print("deleted and staged" + (f". deploy to {', '.join(row['hosts'])}" if mine else ""))


def cmd_pick(_args):
    rows = inventory()
    refs = list(rows)
    lines = [f"{i}\t{line}" for i, line in enumerate(format_rows(rows))]
    out = subprocess.run(
        [
            "fzf",
            "--with-nth=2..",
            "--delimiter=\t",
            "--header=enter: set or replace · ctrl-e: expiry · ctrl-a: add new · ctrl-x: delete",
            "--expect=enter,ctrl-e,ctrl-a,ctrl-x",
            "--no-sort",
        ],
        input="\n".join(lines),
        stdout=subprocess.PIPE,
        text=True,
        check=False,
    )
    if out.returncode or not out.stdout.strip():
        return
    key, *picked = out.stdout.splitlines()
    if key == "ctrl-a":
        cmd_add([])
        return
    if not picked:
        return
    ref = refs[int(picked[0].split("\t")[0])]
    if key == "ctrl-x":
        cmd_rm([ref])
    elif key == "ctrl-e":
        cmd_expire([ref, input("expires (YYYY-MM-DD, +Nd, none): ").strip()])
    else:
        cmd_set([ref], rows)


def main(argv):
    cmd, args = (argv[0], argv[1:]) if argv else ("pick", [])
    commands = {
        "list": cmd_list,
        "set": cmd_set,
        "replace": cmd_set,
        "expire": cmd_expire,
        "add": cmd_add,
        "rm": cmd_rm,
        "passwd": cmd_passwd,
        "pick": cmd_pick,
    }
    if cmd not in commands:
        print(__doc__.split("\n\n")[1], file=sys.stderr)
        sys.exit(2)
    commands[cmd](args)


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (KeyboardInterrupt, EOFError):
        print("\nsecrets: cancelled, nothing written", file=sys.stderr)
        sys.exit(130)
