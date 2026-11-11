{ config, lib, pkgs, ... }:
let
  home = config.home.homeDirectory;
  sweep = pkgs.writeShellApplication {
    name = "empty-dirs";
    runtimeInputs = with pkgs; [ coreutils findutils gnugrep ];
    text = builtins.readFile ../scripts/empty-dirs.sh;
  };
in
{
  home.packages = [ sweep ];

  xdg.configFile."empty-dirs/roots".text = lib.concatLines [ home "/srv" ];

  # Folders that are meant to sit empty: script drop targets, channel slots
  # filled by ia-fetch/split-commercials, and app-owned trees.
  xdg.configFile."empty-dirs/keep".text = lib.concatLines [
    "${home}/Videos"
    "/srv/Videos/record" "/srv/Videos/live" "/srv/Videos/rip" "/srv/Videos/tape" "/srv/Videos/burn"
    "/srv/Audios/record" "/srv/Audios/rip" "/srv/Audios/tape"
    "/srv/Videos/*/commercials" "/srv/Videos/*/retro"
    "/srv/live" "/srv/Games" "/srv/game-saves" "/srv/roms" "/srv/torrents" "/srv/jellyfin"
  ];

  goodnight.jobs.empty-dirs.every = "week";

  systemd.user.services.empty-dirs = {
    Unit.Description = "Remove stale empty folders from home and /srv";
    Service = {
      Type = "oneshot";
      ExecStart = "${sweep}/bin/empty-dirs --delete";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
  };

  systemd.user.timers.empty-dirs = {
    Unit.Description = "Weekly empty-folder sweep";
    Timer = { OnCalendar = "weekly"; RandomizedDelaySec = "1h"; Persistent = true; };
    Install.WantedBy = [ "timers.target" ];
  };
}
