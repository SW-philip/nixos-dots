# Pegasus collection for the Windows games in /srv/roms/pc, run through the
# desktop wine (profiles/prepko/desktop.nix) in the default ~/.wine prefix. Not a
# retro-systems.nix entry: every game dir holds several .exe files (steam-emu
# loaders, crash handlers, _Redist installers), so an `extensions` scan would
# list junk. Each game names its real entry point here instead, which means a
# rebuild per added game. `scrape -r pc` searches by these filenames, so each
# entry exe is renamed after its game (a Unity exe's <name>_Data dir and a
# SmartSteamLoader's <name>.cfg get renamed with it). FitGirl repacks only
# show up once installed.
# workdir matters: the SmartSteamLoader/ColdClientLoader launchers resolve
# their .cfg/.ini and the game exe relative to the current directory.
# The scope caps exist because one of these took the desktop down on 2026-11-05:
# ~20k tiny processes and 45 GB of RAM + swap in 17 minutes, no window. MemoryMax
# alone wouldn't help, since a capped cgroup just pushes the rest into swap.
# Header only, like the retro collections: a `game:` block here would own the file
# and make Pegasus reject the entry skyscraper.metadata.pegasus.txt has for it,
# taking the art with it.
{ pkgs }:
let
  games = [
    "Bluey: The Videogame/Bluey.The.Videogame/Biscuits/Bluey The Videogame.exe"
    "Hole/Hook.exe"
    "Hole2/Hook 2.exe"
    "The Jackbox Naughty Pack/The Jackbox Naughty Pack.exe"
    "The Jackbox Party Pack 10/The Jackbox Party Pack 10.exe"
    "The Jackbox Party Pack 11/The Jackbox Party Pack 11.exe"
  ];
in
pkgs.writeText "pegasus-metadata-pc" (''
  collection: PC
  shortname: pc
  files:
'' + pkgs.lib.concatMapStrings (file: "    ${file}\n") games + ''
  launch: ${pkgs.systemd}/bin/systemd-run --user --scope --collect --quiet -p TasksMax=256 -p MemoryMax=12G -p MemorySwapMax=4G ${pkgs.wineWow64Packages.stable}/bin/wine "{file.path}"
  workdir: {file.dir}
'')
