# Rosé Pine status bar for tmux. Generated from a palette-*.nix and deployed at
# runtime by drmis to ~/.config/tmux/theme.conf (re-sourced on theme switch).
# Mirrors the home/waybar/style.nix { p } pattern. No hardcoded hex.
{ p }:
''
# ── Status bar ───────────────────────────────────────────────
set -g status on
set -g status-interval 5
set -g status-justify left
set -g status-style "bg=${p.STAGE},fg=${p.SCORE}"

set -g status-left-length 32
set -g status-left "#[fg=${p.HALL},bg=${p.ROOT},bold] #S #[fg=${p.ROOT},bg=${p.STAGE},nobold] "

# status-right: prefix-pending + copy-mode pills (native #{?...} format, so they
# live-switch with the palette), then date / time / host. Commas inside the
# conditional style blocks are escaped as #, per tmux format syntax.
set -g status-right-length 80
set -g status-right "#{?client_prefix,#[fg=${p.HALL}#,bg=${p.FORTE}#,bold] PREFIX #[default],}#{?pane_in_mode,#[fg=${p.HALL}#,bg=${p.PIANO}#,bold] COPY #[default],}#[fg=${p.REST}] %Y-%m-%d #[fg=${p.FIFTH}]%H:%M #[fg=${p.HALL},bg=${p.ROOT},bold] #h "

setw -g window-status-separator ""
setw -g window-status-format "#[fg=${p.BAR},bg=${p.STAGE}] #I:#W "
setw -g window-status-current-format "#[fg=${p.HALL},bg=${p.FIFTH},bold] #I:#W "

# ── Panes / messages / copy-mode ─────────────────────────────
set -g pane-border-style "fg=${p.WING}"
set -g pane-active-border-style "fg=${p.ROOT}"
set -g message-style "bg=${p.WING},fg=${p.SCORE}"
set -g message-command-style "bg=${p.WING},fg=${p.SCORE}"
set -g mode-style "bg=${p.WING},fg=${p.SCORE}"
''
