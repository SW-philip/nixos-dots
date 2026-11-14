{ pkgs, ... }:
{
  # The emulator/game-library setup itself lives in home/emulation. This
  # file is prepko's delta on top of it: scraper tooling, and (see below)
  # the desktop-only Pegasus theme.
  imports = [ ../emulation ./controller-home.nix ];

  home.packages = [ pkgs.skyscraper ];

  # Desktop-only theme, distinct from surface/kid's "homage" (a retro
  # NES-manual look, home/emulation-light) -- gameOS is a modern
  # dashboard/grid style built for a full library on a big screen.
  # gameOS looks up logospng/<collection shortname>.png; ./logos fills in
  # the collections it doesn't ship (gcwii, cloud). PNGs are rendered from
  # the .svg sources beside them with rsvg-convert + magick -trim.
  xdg.configFile."pegasus-frontend/themes/gameOS".source =
    let
      upstream = pkgs.fetchFromGitHub {
        owner = "PlayingKarrde";
        repo = "gameOS";
        rev = "7a5a5223ff7371d0747a7c5d3a3b8f2f5e36b4f2";
        hash = "sha256-EBpIe0aw1FO7DzB6F3oAWD5FRLF2iZGtOHllMxuamdc=";
      };
    in
    pkgs.runCommand "gameOS-with-logos" { } ''
      cp -r ${upstream} $out
      chmod -R u+w $out
      cp ${./logos}/*.png $out/assets/images/logospng/
    '';

  # Pegasus rewrites settings.txt on exit; force = true clobbers it back on
  # every rebuild. Value must include the "themes/" prefix or Pegasus falls
  # back to default even though the theme is found.
  xdg.configFile."pegasus-frontend/settings.txt" = {
    force = true;
    text = ''
      general.theme: themes/gameOS
    '';
  };
}
