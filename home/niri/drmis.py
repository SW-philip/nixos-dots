import json, os, re, shutil, subprocess, sys, time
from pathlib import Path

THEME_MAP_PATH = "@THEME_MAP_PATH@"
THEMES_ROOT    = Path(os.environ.get("DRMIS_THEMES_ROOT", str(Path.home() / "nixos" / "themes")))
STATE_FILE     = Path.home() / ".local" / "state" / "theme"
APPLIED_FILE   = Path.home() / ".local" / "state" / "theme.applied"
FIREFOX_INI    = Path.home() / ".mozilla" / "firefox" / "profiles.ini"
EMBER_MUG_MAC  = "00:00:00:00:00:01"

def family_flags():
    """Map every theme family on disk to a --<family> scaffold flag, discovered
    from THEMES_ROOT so a new family folder works without editing this file.
    Lowercased keys → case-insensitive matching (--Custom == --custom).
    A family folder name like "Dark" yields the flag "--dark"."""
    if not THEMES_ROOT.exists():
        return {}
    return {f"--{d.name.lower()}": d.name
            for d in sorted(THEMES_ROOT.iterdir()) if d.is_dir()}

def load_theme_map():
    with open(THEME_MAP_PATH) as f:
        return json.load(f)

def parse_palette(sh_path):
    colors = {}
    try:
        with open(sh_path) as f:
            for line in f:
                m = re.match(r'^(?:export\s+)?([A-Z][A-Z0-9_]*)="(#[0-9a-fA-F]{6})"', line.strip())
                if m:
                    colors[m.group(1)] = m.group(2)
    except OSError:
        pass
    return colors

def ember_mug_led_argv(mug_bin, hall_hex):
    """Build argv to sync the mug's LED to a theme's ROOT hex color, or None
    if the sync should be skipped (no mug installed, no ROOT color on this
    theme, or a malformed hex)."""
    if not mug_bin or not hall_hex:
        return None
    if not re.match(r'^#[0-9a-fA-F]{6}$', hall_hex):
        return None
    return [mug_bin, "set", "-m", EMBER_MUG_MAC, "--led-colour", hall_hex.lstrip("#")]

def mug_sync_argv(slug, theme_map, which=shutil.which):
    cfgs = theme_map.get("themes", {}).get(slug)
    if not cfgs:
        return None
    root = parse_palette(theme_file(cfgs, "waybarSh")).get("ROOT")
    return ember_mug_led_argv(which("ember-mug"), root)

def get_all_themes():
    themes = []
    if not THEMES_ROOT.exists():
        return themes
    for fam in sorted(THEMES_ROOT.iterdir()):
        if not fam.is_dir():
            continue
        for td in sorted(fam.iterdir()):
            if not td.is_dir():
                continue
            nix_files = list(td.glob("palette-*.nix"))
            sh_files  = list(td.glob("palette-*.sh"))
            if not nix_files and not sh_files:
                continue
            ref  = nix_files[0] if nix_files else sh_files[0]
            slug = ref.stem.removeprefix("palette-")
            sh   = sh_files[0] if sh_files else ref
            themes.append((slug, fam.name, td, sh, parse_palette(sh)))
    return themes

def ordered_slugs():
    return [t[0] for t in get_all_themes()]

def step_slug(cur, slugs, direction):
    if not slugs:
        return None
    if cur in slugs:
        return slugs[(slugs.index(cur) + direction) % len(slugs)]
    return slugs[0]

def mode_of(cfgs):
    return "light" if cfgs.get("isLight") else "dark"

def mode_slugs(slugs, theme_map, mode):
    themes = theme_map.get("themes", {})
    return [s for s in slugs if s in themes and mode_of(themes[s]) == mode]

def pair_chain(slug, themes):
    """The theme's group, in order: follow PAIR (the next member) until it returns to
    `slug`, runs out, or hits a theme already seen. `slug` itself is not included."""
    chain, seen, cur = [], {slug}, slug
    while True:
        nxt = themes.get(cur, {}).get("pair")
        if not nxt or nxt in seen:
            return chain
        chain.append(nxt)
        seen.add(nxt)
        cur = nxt

def mode_target(slug, want, theme_map):
    """Where `drmis mode <want>` should go from `slug`: (target slug or None, message).
    `toggle` is the next member of the group; light/dark is the first member of that mode."""
    themes = theme_map.get("themes", {})
    cfgs = themes.get(slug)
    if cfgs is None:
        return None, f"drmis: unknown theme '{slug}'"
    if want != "toggle" and want == mode_of(cfgs):
        return None, f"drmis: {slug} is already {want}"
    first = cfgs.get("pair")
    if not first:
        return None, f"drmis: {slug} has no light/dark pair"
    if first not in themes:
        return None, f"drmis: {slug}'s pair '{first}' is not in the theme map (run nrs)"
    chain = [s for s in pair_chain(slug, themes) if s in themes]
    if want == "toggle":
        return chain[0], f"{slug} -> {chain[0]}"
    for member in chain:
        if mode_of(themes[member]) == want:
            return member, f"{slug} -> {member}"
    return None, f"drmis: {slug}'s group has no {want} theme"

def current_theme():
    try:
        return STATE_FILE.read_text().strip()
    except OSError:
        return ""

def deploy_file(src, dest):
    d = Path(dest)
    d.parent.mkdir(parents=True, exist_ok=True)
    d.unlink(missing_ok=True)
    shutil.copy2(src, d)

def deploy_symlink(src, dest):
    d = Path(dest)
    d.parent.mkdir(parents=True, exist_ok=True)
    d.unlink(missing_ok=True)
    d.symlink_to(src)

def deploy_theme_files(files, home):
    for t in files.values():
        dest = Path(home) / t["dest"]
        if t["mode"] == "copy":
            deploy_file(t["src"], dest)
        elif t["mode"] == "link":
            deploy_symlink(t["src"], dest)
        else:
            raise ValueError(f"drmis: unknown deploy mode {t['mode']!r} for {t['dest']}")

def theme_file(cfgs, key):
    return cfgs["files"][key]["src"]

def publish_greeter_palette(content, path="/run/greeter/palette.sh"):
    """Mirror the active palette to a world-readable runtime path for the greeter
    (which runs as the unprivileged `greeter` user). Best-effort: silently no-ops
    if /run/greeter isn't writable, so theme switches never fail on this."""
    try:
        p = Path(path)
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content)
    except OSError:
        pass

def firefox_profiles():
    found = False
    try:
        with open(FIREFOX_INI) as f:
            for line in f:
                line = line.rstrip("\r\n")
                if line.startswith("Path="):
                    found = True
                    yield Path.home() / ".mozilla" / "firefox" / line[5:]
    except OSError:
        pass
    if not found:
        yield Path.home() / ".mozilla" / "firefox" / "default"

def resolve_wallpaper(slug, live_dir, fallback):
    p = Path(live_dir) / f"wallpaper-{slug}.png"
    return str(p) if p.exists() else fallback

def cache_wallpaper(src, state_dir):
    """Copy the wallpaper out of the NFS-backed flake tree: swaybg, hyprlock and
    greeter-wallpaper-seed read it at boot, before (or without) desktop."""
    dest = state_dir / "wallpaper-cache.png"
    tmp = dest.with_suffix(".tmp")
    try:
        shutil.copyfile(src, tmp)
        os.replace(tmp, dest)
    except OSError:
        tmp.unlink(missing_ok=True)
        return str(dest) if dest.exists() else src
    return str(dest)

def resolve_theme_alias(slug):
    return {"dark": "main", "light": "dawn"}.get(slug, slug)

def do_let(slug, theme_map):
    slug = resolve_theme_alias(slug)
    themes = theme_map.get("themes", {})
    if slug not in themes:
        print(f"drmis: unknown theme '{slug}'", file=sys.stderr); sys.exit(1)
    cfgs = themes[slug]
    home = Path.home()
    deploy_theme_files(cfgs["files"], home)
    state_dir = home / ".local/state"
    state_dir.mkdir(parents=True, exist_ok=True)
    live = Path(cfgs["wallpaperLiveDir"])
    wallpaper = cache_wallpaper(resolve_wallpaper(slug, live, cfgs["wallpaperFallback"]), state_dir)
    (state_dir / "wallpaper").write_text(wallpaper)
    deploy_symlink(wallpaper, state_dir / "wallpaper-img")
    for profile_dir in firefox_profiles():
        chrome = profile_dir / "chrome"
        chrome.mkdir(parents=True, exist_ok=True)
        deploy_file(cfgs["firefoxCss"],    chrome / "userChrome.css")
        deploy_file(cfgs["userContentCss"], chrome / "userContent.css")
    zed_settings_path = home / ".config/zed/settings.json"
    try:
        with open(zed_settings_path) as f:
            zed_settings = json.load(f)
    except (OSError, json.JSONDecodeError):
        zed_settings = {}
    appearance = "light" if cfgs.get("isLight") else "dark"
    zed_settings["theme"] = {"mode": appearance, "light": slug, "dark": slug}
    zed_settings_path.parent.mkdir(parents=True, exist_ok=True)
    with open(zed_settings_path, "w") as f:
        json.dump(zed_settings, f, indent=2)
    try:
        Path("/run/tuigreet-theme").write_text(cfgs["tuigreetTheme"])
    except OSError:
        pass
    try:
        publish_greeter_palette(Path(theme_file(cfgs, "waybarSh")).read_text())
    except OSError:
        pass
    print(f"drmis let: applied {slug}")

def do_set(slug, theme_map):
    slug = resolve_theme_alias(slug)
    themes = theme_map.get("themes", {})
    if slug not in themes:
        print(f"drmis: unknown theme '{slug}'", file=sys.stderr); sys.exit(1)
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(slug)
    do_let(slug, theme_map)
    subprocess.run(["systemctl", "--user", "restart", "swaybg"],  stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-USR1", "zsh"],                      stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-SIGUSR1", "waybar"],                stderr=subprocess.DEVNULL)
    subprocess.run(["swaync-client", "-R"],                        stderr=subprocess.DEVNULL)
    subprocess.run(["swaync-client", "-rs"],                       stderr=subprocess.DEVNULL)
    subprocess.run(["systemctl", "--user", "try-restart", "squeekboard.service"], stderr=subprocess.DEVNULL)
    subprocess.run(["eww", "reload"],                              stderr=subprocess.DEVNULL)
    time.sleep(0.3)
    subprocess.run(["pkill", "-f", "waybar-weather"],              stderr=subprocess.DEVNULL)
    subprocess.run(["pkill", "-SIGUSR2", "ghostty"],               stderr=subprocess.DEVNULL)
    subprocess.run(["tmux", "source-file", str(Path.home() / ".config/tmux/theme.conf")], stderr=subprocess.DEVNULL)
    # SIGUSR2 reload leaks ~5 zombie children of waybar per call; a restart reaps them all
    subprocess.run(["systemctl", "--user", "restart", "waybar"],   stderr=subprocess.DEVNULL)
    try:
        subprocess.run(["niri", "msg", "action", "load-config-file"], stderr=subprocess.DEVNULL)
    except FileNotFoundError:
        pass
    APPLIED_FILE.write_text(slug)
    print(f"✅ Theme set to: {slug}")

def do_mode(arg, theme_map):
    if arg not in ("light", "dark", "toggle"):
        print("usage: drmis mode light|dark|toggle", file=sys.stderr)
        return 2
    target, msg = mode_target(current_theme(), arg, theme_map)
    if target is None:
        already = "already" in msg
        print(msg, file=sys.stdout if already else sys.stderr)
        return 0 if already else 1
    do_set(target, theme_map)
    return 0

def do_step(direction, theme_map):
    cur = current_theme()
    here = mode_of(theme_map.get("themes", {}).get(cur, {}))
    slugs = mode_slugs(ordered_slugs(), theme_map, here)
    nxt = step_slug(cur, slugs, direction)
    if nxt is None:
        print("drmis: no themes found", file=sys.stderr); sys.exit(1)
    do_set(nxt, theme_map)
    subprocess.run(["notify-send", "-u", "low", "Theme", nxt], stderr=subprocess.DEVNULL)

def do_next(theme_map):
    do_step(1, theme_map)

def do_prev(theme_map):
    do_step(-1, theme_map)

def do_toggle(theme_map):
    do_next(theme_map)








def do_list(args=None):
    args   = args or []
    themes = get_all_themes()
    cur    = current_theme()
    if "--json" in args:
        print(json.dumps([
            {"slug": slug, "family": family, "current": slug == cur}
            for slug, family, _, _, _ in themes
        ]))
        return
    for slug, family, _, _, _ in themes:
        marker = " ●" if slug == cur else ""
        print(f"  {slug:<24} {family}{marker}")

def print_help():
    families = ", ".join(sorted(family_flags().values())) or "(none found)"
    print(f"""drmis  dynamic runtime manager for interface styling

usage:
  drmis                       open interactive TUI
  drmis --list | list         list all themes
  drmis --help                this help

  drmis set <theme>           switch theme (save + apply + restart services)
  drmis let [<theme>]         apply configs only (no state save, no restart)
  drmis toggle                alias for next
  drmis next                  step to the next theme in this mode (list order, wraps)
  drmis prev                  step to the previous theme in this mode (list order, wraps)
  drmis mode light|dark|toggle  switch to this theme's light/dark pair
  drmis pick                  interactive grouped theme menu
  drmis get [<theme>]              inspect palette  (default: current)
  drmis get --<family> <name>      scaffold via keyword/API search into themes/<family>/
                                   (any folder under themes/, e.g. --dark, --light)
  drmis get --rose-pine <variant>  scaffold Rose Pine variant (main/moon/dawn) from official site into Dark/
  drmis get --new <n> [--family F] scaffold in any family
  drmis get --compare <query>      compare query across palette sources
  drmis get --sources              list available palette sources

  drmis regen                      regenerate derived files for all themes (preserves palette.sh)
  drmis regen <family>             limit to one family: {families}
  drmis regen --force              also re-derive palette files from seed colors
  drmis regen --wallpapers-only    only (re)generate wallpapers for all themes
  drmis regen --no-wallpapers      regenerate derived files but skip wallpapers
""")













def main():
    args = sys.argv[1:]
    if not args:
        from drmis_tui import run_tui
        run_tui(load_theme_map())
        return
    if "--help" in args or "-h" in args:
        print_help(); return
    if "--list" in args:
        do_list(args); return
    cmd  = args[0]
    rest = args[1:]
    if cmd == "set":
        if not rest:
            print("drmis set: theme required", file=sys.stderr); sys.exit(1)
        do_set(rest[0], load_theme_map())
    elif cmd == "let":
        do_let(rest[0] if rest else current_theme(), load_theme_map())
    elif cmd == "toggle":
        do_toggle(load_theme_map())
    elif cmd == "next":
        do_next(load_theme_map())
    elif cmd == "prev":
        do_prev(load_theme_map())
    elif cmd == "mode":
        sys.exit(do_mode(rest[0] if rest else "", load_theme_map()))
    elif cmd == "pick":
        from drmis_tui import run_pick
        run_pick(load_theme_map())
    elif cmd == "get":
        from drmis_tui import do_get
        do_get(rest)
    elif cmd == "regen":
        from drmis_tui import do_regen
        do_regen(rest)
    elif cmd == "list":
        do_list(rest)
    elif cmd == "mug-sync":
        argv = mug_sync_argv(current_theme(), load_theme_map())
        if argv:
            sys.exit(subprocess.run(argv).returncode)
    else:
        print(f"drmis: unknown command '{cmd}' -- try drmis --help", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()
