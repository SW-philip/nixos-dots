{ lib, chromium, writeShellApplication, makeDesktopItem, symlinkJoin }:

let
  # GFN caps Linux browsers at 1080p60; a ChromeOS UA unlocks the 1440p/1600p
  # and 120 fps tiers. Version tracks the real Chromium so feature sniffing agrees.
  userAgent = "Mozilla/5.0 (X11; CrOS x86_64 16181.61.0) AppleWebKit/537.36 "
    + "(KHTML, like Gecko) Chrome/${lib.versions.major chromium.version}.0.0.0 Safari/537.36";

  features = lib.concatStringsSep "," [
    "AcceleratedVideoDecodeLinuxGL"
    "AcceleratedVideoDecodeLinuxZeroCopyGL"
    "VaapiVideoDecoder"
    "VaapiIgnoreDriverChecks"
  ];

  launcher = writeShellApplication {
    name = "geforce-now";
    runtimeInputs = [ chromium ];
    text = ''
      # own profile: keeps the GFN login and its flags out of any other Chromium
      profile="''${XDG_DATA_HOME:-$HOME/.local/share}/geforce-now"
      mkdir -p "$profile"
      # GFN_URL: a game's deep link (Pegasus Cloud entries); the path stays /mall/
      # so the app-id and its niri rule don't change
      exec chromium \
        --user-data-dir="$profile" \
        --app="''${GFN_URL:-https://play.geforcenow.com/mall/}" \
        --user-agent=${lib.escapeShellArg userAgent} \
        --ozone-platform-hint=auto \
        --enable-features=${features} \
        --password-store=gnome-libsecret \
        --no-first-run \
        --no-default-browser-check \
        "$@"
    '';
  };

  desktopItem = makeDesktopItem {
    name = "geforce-now";
    desktopName = "GeForce NOW";
    genericName = "Cloud Gaming";
    exec = "geforce-now";
    icon = "input-gaming";
    # Chromium ignores --class on Wayland and derives app_id from the --app URL
    startupWMClass = "chrome-play.geforcenow.com__mall_-Default";
    categories = [ "Game" ];
  };
in
symlinkJoin {
  name = "geforce-now";
  paths = [ launcher desktopItem ];
  meta.mainProgram = "geforce-now";
}
