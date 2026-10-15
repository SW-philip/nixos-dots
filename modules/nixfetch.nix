{ config, pkgs, ... }:
let
  sampler = pkgs.writeShellApplication {
    name = "nixfetch-sample";
    runtimeInputs = with pkgs; [ jq coreutils gawk gnused config.nix.package ];
    text = builtins.readFile ../scripts/nixfetch-sample.sh;
  };
in
{
  systemd.services.nixfetch-sample = {
    description = "Write this host's flake facts for nixfetch";
    environment.NIXFETCH_LOCK = "${../flake.lock}";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${sampler}/bin/nixfetch-sample";
      StateDirectory = "nixfetch";
      StateDirectoryMode = "0755";
      Nice = 19;
    };
  };

  systemd.timers.nixfetch-sample = {
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "2min"; OnUnitActiveSec = "1h"; AccuracySec = "5min"; };
  };

  # A deploy changes this unit (the revision is a restart trigger), so switch-to-configuration
  # restarts it and it pokes a fresh sample; a RemainAfterExit unit is what makes switch restart it.
  systemd.services.nixfetch-sample-activation = {
    description = "Refresh nixfetch's host.json after a deploy";
    wantedBy = [ "multi-user.target" ];
    restartTriggers = [ (toString config.system.configurationRevision) ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${config.systemd.package}/bin/systemctl start --no-block nixfetch-sample.service";
    };
  };
}
