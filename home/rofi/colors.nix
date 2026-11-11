# Rofi color variables — regenerated per-theme by drmis, deployed to
# ~/.config/rofi/colors.rasi and imported by the static config.rasi.
# The old app-launch "Open on" picker look: ROOT accent as border + selection, HALL text on it.
{ p, lib }:
let
  c  = hex: (lib.removePrefix "#" hex) + "ff";        # opaque
  ca = hex: a: (lib.removePrefix "#" hex) + a;        # explicit alpha byte
in
''
  * {
      bg:    #${ca p.HALL "f2"};
      fg:    #${c p.SCORE};
      match: #${c p.ROOT};
      sel:   #${c p.ROOT};
      selfg: #${c p.HALL};
      bd:    #${c p.ROOT};
  }

  /* highlight only takes a literal color, not a @reference */
  element-text {
      highlight: bold #${c p.ROOT};
  }
  element-text selected.normal {
      highlight: bold #${c p.HALL};
  }
''
