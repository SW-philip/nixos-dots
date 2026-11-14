{ pkgs, lib, ... }:
let
  # nix-your-shell's zsh hook is static; generate it at build time instead of
  # forking the binary on every shell start.
  nixYourShellInit = pkgs.runCommand "nix-your-shell-zsh" { } ''
    ${pkgs.nix-your-shell}/bin/nix-your-shell zsh > $out
  '';
in
{
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 10000;
      save = 10000;
      extended = true;
      ignoreDups = true;
      ignoreAllDups = true;
      expireDuplicatesFirst = true;
      share = true;
    };

    shellAliases = {
      ls = "eza --icons=auto --group-directories-first";
      ll = "eza -lh --icons=auto --group-directories-first --git";
      la = "eza -lah --icons=auto --group-directories-first --git";
      lt = "eza --tree --icons=auto --level=2";
      ltt = "eza --tree --icons=auto";
      cat = "bat --style=plain --paging=never";
      lg = "lazygit";
      gds = "git diff --staged";
      nfu = "nix flake update";
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      g = "git";
      gst = "git status";
      ga = "git add";
      gaa = "git add --all";
      gc = "git commit";
      gcmsg = "git commit -m";
      gco = "git checkout";
      gb = "git branch";
      gf = "git fetch";
      gp = "git push";
      gl = "git pull";
      gd = "git diff";
      gfa = "git fetch --all --prune";
      gm = "git merge";
      gr = "git remote";
      grm = "git rm";
      grb = "git rebase";
      grba = "git rebase --abort";
      grbc = "git rebase --continue";
      grbi = "git rebase -i";
      gsw = "git switch";
      gss = "git status -s";
      gsta = "git stash push";
      gstp = "git stash pop";
      gcm = "git checkout main";
      gpf = "git push --force-with-lease";
      x = "ouch decompress";
      extract = "ouch decompress";
      grep = "grep --color=auto";
      ip = "ip --color=auto";
      diff = "delta";
    };

    # compaudit stats every dir in $fpath on every startup (Nix profiles inflate
    # $fpath heavily); that alone was ~40% of shell startup time (measured via
    # zprof). Skip it, and the dump rebuild, unless the dump is over a day old.
    # The touch matters: a full compinit finding a valid dump leaves its mtime
    # alone, so without it every shell after day one takes the slow path again.
    completionInit = ''
      autoload -Uz compinit
      _zcd=(''${HOME}/.zcompdump(N.mh-24))
      if (( ''${#_zcd} )); then compinit -C; else compinit; touch ''${HOME}/.zcompdump; fi
      unset _zcd
    '';

    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
    ];

    # p10k instant prompt only works if this is the first thing .zshrc does —
    # sourced after the plugins it just writes a cache file nothing reads.
    initContent = lib.mkMerge [
      (lib.mkOrder 0 ''
        if [[ -r "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh" ]]; then
          source "''${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-''${(%):-%n}.zsh"
        fi
      '')
      (lib.mkAfter ''
      # 1. Color Refresh Function
      _refresh_colors() {
        # Path where toggle-theme copies the palette
        PALETTE_FILE="$HOME/.config/waybar/palette.sh"

        if [ -f "$PALETTE_FILE" ]; then
          source "$PALETTE_FILE"

          export BASE SURFACE OVERLAY MUTED SUBTLE TEXT LOVE GOLD ROSE PINE FOAM IRIS \
                 HIGHLIGHT_LOW HIGHLIGHT_MED HIGHLIGHT_HIGH

          export FZF_DEFAULT_OPTS="
            --height=50% --layout=reverse --border=rounded
            --info=inline --cycle
            --bind=ctrl-u:preview-page-up,ctrl-d:preview-page-down
            --bind=ctrl-/:toggle-preview
            --color=bg:''${BASE},bg+:''${HIGHLIGHT_LOW},fg:''${TEXT},fg+:''${TEXT}
            --color=hl:''${LOVE},hl+:''${LOVE},info:''${FOAM},prompt:''${IRIS}
            --color=pointer:''${LOVE},marker:''${GOLD},spinner:''${FOAM},header:''${MUTED}
            --color=border:''${HIGHLIGHT_MED},gutter:''${BASE}
          "

          if [[ -v ZSH_HIGHLIGHT_STYLES ]]; then
            ZSH_HIGHLIGHT_STYLES[comment]="fg=''${MUTED:-#6e6a86}"
          fi
        fi
      }

      _refresh_colors

      TRAPUSR1() {
        _refresh_colors
        # Force prompt redraw so colors update without pressing Enter
        zle && zle reset-prompt
      }

      [[ -f ~/.p10k.zsh ]] && source ~/.p10k.zsh
      [ -f "$HOME/.config/sqlch/env" ] && source "$HOME/.config/sqlch/env"

      source ${nixYourShellInit}

      zstyle ':completion:*' menu select
      zstyle ':completion:*' matcher-list 'm:{a-z}={A-Za-z}'
      zstyle ':completion:*:descriptions' format '%F{yellow}-- %d --%f'
      zstyle ':completion:*:warnings' format '%F{red}no matches%f'
      zstyle ':completion:*' group-name ""
      zstyle ':completion:*' list-colors "''${(s.:.)LS_COLORS}"

      bindkey "^[[1;5C" forward-word
      bindkey "^[[1;5D" backward-word
      bindkey "^[[H"    beginning-of-line
      bindkey "^[[F"    end-of-line
      bindkey "^[[3~"   delete-char
      bindkey "^H"      backward-kill-word
      bindkey "^[[3;5~" kill-word

      # esc-esc: prepend sudo to the line (or the previous command if empty)
      _sudo_prepend() {
        [[ -z $BUFFER ]] && zle up-history
        [[ $BUFFER == sudo\ * ]] || BUFFER="sudo $BUFFER"
        zle end-of-line
      }
      zle -N _sudo_prepend
      bindkey "^[^[" _sudo_prepend

      copypath() { print -n -- "''${1:A}" | wl-copy }
      copyfile() { wl-copy < "$1" }
      mkcd() { mkdir -p "$1" && cd "$1" }
      nsh() { nix shell ''${@/#/nixpkgs#} }
      '')
    ];
  };

  programs.atuin = {
    enable = true;
    enableZshIntegration = true;
    settings = {
      style                            = "compact";
      search_mode                       = "fuzzy";
      filter_mode_shell_up_key_binding = "session";
      show_preview                     = true;
      inline_height                    = 20;
    };
  };

  programs.direnv = {
    enable = true;
    enableZshIntegration = true;
    nix-direnv.enable = true;
  };
}
