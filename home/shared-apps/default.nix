{ config, lib, pkgs, ... }:
let
  cfg = config.myConfig.apps;
  self = if config.myConfig.isDesktop then "desktop" else "surface";

  appLaunch = pkgs.writeShellApplication {
    name = "app-launch";
    runtimeInputs = with pkgs; [ jq libnotify coreutils fuzzel ];
    text = builtins.readFile ../../scripts/app-launch.sh;
  };

  checkApps = pkgs.writeShellApplication {
    name = "check-apps";
    runtimeInputs = with pkgs; [ jq openssh coreutils ];
    text = builtins.readFile ../../scripts/check-apps.sh;
  };

  hideApps = pkgs.writeShellApplication {
    name = "hide-apps";
    runtimeInputs = with pkgs; [ coreutils gawk ];
    text = builtins.readFile ../../scripts/hide-apps.sh;
  };

  registry = {
    inherit self;
    apps = lib.mapAttrs (_: a: { inherit (a) exec remoteExec hosts; }) cfg.remote;
  };
in
{
  options.myConfig.apps.remote = lib.mkOption {
    default = { };
    description = ''
      Apps opened through app-launch. The attribute name is the desktop-file id
      (without .desktop): the generated entry shadows the packaged one, so it
      must match it exactly.
    '';
    type = lib.types.attrsOf (lib.types.submodule ({ config, ... }: {
      options = {
        name = lib.mkOption { type = lib.types.str; };
        icon = lib.mkOption { type = lib.types.str; };
        exec = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "argv used when launching on this host.";
        };
        remoteExec = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          default = config.exec;
          description = "argv used on another host; differs for apps that hand off to a running instance.";
        };
        hosts = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "Fleet hosts that have this app installed (check-apps verifies it).";
        };
      };
    }));
  };

  options.myConfig.apps.hide = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [ ];
    description = ''
      Desktop-file ids (without .desktop) hidden from launchers. The real entry is copied with
      NoDisplay=true so MIME handling keeps working; ids a host doesn't have are ignored.
    '';
  };

  config = {
    # `on` comes from home/on.nix via the same profile
    home.packages = [ appLaunch checkApps hideApps ];

    xdg.configFile."app-launch/registry.json".text = builtins.toJSON registry;

    # %U kept: xdg-open and file managers pass URLs/files through this entry
    xdg.desktopEntries = lib.mapAttrs (id: a: {
      inherit (a) name icon;
      exec = "app-launch ${id} %U";
      terminal = false;
      categories = [ "Utility" ];
    }) cfg.remote;

    assertions = [{
      assertion = lib.all (id: !(lib.hasAttr id cfg.remote)) cfg.hide;
      message = "myConfig.apps.hide and myConfig.apps.remote must not share an id";
    }];

    home.activation.hideApps = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      $DRY_RUN_CMD ${hideApps}/bin/hide-apps ${lib.escapeShellArgs cfg.hide}
    '';

    myConfig.apps.remote = {
      "com.mitchellh.ghostty" = {
        name = "Ghostty";
        icon = "com.mitchellh.ghostty";
        exec = [ "ghostty" "--gtk-single-instance=true" ];
        remoteExec = [ "ghostty" "--gtk-single-instance=false" ];
        hosts = [ "desktop" "surface" ];
      };
      # a running Firefox swallows a second launch (shared user D-Bus), so remote gets its own profile.
      # A bare --profile dir, not -P: home-manager owns profiles.ini (read-only), so Firefox can't add a named profile.
      # drmis only themes the profiles listed in profiles.ini, so each launch copies the host's deployed
      # userChrome/userContent in and turns on the pref that makes Firefox read them.
      "firefox" = {
        name = "Firefox";
        icon = "firefox";
        exec = [ "firefox" "--name" "firefox" ];
        remoteExec = [
          "sh" "-c"
          ''d="$HOME/.local/share/firefox-remote"; mkdir -p "$d/chrome"; cp -f "$HOME"/.mozilla/firefox/default/chrome/user*.css "$d/chrome/" 2>/dev/null; echo 'user_pref("toolkit.legacyUserProfileCustomizations.stylesheets", true);' > "$d/user.js"; exec firefox --no-remote --profile "$d"''
        ];
        hosts = [ "desktop" "surface" ];
      };
      "vlc" = {
        name = "VLC media player";
        icon = "vlc";
        exec = [ "vlc" ];
        hosts = [ "desktop" "surface" ];
      };
      "org.kde.kdenlive" = {
        name = "Kdenlive";
        icon = "kdenlive";
        exec = [ "kdenlive" ];
        hosts = [ "surface" ];
      };
      # zed forwards a second launch to the running instance over its own IPC; a separate data dir avoids that
      "dev.zed.Zed" = {
        name = "Zed";
        icon = "zed";
        exec = [ "zeditor" ];
        remoteExec = [ "sh" "-c" "exec zeditor --user-data-dir \"$HOME/.local/share/zed-remote\"" ];
        hosts = [ "desktop" "surface" ];
      };
    };

    myConfig.apps.hide = [
      # LibreOffice modules; the start centre ("startcenter") stays and opens any of them
      "base" "calc" "draw" "impress" "math" "writer"
      # plumbing
      "nvim" "mpv" "nwg-look"
      "org.kde.kdeconnect.nonplasma" "org.kde.kdeconnect.sms"
      # emulators: Pegasus is the front end
      "dev.eden_emu.eden" "dolphin-emu" "info.cemu.Cemu" "org.azahar_emu.Azahar"
      "PCSX2" "rpcs3" "xemu" "ppsspp"
      # desktop admin tools
      "winetricks" "remote-viewer" "nvidia-settings"
    ];
  };
}
