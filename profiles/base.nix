{ inputs, pkgs, lib, config, ... }:
let
  pythonEnv = import ./python-env.nix pkgs;
in
{
  imports = [
    ../modules/home-options.nix
    ../home/niri-service.nix
    ../home/downloaders.nix
    ../home/waybar
    ../home/niri/swaync
    ../home/hyprlock
    ../home/hypridle.nix
    ../home/zsh
    ../home/eww
    ../home/niri
    ../home/niri/xwayland-satellite.nix
    ../home/firefox
    ../home/tmux
    ../home/fastfetch
    ../home/usb-notify.nix
    ../home/bluetooth-battery-notify.nix
    ../home/bluetooth-device-probe.nix
    ../home/screenshot-sound.nix
    ../home/resource-warn.nix
    ../home/goodnight-jobs.nix
    ../home/settings.nix
    ../home/commands.nix
    ../home/snark.nix
    ../home/polkit-agent.nix
    ../home/shared-apps
  ];

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
  home.file.".local/bin/zed".source = config.lib.file.mkOutOfStoreSymlink "${config.home.profileDirectory}/bin/zeditor";

  ########################################
  # systemd user services
  ########################################
  systemd.user.startServices = "sd-switch";

  systemd.user.services = {
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


  # Language servers on zeditor's PATH: Zed's own ruff download is a generic
  # dynamically linked binary that can't run here (no nix-ld). The settings
  # merge keeps drmis's theme key.
  programs.zed-editor = {
    enable = true;
    extraPackages = with pkgs; [ nixd ruff basedpyright shellcheck bash-language-server ];
    userSettings.languages.Nix.language_servers = [ "nixd" "!nil" ];
  };

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
    # Atuin owns Ctrl-R. Load order already lets atuin's bindkey win (fzf's zsh
    # init is mkOrder 910, atuin's 1000), but home-manager warns unless fzf's
    # own binding is disabled, so state the ownership outright.
    fzf = {
      enable = true;
      historyWidget.command = "";
    };
    gpg.enable       = true;
  };

  services.gpg-agent = {
    enable = true;
    pinentry.package = pkgs.pinentry-gnome3;
  };

  # SSH keys live in gcr-ssh-agent (gnome-keyring, roles/niri.nix), not a second agent.
  systemd.user.sessionVariables.SSH_AUTH_SOCK = "\${XDG_RUNTIME_DIR}/gcr/ssh";


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
    git neovim wget
    jq ripgrep fd bat
    gitleaks unzip resvg
    ouch
    mame-tools pythonEnv
    grim slurp wl-clipboard
    cliphist
    ffmpeg mediainfo vlc playerctl libnotify
    fluidsynth soundfont-fluid
    (writeShellScriptBin "sfx" ''
      # sfx <name>: play assets/sounds/<name>.wav (e.g. sfx error)
      exec ${pipewire}/bin/pw-play ${../assets/sounds}/"$1".wav
    '')
    (writeShellScriptBin "midiplay" ''
      exec ${fluidsynth}/bin/fluidsynth -a pulseaudio -q -i \
        ${soundfont-fluid}/share/soundfonts/FluidR3_GM2-2.sf2 "$@"
    '')

    libreoffice
    nemo
    (symlinkJoin {
      name = "ghostty-random-cursor";
      paths = [ ghostty ];
      nativeBuildInputs = [ makeWrapper ];
      # Cursor colour is picked per window from palette slots 1-6 of the live
      # (drmis-themed) config, so no shader / idle redraw is needed.
      postBuild = ''
        wrapProgram $out/bin/ghostty --run '
          c=$(sed -n "s/^palette = [1-6]=//p" "$HOME/.config/ghostty/config" 2>/dev/null | shuf -n1)
          case " $* " in *" --cursor-color"*) ;; *) [ -n "$c" ] && set -- "--cursor-color=$c" "$@" ;; esac'
      '';
    })

    eza sshfs yt-dlp aria2 imagemagick
    delta lazygit gh tealdeer nix-your-shell comma
    dua mtr sqlite nodejs nvd nix-output-monitor
    easyeffects nwg-look uv

    # MIDI songwriting: vmpk sends notes, fluidsynth (see `synth`) makes sound
    vmpk fluidsynth qpwgraph qsynth soundfont-fluid
    helio-workstation hydrogen
    kdePackages.kdenlive

    (writeShellScriptBin "synth" ''
      exec ${fluidsynth}/bin/fluidsynth -a pipewire -m alsa_seq \
        ${soundfont-generaluser-gs}/share/soundfonts/GeneralUser-GS.sf2 "$@"
    '')
  ];

}
