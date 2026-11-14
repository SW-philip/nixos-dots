# Pegasus collection for streamed games, as tmpfiles rules for /srv/roms/cloud.
# Pegasus drops a game with no file ("has no valid games, ignored"), so each
# entry is a real <name>.gfn file holding its GFN deep link (empty = the store
# page). Real files, not store symlinks: Skyscraper resolves links and rejects
# anything outside its input dir. The window lands fullscreen via the GFN rule
# in home/niri/config.kdl.nix.
{ pkgs }:
let
  inherit (pkgs) lib;
  games = [
    { name = "GeForce NOW"; url = ""; }
    # streamer URLs skip the game page and start the session; cmsId/shortName
    # come from the GFN profile's History after launching the game once
    { name = "Apex Legends";
      url = "https://play.geforcenow.com/mall/#/streamer?launchSource=GeForceNOW&cmsId=102007911&shortName=apex_legends_ea_app&appLaunchMode=Default"; }
  ];
  open = pkgs.writeShellScript "gfn-open" ''
    url=$(< "$1")
    [ -n "$url" ] && export GFN_URL="$url"
    exec ${lib.getExe pkgs.geforce-now}
  '';
  file = g: "${g.name}.gfn";
  # Header only, like pegasus-pc.nix: a `game:` block here would own the file
  # and make Pegasus reject the sidecar entries (skyscraper.metadata.pegasus.txt
  # for scraped games, overrides.metadata.pegasus.txt for GeForce NOW itself) that
  # carry the details and art.
  metadata = pkgs.writeText "pegasus-metadata-cloud" ''
    collection: Cloud
    shortname: cloud
    extensions: gfn
    launch: ${open} "{file.path}"
  '';
  # tmpfiles paths can't hold raw spaces, and % starts a specifier in either field
  esc = lib.replaceStrings [ " " ] [ "\\x20" ];
in
assert lib.all (g: !lib.hasInfix "%" g.url) games;
[ "L+ /srv/roms/cloud/metadata.pegasus.txt - - - - ${metadata}" ]
++ map (g: "f+ ${esc "/srv/roms/cloud/${file g}"} 0644 prepko users - ${g.url}") games
