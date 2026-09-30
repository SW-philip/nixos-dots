# nix-flake mark — recoloured to a flat REST silhouette per-theme and
# rasterised to PNG by rsvg-convert. Shared by the lock screen (hyprlock)
# and the logout popup (lix-logout); the greeter recolours the same source
# SVG itself (different user, no ~/.local/state at boot). Mirrors
# home/fastfetch/logo.nix, minus its two-tone accent treatment.
{ t, pkgs, lib }:
let
  rest = t.palette.REST;
in pkgs.runCommand "nix-mark-${t.slug}.png" {
  nativeBuildInputs = [ pkgs.librsvg ];
} ''
  cp ${../../assets/nix/nix-flake.svg} mark.svg
  grep -q '#7EBAE4' mark.svg || { echo "nix-flake.svg fills changed — update mark.nix + pkgs/greeter/greeter/mark.py" >&2; exit 1; }
  sed -i 's|#7EBAE4|${rest}|g; s|#5277C3|${rest}|g' mark.svg
  sed -i 's|stroke="#000000"|stroke="none"|g' mark.svg
  rsvg-convert -w 128 mark.svg -o $out   # native viewBox width; both consumers downscale
''
