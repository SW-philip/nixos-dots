# Fuzzel color overrides — regenerated per-theme by drmis, deployed to
# ~/.config/fuzzel/fuzzel-colors.ini and pulled into the static fuzzel.ini
# via `include=`. No hardcoded hex. Flat vocabulary: neutral `thread`
# border, calm STAGE selection.
{ p, lib }:
let
  c  = hex: (lib.removePrefix "#" hex) + "ff";        # opaque
  ca = hex: a: (lib.removePrefix "#" hex) + a;        # explicit alpha byte
in
''
  [colors]
  background=${ca p.HALL "cc"}
  text=${c p.SCORE}
  match=${c p.ROOT}
  selection=${c p.STAGE}
  selection-text=${c p.SCORE}
  selection-match=${c p.ROOT}
  border=${ca p.SCORE "8c"}
''
