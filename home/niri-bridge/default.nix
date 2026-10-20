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
    Unit = config.lib.niri.unit { wayland = false; } {
      Description = "NiriBridge keyboard and pointer sharing";
      StartLimitIntervalSec = 60;
      StartLimitBurst = 3;
    };
    Service = {
      Type = "simple";
      ExecStart = "${pkgs.niri-bridge}/bin/niri-bridge run --config ${config.home.homeDirectory}/.config/niri-bridge/config.toml";
      # Upstream shells out to openssl for fingerprint inspection; a user unit has no PATH to find it.
      Environment = [ "PATH=${pkgs.openssl}/bin" ];
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
