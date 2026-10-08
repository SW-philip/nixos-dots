import os, re, subprocess, sys
from pathlib import Path

from drmis import THEMES_ROOT, current_theme, do_set, do_toggle, family_flags, get_all_themes, parse_palette

def slug_from_name(name):
    return re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")


ROSE_PINE_VARIANT_SLUGS = {"main": "midnight-rose", "moon": "indigo-rose", "dawn": "cream-terracotta"}


def scaffold_theme(name, family, extra_args=None):
    if "--rose-pine" in (extra_args or []):
        n = name.lower()
        variant = "dawn" if "dawn" in n else "moon" if "moon" in n else "main"
        slug = ROSE_PINE_VARIANT_SLUGS[variant]
    else:
        slug = slug_from_name(name)
    dest = THEMES_ROOT / family / slug
    if dest.exists():
        print(f"drmis: '{dest}' already exists — delete it first to regenerate", file=sys.stderr); sys.exit(1)
    auto_theme = Path.home() / "nixos" / "scripts" / "auto-theme.py"
    cmd = ["uv", "run", str(auto_theme), name, "--register-only", "--output-dir", str(dest)] + (extra_args or [])
    result = subprocess.run(cmd)
    if result.returncode != 0:
        sys.exit(result.returncode)
    print(f"\nScaffolded: {dest}")
    print(f"  run nrs to make the theme available")


def print_palette(slug):
    sh_path = None
    for fam_dir in THEMES_ROOT.iterdir() if THEMES_ROOT.exists() else []:
        if not fam_dir.is_dir(): continue
        candidate = fam_dir / slug / f"palette-{slug}.sh"
        if candidate.exists():
            sh_path = candidate; break
    if not sh_path:
        print(f"drmis: theme '{slug}' not found", file=sys.stderr); sys.exit(1)
    colors = parse_palette(sh_path)
    family = sh_path.parent.parent.name
    print(f"\n  \033[1m{slug}\033[0m  \033[2m({family})\033[0m\n")
    for k, v in sorted(colors.items()):
        if v.startswith("#"):
            r, g, b = int(v[1:3], 16), int(v[3:5], 16), int(v[5:7], 16)
            print(f"  \033[48;2;{r};{g};{b}m  \033[0m  \033[2m{k:<26}\033[0m {v}")
    print()


def do_get(args):
    auto_theme = Path.home() / "nixos" / "scripts" / "auto-theme.py"

    if "--sources" in args:
        subprocess.run(["uv", "run", str(auto_theme), "--sources"])
        return

    if "--compare" in args:
        idx   = args.index("--compare")
        query = args[idx + 1] if idx + 1 < len(args) and not args[idx + 1].startswith("-") else None
        if not query:
            print("drmis get --compare: query required", file=sys.stderr); sys.exit(1)
        subprocess.run(["uv", "run", str(auto_theme), query, "--compare"])
        return

    fam_flags = family_flags()
    for a in args:
        family = fam_flags.get(a.lower()) if a.startswith("--") else None
        if family:
            idx  = args.index(a)
            name = (args[idx + 1] if idx + 1 < len(args)
                    and not args[idx + 1].startswith("-") else None)
            if not name:
                print(f"drmis get {a}: name required", file=sys.stderr); sys.exit(1)
            # The folder flag only chooses the destination family; the keyword
            # search (API) happens for every family inside auto-theme.py.
            extra = ["--rose-pine"] if family == "Rose-Pine" else None
            scaffold_theme(name, family, extra_args=extra)
            return

    if "--new" in args:
        idx    = args.index("--new")
        name   = args[idx + 1] if idx + 1 < len(args) else None
        family = "Custom"
        if "--family" in args:
            fi = args.index("--family")
            family = args[fi + 1] if fi + 1 < len(args) else "Custom"
        if not name:
            print("drmis get --new: name required", file=sys.stderr); sys.exit(1)
        scaffold_theme(name, family)
        return

    slug = next((a for a in args if not a.startswith("-")), None) or current_theme()
    print_palette(slug)


def regen_wallpapers(family=None, force=False):
    script = Path.home() / "nixos" / "scripts" / "make-splotch-bg.py"
    if not script.exists():
        print(f"drmis: {script} not found, skipping wallpapers", file=sys.stderr)
        return
    if not family:
        subprocess.run([sys.executable, str(script), "--all"])
        return
    if not THEMES_ROOT.exists():
        return
    for fam_dir in sorted(THEMES_ROOT.iterdir()):
        if not fam_dir.is_dir() or fam_dir.name.lower() != family.lower():
            continue
        for theme_dir in sorted(fam_dir.iterdir()):
            if not theme_dir.is_dir() or not list(theme_dir.glob("palette-*.sh")):
                continue
            r = subprocess.run([sys.executable, str(script), str(theme_dir)])
            status = "generated" if r.returncode == 0 else "FAILED"
            print(f"  wallpaper {theme_dir.name}: {status}",
                  file=sys.stderr if r.returncode else sys.stdout)


def do_regen(args):
    auto_theme = Path.home() / "nixos" / "scripts" / "auto-theme.py"
    force  = "--force" in args
    # matches both "--<family>" flags and a bare "drmis regen custom / teams /
    # rose-pine" positional arg (families discovered dynamically); first match in args wins.
    fam_names = {name.lower(): name for name in family_flags().values()}
    family = None
    for a in args:
        key = a[2:].lower() if a.startswith("--") else a.lower()
        if key in fam_names:
            family = fam_names[key]
            break
    wallpapers_only = "--wallpapers-only" in args
    no_wallpapers   = "--no-wallpapers" in args
    if not wallpapers_only:
        cmd = ["uv", "run", str(auto_theme), "--batch"]
        if family:
            cmd += ["--family", family]
        if force:
            cmd += ["--force"]
        result = subprocess.run(cmd)
        if result.returncode != 0:
            sys.exit(result.returncode)
    if not no_wallpapers:
        regen_wallpapers(family, force)


SWATCH_KEYS = ("HALL", "STAGE", "WING", "FORTE", "PIANO", "SOTTO", "SEVENTH", "FIFTH", "ROOT")


PICK_SECTIONS = [
    ("Custom",    "🎨 Themes"),
    ("Rose-Pine", "🌹 Rosé Pine"),
]


PICK_SELECTABLE = ("theme", "action")


def build_pick_rows(themes):
    """themes: list of (slug, family, dir, sh, colors). Returns ordered rows.

    Row kinds: "header" (non-selectable title), "theme" (a theme),
    "action" (e.g. Random). Families not in PICK_SECTIONS still get a
    section under their raw name so new themes are never hidden.
    """
    rows = []
    seen = set()

    def add_family(fam, title):
        members = [t for t in themes if t[1] == fam]
        if not members:
            return
        rows.append({"kind": "header", "label": title})
        for slug, family, _td, _sh, colors in members:
            rows.append({"kind": "theme", "label": slug, "slug": slug,
                         "family": family, "colors": colors})
        seen.add(fam)

    for fam, title in PICK_SECTIONS:
        add_family(fam, title)
    for fam in dict.fromkeys(t[1] for t in themes):  # preserve first-seen order
        if fam not in seen:
            add_family(fam, fam)

    rows.append({"kind": "header", "label": "🎲 Shuffle"})
    rows.append({"kind": "action", "label": "Random (any)", "action": "random"})
    return rows


def selectable_indices(rows):
    return [i for i, r in enumerate(rows) if r["kind"] in PICK_SELECTABLE]


def move_cursor(rows, idx, delta):
    """Move to the next selectable row in direction delta, skipping headers, wrapping.

    Robust for any idx: if idx is a non-selectable (header) row, snaps to the
    nearest selectable row in the direction of travel (wrapping at the ends).
    """
    sel = selectable_indices(rows)
    if not sel:
        return idx
    if idx in sel:
        return sel[(sel.index(idx) + delta) % len(sel)]
    if delta >= 0:
        return next((i for i in sel if i > idx), sel[0])
    return next((i for i in reversed(sel) if i < idx), sel[-1])


def run_pick(theme_map):
    try:
        import readchar
    except ImportError:
        sys.exit("drmis pick: readchar not found -- rebuild with nrs")
    from rich.console import Console
    from rich.text import Text
    from rich.panel import Panel
    from rich.style import Style
    import random

    themes = get_all_themes()
    rows   = build_pick_rows(themes)
    sel    = selectable_indices(rows)
    if not sel:
        sys.exit("drmis pick: no themes found")
    cur     = current_theme()
    idx     = sel[0]
    console = Console()
    K       = readchar.key

    def render():
        console.clear()
        body = Text()
        for i, r in enumerate(rows):
            if r["kind"] == "header":
                body.append(("\n" if i else "") + r["label"] + "\n", style="bold")
                continue
            here = (i == idx)
            is_cur = r.get("slug") == cur
            line = Text()
            line.append("  > " if here else "    ", style="bold cyan" if here else "")
            line.append("● " if is_cur else "  ", style="bold green" if is_cur else "")
            line.append(f"{r['label']:<22}",
                        style="reverse" if here else ("bold" if is_cur else ""))
            if r["kind"] == "theme":
                for k in SWATCH_KEYS:
                    c = r["colors"].get(k, "")
                    if c and c.startswith("#"):
                        line.append("  ", style=Style(bgcolor=c))
            body.append_text(line)
            body.append("\n")
        console.print(Panel(body, title="[bold]drmis[/bold]",
                            subtitle=f"current: [green]{cur}[/green]"))
        console.print("[dim]↑↓ move · enter apply · q cancel[/dim]")

    while True:
        render()
        try:
            key = readchar.readkey()
        except KeyboardInterrupt:
            break
        if key in ("q", "Q", K.ESC, "\x03"):
            break
        elif key in (K.UP, "k"):
            idx = move_cursor(rows, idx, -1)
        elif key in (K.DOWN, "j"):
            idx = move_cursor(rows, idx, +1)
        elif key in (K.ENTER, "\r", "\n"):
            row = rows[idx]
            if row["kind"] == "action" and row.get("action") == "random":
                slug = random.choice([r["slug"] for r in rows if r["kind"] == "theme"])
            else:
                slug = row["slug"]
            do_set(slug, theme_map)
            break
    console.clear()


def run_tui(theme_map):
    try:
        from rich.console import Console
        from rich.table import Table
        from rich.panel import Panel
        from rich.text import Text
        from rich.style import Style
        from rich.prompt import Prompt
    except ImportError:
        sys.exit("drmis: rich not found -- rebuild with nrs")

    console = Console()
    themes  = get_all_themes()
    cur     = current_theme()

    def make_swatch(colors):
        t = Text()
        for k in SWATCH_KEYS:
            c = colors.get(k, "")
            if c and c.startswith("#"):
                t.append("  ", style=Style(bgcolor=c))
        return t

    def render_list():
        tbl = Table(show_header=True, header_style="bold", box=None, padding=(0, 1))
        tbl.add_column("#",      style="dim", width=4)
        tbl.add_column("theme",  min_width=22)
        tbl.add_column("family", min_width=14, style="dim")
        tbl.add_column("palette")
        for i, (slug, family, _, _, colors) in enumerate(themes, 1):
            dot  = Text("● ", style="bold green") if slug == cur else Text("  ")
            name = Text()
            name.append_text(dot)
            name.append(slug, style="bold" if slug == cur else "")
            tbl.add_row(str(i), name, family, make_swatch(colors))
        console.print(Panel(tbl, title="[bold]drmis[/bold]",
                            subtitle=f"current: [green]{cur}[/green]"))

    def resolve(token):
        if token and token.isdigit():
            idx = int(token) - 1
            return themes[idx][0] if 0 <= idx < len(themes) else None
        return next((t[0] for t in themes if t[0] == token), None)

    render_list()
    console.print("""
[bold]commands[/bold]
  [cyan]list[/cyan]              all themes with swatches
  [cyan]set[/cyan] <n|name>      switch theme
  [cyan]get[/cyan] [n|name]      inspect palette
  [cyan]edit[/cyan] <n|name>     open palette files in $EDITOR
  [cyan]new[/cyan] <name>        scaffold new theme in Custom/
  [cyan]regen[/cyan] [family]    regenerate derived files for all (or one family's) themes
  [cyan]toggle[/cyan]            cycle theme
  [cyan]q[/cyan]                 quit
""")

    while True:
        try:
            line = Prompt.ask("[bold cyan]drmis[/bold cyan]").strip()
        except (KeyboardInterrupt, EOFError):
            break
        if not line:
            continue
        parts = line.split(None, 1)
        cmd   = parts[0].lower()
        arg   = parts[1] if len(parts) > 1 else None

        if cmd in ("q", "quit", "exit"):
            break
        elif cmd == "list":
            cur = current_theme()
            render_list()
        elif cmd == "set":
            if not arg:
                console.print("[yellow]usage:[/yellow] set <n|name>")
            else:
                slug = resolve(arg)
                if not slug:
                    console.print(f"[red]unknown:[/red] {arg}")
                else:
                    do_set(slug, theme_map)
                    cur = current_theme()
        elif cmd == "get":
            print_palette(resolve(arg) or arg or cur)
        elif cmd == "edit":
            if not arg:
                console.print("[yellow]usage:[/yellow] edit <n|name>")
            else:
                slug = resolve(arg)
                if not slug:
                    console.print(f"[red]unknown:[/red] {arg}")
                else:
                    t = next((x for x in themes if x[0] == slug), None)
                    if t:
                        _, _, td, sh, _ = t
                        editor = os.environ.get("EDITOR", "nano")
                        nix_files = list(td.glob("palette-*.nix"))
                        subprocess.run([editor, str(sh)] + [str(f) for f in nix_files])
        elif cmd == "toggle":
            do_toggle(theme_map)
            cur = current_theme()
        elif cmd == "regen":
            family_arg = [arg] if (arg := (parts[1] if len(parts) > 1 else None)) else []
            do_regen(family_arg)
            themes = get_all_themes()
        elif cmd == "new":
            if not arg:
                console.print("[yellow]usage:[/yellow] new <name>")
            else:
                scaffold_theme(arg, "Custom")
                themes = get_all_themes()
        elif cmd == "help":
            console.print("[bold]commands:[/bold] list · set · get · edit · new · regen · toggle · help · q")
        else:
            console.print(f"[red]unknown:[/red] {cmd} -- type [cyan]help[/cyan]")
