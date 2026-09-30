{ pkgs, config, ... }:
{
  home.packages = [ pkgs.niri-bridge ];

  # Config, identity and pairing files are NOT home-manager-managed: the
  # daemon owns ~/.config/niri-bridge/config.toml after first run (rewrites
  # [[edges]] entries, bumps config revisions) and generates
  # identity.pem/identity.key.pem/peer.pem itself. A home-manager-managed
  # symlink here would fight that. See the design spec's "Configuration,
  # identity, persistence" section.
  systemd.user.services.niri-bridge = {
    Unit = {
      Description = "NiriBridge keyboard and pointer sharing";
      ConditionEnvironment = [ "XDG_CURRENT_DESKTOP=niri" ];
      After = [ "graphical-session.target" ];
      PartOf = [ "graphical-session.target" ];
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "simple";
      # A host being actively controlled via NiriBridge (or simply idle
      # between conversational turns during a debugging session) can still
      # hit hypridle's 8-minute lock timeout -- observed live on both hosts
      # during first real use (both independently logged "Sharing paused
      # while the graphical session is locked" ~8 minutes after pairing).
      # The exact mechanism isn't nailed down (niri's own idle-notify path
      # doesn't appear to filter synthetic uinput input from real input, so
      # the simplest explanation may just be an ordinary idle gap, not
      # something specific to cross-machine control) -- but a locked
      # session pauses niri-bridge.service either way, so inhibiting idle
      # for the service's runtime fixes the symptom regardless of cause.
      # systemd-inhibit --what=idle holds a logind inhibitor for this
      # process's whole lifetime (released automatically on exit); hypridle
      # already respects it (ignore_systemd_inhibit defaults to false,
      # profiles/base.nix only overrides ignore_dbus_inhibit).
      ExecStart = "${pkgs.systemd}/bin/systemd-inhibit --what=idle --who=niri-bridge '--why=NiriBridge cross-machine input sharing active' --mode=block ${pkgs.niri-bridge}/bin/niri-bridge run --config ${config.home.homeDirectory}/.config/niri-bridge/config.toml";
      Restart = "on-failure";
      RestartSec = 3;
      TimeoutStopSec = 4;
      KillMode = "control-group";
      UMask = "0077";
      NoNewPrivileges = true;
      LockPersonality = true;
      RestrictAddressFamilies = "AF_UNIX AF_INET AF_INET6";
    };
    Install.WantedBy = [ "graphical-session.target" ];
  };
}
