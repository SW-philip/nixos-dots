{ inputs, pkgs, lib, config, ... }:
let
  pythonEnv = pkgs.python312.withPackages (ps: with ps; [
    pygobject3 textual rich pystray pillow pydbus cairosvg
    requests watchdog python-dateutil
    loguru platformdirs attrs typing-extensions
    build setuptools wheel pyyaml
  ]);

  sqlchHttpBridge = pkgs.writeScript "sqlch-http-bridge" ''
    #!${pkgs.python3}/bin/python3
    import json, os, socket
    from http.server import BaseHTTPRequestHandler, HTTPServer

    PORT = 8766  # NOT 8765 — that's iptv-serve (hosts/desktop/services.nix); bind-collides on desktop
    SOCK = os.path.join(os.environ.get("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}"), "sqlch", "control.sock")

    def sqlch(msg):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.settimeout(2.0)
            s.connect(SOCK)
            s.sendall((json.dumps(msg) + "\n").encode())
            buf = b""
            while not buf.endswith(b"\n"):
                chunk = s.recv(4096)
                if not chunk:
                    break
                buf += chunk
        return json.loads(buf.decode("utf-8", errors="replace"))

    class H(BaseHTTPRequestHandler):
        def _send(self, code, body):
            b = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", len(b))
            self.end_headers()
            self.wfile.write(b)

        def do_OPTIONS(self):
            self.send_response(204)
            self.send_header("Access-Control-Allow-Origin", "*")
            self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
            self.send_header("Access-Control-Allow-Headers", "Content-Type")
            self.end_headers()

        def do_GET(self):
            if self.path != "/status":
                self._send(404, {"error": "not found"}); return
            try:
                self._send(200, sqlch({"cmd": "status"}))
            except Exception as e:
                self._send(503, {"ok": False, "error": str(e)})

        def do_POST(self):
            if self.path != "/command":
                self._send(404, {"error": "not found"}); return
            try:
                n = int(self.headers.get("Content-Length", 0))
                msg = json.loads(self.rfile.read(n))
                self._send(200, sqlch(msg))
            except Exception as e:
                self._send(503, {"ok": False, "error": str(e)})

        def log_message(self, *_): pass

    HTTPServer(("127.0.0.1", PORT), H).serve_forever()
  '';

  # Guards the 18-min idle session-quit: media playback (or any other
  # process on the blacklist below) alone doesn't reset hypridle's idle
  # timer (only input activity does), so without this the quit would fire
  # once and kill music/video/a claude session/a rebuild along with the
  # session. Polls while still locked + busy; bails without quitting if the
  # user unlocks first, and quits once nothing on the list is still running.
  # Blacklist patterns are `pgrep -f` regexes, checked across all users'
  # processes (a `nrs`/nixos-rebuild runs as root under sudo) — add a
  # pattern here for anything else that shouldn't be interrupted by a
  # logout while the screen happens to be locked.
  hypridleQuitBlacklist = [
    "nixos-rebuild"    # nrs / nh os switch / manual nixos-rebuild
    "/bin/nh os"        # nh itself, before it shells out to nixos-rebuild
    "claude"           # claude code CLI session (also matches its own child shells)
  ];
  hypridleQuitGuard = pkgs.writeShellScript "hypridle-quit-guard" ''
    export PATH="${lib.makeBinPath [ pkgs.playerctl pkgs.procps ]}:$PATH"

    is_busy() {
      playerctl -a status 2>/dev/null | grep -q Playing && return 0
      ${lib.concatMapStringsSep "\n      " (pat: ''pgrep -f ${lib.escapeShellArg pat} >/dev/null 2>&1 && return 0'') hypridleQuitBlacklist}
      return 1
    }

    while pidof hyprlock >/dev/null 2>&1 && is_busy; do
      sleep 60
    done
    pidof hyprlock >/dev/null 2>&1 && niri msg action quit -s
  '';
in
{
  imports = [
    ../modules/home-options.nix
    ../home/waybar
    ../home/niri/swaync
    ../home/eww
    ../home/niri
    ../home/niri/xwayland-satellite.nix
    ../home/firefox
    ../home/tmux
    ../home/fastfetch
    ../home/usb-notify.nix
    ../home/bluetooth-battery-notify.nix
    ../home/bluetooth-device-probe.nix
    ../home/fitlauncher-watchdog.nix
    ../home/sqlch-sync.nix
    inputs.sqlch.homeManagerModules.default
  ];

  sqlch.gui.enable = true;

  ########################################
  # Session / GTK
  ########################################
  gtk = {
    enable = true;
    gtk4.theme = config.gtk.theme;
    theme = {
      name    = "Adwaita-dark";
      package = pkgs.gnome-themes-extra;
    };
    iconTheme = {
      name    = "Papirus-Dark";
      package = pkgs.papirus-icon-theme;
    };
  };

  # home-manager's gtk module only writes gtk-3.0/gtk-4.0 settings.ini, never
  # dconf — so without this, org/gnome/desktop/interface.color-scheme stays
  # at the GNOME default (light) even though gtk.theme.name above is dark.
  # Firefox's native urlbar widgets follow settings.ini (dark) while its own
  # "Auto" chrome theme follows this dconf key (light) — the mismatch is a
  # white urlbar with white text. Both hosts need the same value here.
  dconf.settings."org/gnome/desktop/interface" = {
    color-scheme = "prefer-dark";
    gtk-theme    = "Adwaita-dark";
  };

  home.pointerCursor = {
    enable  = true;
    name    = "posys_cursor_scalable";
    package = inputs.posys-cursor.packages.${pkgs.stdenv.hostPlatform.system}.default;
    size    = 48;
    gtk.enable = true;
  };

  xdg.portal.config.common.default = "*";

  xdg.configFile."systemd/user/xdg-desktop-portal-gnome.service.d/unset-gdk-backend.conf".text = ''
    [Service]
    UnsetEnvironment=GDK_BACKEND
  '';

  xdg.dataFile."mime/packages/custom-dev.xml".text = ''
    <?xml version="1.0" encoding="UTF-8"?>
    <mime-info xmlns="http://www.freedesktop.org/standards/shared-mime-info">
      <mime-type type="text/x-nix">
        <comment>Nix expression</comment>
        <glob pattern="*.nix"/>
        <sub-class-of type="text/plain"/>
      </mime-type>
      <mime-type type="text/x-conf">
        <comment>Configuration file</comment>
        <glob pattern="*.conf"/>
        <sub-class-of type="text/plain"/>
      </mime-type>
    </mime-info>
  '';

  home.activation.papirus-violet = lib.hm.dag.entryAfter ["writeBoundary"] ''
    export PATH="${pkgs.gawk}/bin:${pkgs.coreutils}/bin:$PATH"
    _ICONS="$HOME/.local/share/icons"
    _THEME="$_ICONS/Papirus-Dark"
    _SRC="${pkgs.papirus-icon-theme}/share/icons/Papirus-Dark"
    _FLUENT="${pkgs.fluent-icon-theme}/share/icons/Fluent-dark/scalable/places"
    _STAMP="$_ICONS/.papirus-dark-src"
    if [ "$(cat "$_STAMP" 2>/dev/null)" != "${pkgs.papirus-icon-theme}:${pkgs.fluent-icon-theme}" ]; then
      $DRY_RUN_CMD rm -rf "$_THEME"
      $DRY_RUN_CMD cp -rL "$_SRC" "$_THEME"
      $DRY_RUN_CMD chmod -R u+w "$_THEME"
      $DRY_RUN_CMD ${pkgs.papirus-folders}/bin/papirus-folders -C violet -t Papirus-Dark
      for _SIZE in 16x16 22x22 24x24 32x32 48x48 64x64; do
        _DIR="$_THEME/$_SIZE/mimetypes"
        [ -d "$_DIR" ] || continue
        $DRY_RUN_CMD ln -sf text-x-haskell.svg      "$_DIR/text-x-nix.svg"
        $DRY_RUN_CMD ln -sf text-x-systemd-unit.svg "$_DIR/text-x-conf.svg"
      done
      # Fluent ships an actual "folder-violet" alias (-> purple-folder.svg) with a layered/sheen
      # look, unlike Papirus's flat recolor. Swap it in for the generic + bookmark places Nemo
      # renders; papirus-folders' violet recolor above still covers the long tail of app-specific
      # folder icons (git/steam/docker/...) Fluent doesn't ship colored variants of.
      for _PLACES in "$_THEME"/*/places; do
        [ -d "$_PLACES" ] || continue
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder.svg"             "$_PLACES/folder.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-documents.svg"   "$_PLACES/folder-documents.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-download.svg"    "$_PLACES/folder-download.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-download.svg"    "$_PLACES/folder-downloads.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-music.svg"       "$_PLACES/folder-music.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-pictures.svg"    "$_PLACES/folder-pictures.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-publicshare.svg" "$_PLACES/folder-public.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-publicshare.svg" "$_PLACES/folder-publicshare.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-recent.svg"      "$_PLACES/folder-recent.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-templates.svg"   "$_PLACES/folder-templates.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-video.svg"       "$_PLACES/folder-video.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-folder-video.svg"       "$_PLACES/folder-videos.svg"
        $DRY_RUN_CMD ln -sf "$_FLUENT/purple-user-desktop.svg"       "$_PLACES/user-desktop.svg"
      done
      $DRY_RUN_CMD printf '%s' "${pkgs.papirus-icon-theme}:${pkgs.fluent-icon-theme}" > "$_STAMP"
    fi
    $DRY_RUN_CMD ${pkgs.shared-mime-info}/bin/update-mime-database \
      "$HOME/.local/share/mime"
  '';

  home.stateVersion = "25.11";
  home.sessionPath = [ "$HOME/.local/bin" ];
  home.sessionVariables.CLAUDE_ENV_FILE = "$HOME/.claude/.env";
  home.file.".local/bin/zed".source = "${pkgs.zed-editor}/bin/zeditor";

  ########################################
  # systemd user services
  ########################################
  systemd.user.startServices = "sd-switch";

  systemd.user.services = {
    sqlch-daemon = {
      Unit = {
        Description = "sqlch mpris daemon";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.bash}/bin/bash -c 'set -a; . /run/secrets/spotify_env; set +a; exec ${pkgs.sqlch}/bin/sqlch daemon'";
        Restart = "on-failure";
        MemoryMax = "300M";
        MemorySwapMax = "0";
        Environment = "MALLOC_ARENA_MAX=2";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    sqlch-http-bridge = {
      Unit = {
        Description = "sqlch HTTP bridge for Firefox startpage";
        After = [ "sqlch-daemon.service" "graphical-session.target" ];
        BindsTo = [ "sqlch-daemon.service" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${sqlchHttpBridge}";
        Restart = "on-failure";
        RestartSec = "3s";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    protonmail-bridge = {
      Unit = {
        Description = "Proton Mail Bridge";
        After = [ "network-online.target" "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.protonmail-bridge}/bin/protonmail-bridge --noninteractive";
        Restart = "on-failure";
        RestartSec = 5;
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    cliphist-text = {
      Unit = {
        Description = "cliphist text clipboard watcher";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type text --watch ${pkgs.cliphist}/bin/cliphist store -max-items 400";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };

    cliphist-image = {
      Unit = {
        Description = "cliphist image clipboard watcher";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        ExecStart = "${pkgs.wl-clipboard}/bin/wl-paste --type image --watch ${pkgs.cliphist}/bin/cliphist store -max-items 400";
        Restart = "on-failure";
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };

  ########################################
  # Shell
  ########################################
  programs.zsh = {
    enable = true;
    enableCompletion = true;
    autosuggestion.enable = true;
    syntaxHighlighting.enable = true;

    history = {
      size = 50000;
      save = 50000;
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
      lb = "sudo rm -f /boot/EFI/systemd/systemd-bootx64.efi /boot/EFI/BOOT/BOOTX64.EFI && sudo rm -f /boot/EFI/Linux/nixos-*.efi";
      # -e pins nh's elevation strategy to the real setuid sudo wrapper —
      # nh's "auto" detection can otherwise resolve the non-setuid
      # /run/current-system/sw/bin/sudo and fail activation.
      nrs = "nh os switch -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos";
      nrb = "nh os boot -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos";
      nrt = "nh os test -e /run/wrappers/bin/sudo ${config.home.homeDirectory}/nixos";
      nfu = "nix flake update";
      ".." = "cd ..";
      "..." = "cd ../..";
      "...." = "cd ../../..";
      grep = "grep --color=auto";
      ip = "ip --color=auto";
      diff = "delta";
      harmonize = "bash ~/nixos/scripts/harmonize-themes.sh";
    };

    # compaudit stats every dir in $fpath on every startup (Nix profiles inflate
    # $fpath heavily); that alone was ~40% of shell startup time (measured via
    # zprof). Store paths are read-only and root-owned, so the insecure-perms
    # check compaudit guards against can't happen here.
    envExtra = ''
      ZSH_DISABLE_COMPFIX=true
    '';

    oh-my-zsh = {
      enable = true;
      plugins = [ "git" "sudo" "zoxide" "extract" "copypath" "copyfile" ];
    };

    plugins = [
      {
        name = "powerlevel10k";
        src = pkgs.zsh-powerlevel10k;
        file = "share/zsh-powerlevel10k/powerlevel10k.zsh-theme";
      }
      {
        name = "you-should-use";
        src = pkgs.zsh-you-should-use;
        file = "share/zsh/plugins/you-should-use/you-should-use.plugin.zsh";
      }
      {
        name = "autopair";
        src = pkgs.zsh-autopair;
        file = "share/zsh/zsh-autopair/autopair.zsh";
      }
    ];

    # p10k instant prompt only works if this is the first thing .zshrc does —
    # sourced after oh-my-zsh/plugins it just writes a cache file nothing reads.
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

      ${pkgs.nix-your-shell}/bin/nix-your-shell zsh | source /dev/stdin

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

  programs.hyprlock.enable = true;

  ########################################
  # Programs
  ########################################
  programs = {
    mpv = {
      enable  = true;
      scripts = [ pkgs.mpvScripts.mpris ];
    };

    btop.enable      = true;
    yazi = { enable = true; shellWrapperName = "yy"; };
    zoxide.enable    = true;
    # Atuin owns Ctrl-R. On release-26.05 (surface) this falls out of
    # load order: fzf's zsh integration runs at mkOrder 910, before atuin's
    # default-order (1000) init, so atuin's bindkey wins. home-manager-unstable
    # (desktop) additionally warns unless fzf's own Ctrl-R binding is disabled
    # explicitly, so state the ownership outright rather than rely on ordering.
    fzf = {
      enable = true;
    };
    gpg.enable       = true;
  };

  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-gnome3;
  };

  # SSH keys live in gcr-ssh-agent (gnome-keyring, roles/niri.nix), not a second agent.
  systemd.user.sessionVariables.SSH_AUTH_SOCK = "\${XDG_RUNTIME_DIR}/gcr/ssh";

  programs.ssh = {
    enable = true;
    # enableDefaultConfig is deprecated upstream; the block it injected just
    # restates OpenSSH's own compiled-in defaults (ForwardAgent no,
    # ServerAliveInterval 0, HashKnownHosts no, ControlMaster/Persist no,
    # etc.) so disabling it changes nothing behaviorally.
    enableDefaultConfig = false;
    settings."*".AddKeysToAgent = "yes";
  };

  ########################################
  # Services
  ########################################
  services.hypridle = {
    enable = true;
    settings = {
      general = {
        lock_cmd = "pidof hyprlock || ${config.myConfig.lockScreenScript}";
        unlock_cmd = "niri msg action do-screen-transition";
        before_sleep_cmd = "loginctl lock-session";
        after_sleep_cmd = "";
        ignore_dbus_inhibit = false;
      };
      listener = [
        {
          timeout = 240;
          on-timeout = "${pkgs.brightnessctl}/bin/brightnessctl -s s 10%";
          on-resume = "${pkgs.brightnessctl}/bin/brightnessctl -r";
        }
        {
          timeout = 480;
          on-timeout = "pidof hyprlock || ${config.myConfig.lockScreenScript}";
        }
        {
          timeout = 900;
          on-timeout = "niri msg action power-off-monitors 2>/dev/null; hyprctl dispatch dpms off 2>/dev/null; true";
          on-resume = "niri msg action power-on-monitors 2>/dev/null; hyprctl dispatch dpms on 2>/dev/null; true";
        }
      ] ++ lib.optional (!config.myConfig.isDesktop) {
        # 10 min after the 8-min lock: end the niri session, dropping back to
        # the greeter. No on-resume — there's nothing to come back to.
        # Guarded so it won't kill a playing music/video session (see
        # hypridleQuitGuard above). Desktop is excluded: greetd auto-logs
        # prepko straight back into niri (initial_session in
        # hosts/desktop/config.nix), so dropping to the greeter there just
        # forces a re-login (and a keyring re-unlock) for no security
        # benefit — desktop should only ever lock on idle, never log out.
        timeout = 1080;
        on-timeout = "${hypridleQuitGuard}";
      };
    };
  };

  ########################################
  # yt-dlp
  ########################################
  xdg.configFile."yt-dlp/config".text = ''
    --downloader aria2c
    --downloader-args "aria2c:-x 16 -s 16 -k 1M"
    --concurrent-fragments 5
  '';

  ########################################
  # Packages
  ########################################
  home.packages = with pkgs; [
    git neovim wget rsync
    jq ripgrep fd bat
    gitleaks unzip resvg
    ouch
    mame-tools pythonEnv claude-code
    grim slurp wl-clipboard
    fuzzel cliphist
    ffmpeg mediainfo vlc playerctl libnotify

    thunderbird libreoffice
    nemo zed-editor ghostty

    eza sshfs yt-dlp aria2 imagemagick
    delta lazygit gh tealdeer nix-your-shell comma
    dua mtr sqlite nodejs nvd nix-output-monitor
    easyeffects nwg-look uv

    (writeShellScriptBin "get-theme" ''
      exec ${pythonEnv}/bin/python3 ~/nixos/scripts/auto-theme.py "$@"
    '')

    (writeShellScriptBin "scrape" ''
      exec ~/nixos/scripts/skyscraper-scrape.sh "$@"
    '')

    (writeShellScriptBin "openb64" ''
      exec ~/nixos/scripts/openb64.sh "$@"
    '')

    (writeShellScriptBin "extract-to-backup" ''
      exec ~/nixos/scripts/extract-to-backup.sh "$@"
    '')
  ];

}
