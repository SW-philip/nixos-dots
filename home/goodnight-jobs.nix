# User services goodnight runs overnight (scripts/goodnight.sh, phase jobs): their timers are
# left installed but no longer wanted, and goodnight reads the list from
# ~/.config/goodnight/jobs.json. System-side half: modules/goodnight-jobs.nix.
{ config, lib, ... }:
let
  jobs = config.goodnight.jobs;
in
{
  options.goodnight.jobs = import ../lib/goodnight-jobs.nix { inherit lib; };

  config = lib.mkIf (jobs != { }) {
    systemd.user.timers = lib.mapAttrs' (_: j: lib.nameValuePair j.timer { Install.WantedBy = lib.mkForce [ ]; }) jobs;

    xdg.configFile."goodnight/jobs.json".text =
      builtins.toJSON (lib.mapAttrs (_: j: { inherit (j) every stage; }) jobs);
  };
}
