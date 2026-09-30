{ pkgs, ... }:
{
  programs.tmux = {
    enable        = true;
    prefix        = "C-a";
    keyMode       = "emacs";
    mouse         = true;
    baseIndex     = 1;
    escapeTime    = 10;
    historyLimit  = 50000;
    terminal      = "tmux-256color";
    focusEvents   = true;

    # resurrect must load before continuum (continuum depends on it).
    plugins = with pkgs.tmuxPlugins; [
      resurrect
      {
        plugin = continuum;
        extraConfig = ''
          set -g @continuum-restore 'on'
          set -g @continuum-save-interval '15'
        '';
      }
    ];

    extraConfig = ''
      # Truecolor for Ghostty
      set -ga terminal-overrides ",*256col*:Tc"
      set -ga terminal-features ",*:RGB"

      # Double-tap prefix sends a literal C-a to the shell (beginning-of-line).
      bind C-a send-prefix

      set -g renumber-windows on

      # Splits inherit the current pane's cwd
      unbind '"'
      unbind %
      bind | split-window -h -c "#{pane_current_path}"
      bind - split-window -v -c "#{pane_current_path}"

      # Reload config
      bind r source-file ~/.config/tmux/tmux.conf \; display "tmux config reloaded"

      # Repeatable pane resize
      bind -r H resize-pane -L 5
      bind -r J resize-pane -D 5
      bind -r K resize-pane -U 5
      bind -r L resize-pane -R 5

      # Pane navigation without prefix (Alt+arrows; no vim, avoids C-hjkl conflicts)
      bind -n M-Left  select-pane -L
      bind -n M-Down  select-pane -D
      bind -n M-Up    select-pane -U
      bind -n M-Right select-pane -R

      # System clipboard: every copy-mode copy (mouse drag-release, Enter, M-w)
      # also pipes the selection to wl-copy, on top of tmux's own paste buffer.
      set -g copy-command 'wl-copy'

      # Pull the system clipboard into tmux and paste it immediately, so
      # content copied outside tmux (Ghostty, browser) round-trips in.
      # Default ']' paste (tmux's own buffer) is untouched.
      bind P run-shell "wl-paste | tmux load-buffer -" \; paste-buffer

      # Fuzzy session switcher: popup + fzf over the live session list.
      bind f display-popup -E "tmux list-sessions -F '##S' | fzf --reverse | xargs -r tmux switch-client -t"

      # Live theme: status colors come from the drmis-deployed file, re-sourced
      # on every `drmis set`. The if-shell guard makes a missing file harmless
      # (e.g. before the first `drmis let`).
      if-shell "test -f ~/.config/tmux/theme.conf" "source-file ~/.config/tmux/theme.conf"
    '';
  };
}
