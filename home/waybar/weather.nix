{ config, pkgs, lib, ... }:
let
  scriptsDir = "${config.home.homeDirectory}/.config/waybar/scripts";
  isDesktop = config.myConfig.isDesktop;

  bar = if config.waybar.barName != "" then config.waybar.barName
        else if isDesktop then "rightBar" else "surfaceTopBar";

  python = pkgs.python3.withPackages (ps: with ps; [ requests ]);

  weatherScript = pkgs.writeShellScriptBin "waybar-weather" ''
    export PATH="${lib.makeBinPath [ python pkgs.fuzzel pkgs.coreutils ]}:$PATH"
    if [ -f /run/secrets/openweathermap_api_key ]; then
      export OPENWEATHERMAP_API_KEY="$(cat /run/secrets/openweathermap_api_key)"
    elif [ -f "$HOME/.config/waybar/.weather_api_key" ]; then
      export OPENWEATHERMAP_API_KEY="$(cat "$HOME/.config/waybar/.weather_api_key")"
    fi
    exec ${python}/bin/python3 ${scriptsDir}/weather.py "$@"
  '';

  radarScript = pkgs.writeShellScriptBin "waybar-weather-radar" ''
    export PATH="${lib.makeBinPath [ pkgs.mpv pkgs.ffmpeg pkgs.procps pkgs.coreutils ]}:$PATH"
    exec ${pkgs.python3}/bin/python3 ${scriptsDir}/weather_radar_mpv.py
  '';

  radarCacheScript = pkgs.writeShellScriptBin "waybar-weather-radar-cache" ''
    export PATH="${lib.makeBinPath [ pkgs.ffmpeg pkgs.coreutils ]}:$PATH"
    exec ${pkgs.python3}/bin/python3 ${scriptsDir}/weather_radar_mpv.py --cache
  '';
in
{
  options.waybar.weather.enable = lib.mkEnableOption "Weather module";

  config = lib.mkIf config.waybar.weather.enable {
    home.packages = [ weatherScript radarScript radarCacheScript ];

    programs.waybar.settings.${bar}."custom/weather" = {
      exec = "${weatherScript}/bin/waybar-weather";
      on-click = "bash ${scriptsDir}/weather_toggle.sh";
      on-click-right = "${radarScript}/bin/waybar-weather-radar";
      return-type = "json";
      interval = 300;
      signal = 8;
      markup = true;
    }
    # Surface's 3-finger tap = middle-click compositor-wide (see
    # home/niri/config.kdl.nix), so location-choice moves to double-click there.
    // (if isDesktop
        then { on-click-middle = "env BUTTON=3 ${weatherScript}/bin/waybar-weather"; }
        else { on-double-click-middle = "env BUTTON=3 ${weatherScript}/bin/waybar-weather"; });

    systemd.user.services.radar-cache = {
      Unit = {
        Description = "Pre-cache weather radar frames";
        After = [ "network-online.target" "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
        ConditionEnvironment = lib.mkForce [ "WAYLAND_DISPLAY" "XDG_CURRENT_DESKTOP=niri" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${radarCacheScript}/bin/waybar-weather-radar-cache";
      };
    };

    systemd.user.timers.radar-cache = {
      Unit = {
        Description = "Weather radar cache timer";
      };
      Timer = {
        OnBootSec = "2min";
        OnUnitActiveSec = "30min";
        Persistent = true;
      };
      Install = {
        WantedBy = [ "timers.target" ];
      };
    };
  };
}
