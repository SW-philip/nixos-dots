# Ghostty terminal colour/font config. Generated from a palette and deployed by
# drmis to ~/.config/ghostty/config (alongside ghostty.css). No hardcoded hex.
{ p }:
''
  palette = 0=${p.WING}
  palette = 1=${p.FORTE}
  palette = 2=${p.SEVENTH}
  palette = 3=${p.PIANO}
  palette = 4=${p.FIFTH}
  palette = 5=${p.ROOT}
  palette = 6=${p.SOTTO}
  palette = 7=${p.SCORE}
  palette = 8=${p.MUTE}
  palette = 9=${p.FORTE}
  palette = 10=${p.SEVENTH}
  palette = 11=${p.PIANO}
  palette = 12=${p.FIFTH}
  palette = 13=${p.ROOT}
  palette = 14=${p.SOTTO}
  palette = 15=${p.SCORE}

  background = ${p.HALL}
  foreground = ${p.SCORE}
  background-opacity = 0.80

  cursor-color = ${p.ROOT}
  cursor-text = ${p.HALL}

  selection-background = ${p.MUTE}
  selection-foreground = ${p.SCORE}

  font-family = JetBrainsMono Nerd Font
  font-family = Symbols Nerd Font Mono

  window-padding-x = 14
  window-padding-y = 10
  window-decoration = false

  split-divider-color = ${p.WING}

  gtk-custom-css = ?ghostty.css
''
