# Fastfetch logo — nix-flake mark recoloured per-theme and rasterised to PNG by rsvg-convert.
{ t, pkgs, lib }:
let
  p            = t.palette;
  nixBlue      = p.ROOT  or "#5277c3";
  nixCyan      = p.FIFTH or "#7ebae4";
  hasOverrides = builtins.pathExists "${t.dir}/wallpaper-colors.sh";
in pkgs.runCommand "fastfetch-logo-${t.slug}.png" {
  nativeBuildInputs = [ pkgs.librsvg ];
} ''
  cp ${../../assets/nix/nix-flake.svg} mark.svg

  NIX_BLUE="${nixBlue}"
  NIX_CYAN="${nixCyan}"

  ${lib.optionalString hasOverrides "source ${t.dir}/wallpaper-colors.sh"}

  sed -i \
    "s|#5277C3|''${NIX_BLUE}|g; \
     s|#7EBAE4|''${NIX_CYAN}|g" \
    mark.svg

  rsvg-convert -w 280 mark.svg -o $out
''
