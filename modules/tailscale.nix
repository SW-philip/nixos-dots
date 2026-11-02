{ config, lib, ... }:
let ports = import ../hosts/ports.nix; in
{
  services.tailscale.enable = true;
  # tailscale0 is not a trusted interface: each service opens its own port on it
  # (syncthing.nix, sunshine.nix, desktop NFS), so a new listener is closed to the tailnet by default.
  networking.firewall = {
    interfaces.tailscale0.allowedTCPPorts = [ ports.niri-bridge ];
    checkReversePath = "loose";
  };

  security.sudo.extraRules = [{
    users = [ config.myConfig.user ];
    commands = [
      {
        command = "/run/current-system/sw/bin/systemctl start tailscaled.service";
        options = [ "NOPASSWD" ];
      }
      {
        command = "/run/current-system/sw/bin/systemctl stop tailscaled.service";
        options = [ "NOPASSWD" ];
      }
    ];
  }];
}
