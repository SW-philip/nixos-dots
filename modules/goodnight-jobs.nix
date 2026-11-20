# System services goodnight runs overnight (scripts/goodnight.sh, phase jobs). Their own timers
# are masked; goodnight finds the list in /etc/goodnight/jobs.json and starts each one over ssh
# (or locally on desktop) as prepko, which a polkit rule allows for exactly these units.
{ config, lib, ... }:
let
  jobs = config.goodnight.jobs;
  units = map (n: "${n}.service") (lib.attrNames jobs);
in
{
  options.goodnight.jobs = import ../lib/goodnight-jobs.nix { inherit lib; };

  config = lib.mkIf (jobs != { }) {
    systemd.timers = lib.mapAttrs' (_: j: lib.nameValuePair j.timer { enable = false; }) jobs;

    environment.etc."goodnight/jobs.json".text =
      builtins.toJSON (lib.mapAttrs (_: j: { inherit (j) every stage; }) jobs);

    security.polkit.extraConfig = ''
      polkit.addRule(function(action, subject) {
        if (action.id === "org.freedesktop.systemd1.manage-units" &&
            subject.user === "${config.myConfig.user}" &&
            // systemctl start --wait also calls Unit.Ref (verb "ref") to pin the unit; without it
            // that call pops a polkit dialog nobody answers, cancelled when the job ends.
            ["start", "ref"].indexOf(action.lookup("verb")) >= 0 &&
            ${builtins.toJSON units}.indexOf(action.lookup("unit")) >= 0) {
          return polkit.Result.YES;
        }
      });
    '';
  };
}
