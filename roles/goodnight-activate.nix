# The privileged half of the nightly deploy (scripts/goodnight-activate.sh): one NOPASSWD rule for
# a wrapper that only switches this host to its own system closure, plus a plain `systemctl
# reboot` for goodnight's reboot phase. Every host, so deploy-all can activate non-interactively
# and surface can be deployed from desktop. The jobs goodnight runs: modules/goodnight-jobs.nix.
{ config, pkgs, ... }:
let
  activate = pkgs.writeShellApplication {
    name = "goodnight-activate";
    runtimeInputs = with pkgs; [ coreutils systemd config.nix.package ];
    text = builtins.readFile ../scripts/goodnight-activate.sh;
  };
in
{
  imports = [ ../modules/goodnight-jobs.nix ];

  environment.systemPackages = [ activate ];

  security.sudo.extraRules = [{
    users = [ config.myConfig.user ];
    commands = [
      { command = "/run/current-system/sw/bin/goodnight-activate"; options = [ "NOPASSWD" ]; }
      # goodnight's reboot phase; sudoers matches the arguments exactly, so only a plain reboot
      { command = "/run/current-system/sw/bin/systemctl reboot"; options = [ "NOPASSWD" ]; }
    ];
  }];
}
