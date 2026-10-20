# Root-only reads for scripts/health-check.sh, so the unattended audit can see btrfs device
# errors, SMART and TPM2 enrollment on hosts without passwordless sudo (desktop, surface). One
# NOPASSWD rule, for a wrapper that validates its arguments (scripts/health-check-root.sh).
{ config, pkgs, ... }:
let
  healthRoot = pkgs.writeShellApplication {
    name = "health-check-root";
    runtimeInputs = with pkgs; [ btrfs-progs systemd util-linux coreutils gawk smartmontools ];
    text = builtins.readFile ../scripts/health-check-root.sh;
  };
in
{
  environment.systemPackages = [ healthRoot ];

  security.sudo.extraRules = [{
    users = [ config.myConfig.user ];
    commands = [{
      command = "/run/current-system/sw/bin/health-check-root";
      options = [ "NOPASSWD" ];
    }];
  }];
}
