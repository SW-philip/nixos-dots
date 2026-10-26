# Pegasus collection for the Windows games in /srv/roms/pc, run through the
# system wine (gpu-nvidia.nix) in the default ~/.wine prefix. Not a
# retro-systems.nix entry: every game dir holds several .exe files (steam-emu
# loaders, crash handlers, _Redist installers), so an `extensions` scan would
# list junk. Each game names its real entry point here instead, which means a
# rebuild per added game. `scrape -r pc` searches by these filenames, so each
# entry exe is renamed after its game (a Unity exe's <name>_Data dir and a
# SmartSteamLoader's <name>.cfg get renamed with it). FitGirl repacks only
# show up once installed.
# workdir matters: the SmartSteamLoader/ColdClientLoader launchers resolve
# their .cfg/.ini and the game exe relative to the current directory.
{ pkgs }:
let
  games = [
    { title = "Bluey: The Videogame";      file = "Bluey: The Videogame/Bluey.The.Videogame/Biscuits/Bluey The Videogame.exe"; }
    { title = "Hook";                      file = "Hole/Hook.exe"; }
    { title = "Hook 2";                    file = "Hole2/Hook 2.exe"; }
    { title = "The Jackbox Naughty Pack";  file = "The Jackbox Naughty Pack/The Jackbox Naughty Pack.exe"; }
    { title = "The Jackbox Party Pack 10"; file = "The Jackbox Party Pack 10/The Jackbox Party Pack 10.exe"; }
    { title = "The Jackbox Party Pack 11"; file = "The Jackbox Party Pack 11/The Jackbox Party Pack 11.exe"; }
  ];
in
pkgs.writeText "pegasus-metadata-pc" (''
  collection: PC
  shortname: pc
  files:
'' + pkgs.lib.concatMapStrings (g: "    ${g.file}\n") games + ''
  launch: ${pkgs.wineWow64Packages.stable}/bin/wine "{file.path}"
  workdir: {file.dir}

'' + pkgs.lib.concatMapStrings (g: ''
  game: ${g.title}
  file: ${g.file}

'') games)
