# The privileged half of the nightly deploy (scripts/goodnight-activate.sh): one NOPASSWD rule for
# a wrapper that only switches this host to its own system closure. Every host, so deploy-all can
# activate non-interactively and surface can be deployed from desktop.
{ config, pkgs, ... }:
let
  activate = pkgs.writeShellApplication {
    name = "goodnight-activate";
    runtimeInputs = with pkgs; [ coreutils systemd config.nix.package ];
    text = builtins.readFile ../scripts/goodnight-activate.sh;
  };
in
{
  environment.systemPackages = [ activate ];

  security.sudo.extraRules = [{
    users = [ "prepko" ];
    commands = [{
      command = "/run/current-system/sw/bin/goodnight-activate";
      options = [ "NOPASSWD" ];
    }];
  }];
}
