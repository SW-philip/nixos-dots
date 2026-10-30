{ config, pkgs, lib, ... }:
let
  dir = ../scripts/settings;
  # Rows and sections gate on these words (has_cap in lib.sh, "requires" in sections.json).
  caps = lib.concatStringsSep " " (
    lib.optional config.myConfig.isDesktop "desktop"
    ++ lib.optional config.myConfig.hasTouch "touch"
    ++ lib.optional config.myConfig.hasBacklight "backlight"
  );
  mk = name: file: inputs: pkgs.writeShellApplication {
    inherit name;
    runtimeInputs = inputs;
    runtimeEnv = {
      SETTINGS_LIB = "${dir}/lib.sh";
      SETTINGS_SECTIONS = "${dir}/sections.json";
      SETTINGS_CAPS = caps;
    };
    text = builtins.readFile (dir + "/${file}");
  };
in
{
  home.packages = [
    (mk "settings"           "settings.sh"  [ pkgs.jq pkgs.procps ])
    (mk "settings-network"   "network.sh"   [ ])
    (mk "settings-bluetooth" "bluetooth.sh" [ ])
    (mk "settings-audio"     "audio.sh"     [ pkgs.jq pkgs.wireplumber pkgs.pipewire pkgs.pavucontrol ])
    (mk "settings-display"   "display.sh"   [ pkgs.jq pkgs.kanshi pkgs.brightnessctl ])
    (mk "settings-interface" "interface.sh" [ ])
  ];
}
