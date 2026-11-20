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
  cursor-style = block
  cursor-style-blink = true
  shell-integration-features = no-cursor

  selection-background = ${p.MUTE}
  selection-foreground = ${p.SCORE}

  font-family = JetBrainsMono Nerd Font
  font-family = Symbols Nerd Font Mono

  window-padding-x = 14
  window-padding-y = 10
  window-decoration = false

  # Each window is its own session grouped into "main" (shared windows, independent current
  # window); the group session dies with its terminal, "main" itself survives detached.
  # A second window opens on a fresh tmux window so it doesn't land on the one already shown.
  command = shell:tmux new-session -d -s main 2>/dev/null; if [ -n "$(tmux list-clients 2>/dev/null)" ]; then exec tmux new-session -t main \; set destroy-unattached on \; new-window; else exec tmux new-session -t main \; set destroy-unattached on; fi

  split-divider-color = ${p.WING}

  gtk-custom-css = ?ghostty.css

  # io_uring's idle waits count as iowait, so every open window showed up as
  # phantom disk pressure in vmstat/PSI. Benchmarks show no difference.
  async-backend = epoll
''
