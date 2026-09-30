# Fuzzel launcher static config — palette-independent, home-manager-managed
# symlink (see xdg.configFile."fuzzel/fuzzel.ini" in home/niri/default.nix).
# Colors live in fuzzel-colors.ini, regenerated per-theme by drmis and pulled
# in via `include=` so theme switches never touch this file. The drun
# placeholder line is picked per launch by the `launcher` script
# (assets/launcher-lines.txt), not set here.
{ l }:
''
  [main]
  font=JetBrainsMono Nerd Font:size=13
  prompt="󰀻  "
  dpi-aware=auto
  terminal=ghostty -e
  layer=overlay
  show-actions=no
  match-mode=fuzzy
  width=38
  lines=8
  horizontal-pad=28
  vertical-pad=20
  inner-pad=14
  line-height=26
  image-size-ratio=0.55
  letter-spacing=0.4
  include=~/.config/fuzzel/fuzzel-colors.ini

  [border]
  width=2
  radius=${toString l.radiusLg}
''
