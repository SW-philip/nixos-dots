{ pkgs, ... }:
let
  # Desktop-only themes, distinct from surface/kid's "homage" (a retro
  # NES-manual look, home/emulation-light) -- gameOS is a modern
  # dashboard/grid style built for a full library on a big screen.
  # gameOS looks up logospng/<collection shortname>.png; ./logos fills in
  # the collections it doesn't ship (gcwii, cloud). PNGs are rendered from
  # the .svg sources beside them with rsvg-convert + magick -trim.
  gameOS =
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
in
{
  # The emulator/game-library setup itself lives in home/emulation. This
  # file is prepko's delta on top of it: scraper tooling, and (see below)
  # the desktop-only Pegasus theme.
  imports = [ ../emulation ./controller-home.nix ];

  home.packages = [ pkgs.skyscraper ];

  xdg.configFile."pegasus-frontend/themes/gameOS".source = gameOS;

  # The active theme. gameOS above stays installed because retro-tiles
  # renders retro's Moonlight tiles from its logospng/. COLORFUL resolves
  # every logo/device/video/colour through CollectionData.qml's aliases
  # map, so our non-standard shortnames just get aliased onto its own;
  # ps3, wiiu, xbox and cloud have no upstream entry, so they're added.
  xdg.configFile."pegasus-frontend/themes/colorful".source =
    let
      upstream = pkgs.fetchFromGitHub {
        owner = "RobZombie9043";
        repo = "COLORFUL";
        rev = "5afca291bbf82cb63cc07bd1d8ad052d547c8903";
        hash = "sha256-M4SOCDoSlGwIEI1Wy+1GNgv2r9mHs9xKxfoc2j3M1Yo=";
      };
    in
    pkgs.runCommand "colorful-aliased" { nativeBuildInputs = [ pkgs.imagemagick ]; } ''
      cp -r ${upstream} $out
      chmod -R u+w $out
      substituteInPlace $out/components/CollectionData.qml \
        --replace-fail "property var aliases: {" \
                       "property var aliases: { 'n3ds': '3ds', 'gcwii': 'wii'," \
        --replace-fail "property var metadata: {" \
                       "property var metadata: {
      $(cat ${./colorful-metadata.js})"

      # Logos are white wordmarks cropped to 1920px wide, recoloured per
      # variant (Color = the collection's metadata colour). Upstream's
      # device art is photographic console renders we can't match, so the
      # white wordmark stands in, centred on the same 2160px canvas.
      img=$out/assets/images
      while read -r name src; do
        color=$(grep -oP "'$name': \\{ color: '\\K#[0-9a-f]+" ${./colorful-metadata.js})
        logo=$TMPDIR/$name.png
        magick "$src" -alpha set -trim +repage -resize 1920x $logo
        tint() { magick $logo -fill "$1" -colorize 100 "$img/logos/$2/$name.png"; }
        tint black "Dark - Black"
        tint white "Light - White"
        tint "$color" "Dark - Color"
        tint "$color" "Light - Color"
        magick -size 2160x2160 xc:none \( $logo -fill white -colorize 100 -resize 1500x900 \) \
          -gravity center -composite $img/devices/$name.png
      done <<EOF
      ps3 ${gameOS}/assets/images/logospng/ps3.png
      wiiu ${gameOS}/assets/images/logospng/wiiu.png
      xbox ${gameOS}/assets/images/logospng/xbox.png
      cloud ${./logos/cloud.png}
      EOF
    '';

  # Pegasus rewrites settings.txt on exit; force = true clobbers it back on
  # every rebuild. Value must include the "themes/" prefix or Pegasus falls
  # back to default even though the theme is found.
  xdg.configFile."pegasus-frontend/settings.txt" = {
    force = true;
    text = ''
      general.theme: themes/colorful
    '';
  };
}
