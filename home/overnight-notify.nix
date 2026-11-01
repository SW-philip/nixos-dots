# User-scope half of overnight notifications (scripts/overnight.sh). Listed user services record
# their outcome on success or failure; a path unit watches the spool (this user's and the system
# one in /var/lib/overnight) and notifies, with an Open action that pages the run's journal.
# A service that sets its own OnSuccess/OnFailure (home/archive.nix) wires the templates itself.
{ config, lib, pkgs, ... }:
let
  cfg = config.overnight.notify;
  overnight = import ../modules/overnight-package.nix { inherit pkgs; };
  spool = "${config.home.homeDirectory}/.local/state/overnight/spool";
  template = outcome: {
    Unit.Description = "Record that %i ${if outcome == "ok" then "finished" else "failed"}";
    Service = {
      Type = "oneshot";
      ExecStart = "${overnight}/bin/overnight record user %i ${outcome}";
    };
  };
in
{
  options.overnight.notify = {
    enable = lib.mkEnableOption "notifications for overnight services";
    units = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "User services (names without .service) whose outcome is recorded.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ overnight ];
    home.activation.overnightSpool = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      mkdir -p ${spool}
    '';

    systemd.user.services = {
      "overnight-ok@" = template "ok";
      "overnight-fail@" = template "fail";
      # also WantedBy the session, so runs that finished while logged out are announced at login
      overnight-notify = {
        Unit = config.lib.niri.unit { wayland = true; } { Description = "Notify about finished overnight services"; };
        Service = { Type = "oneshot"; ExecStart = "${overnight}/bin/overnight consume"; };
        Install.WantedBy = [ "graphical-session.target" ];
      };
    } // lib.genAttrs cfg.units (n: {
      Unit = {
        OnSuccess = [ "overnight-ok@${n}.service" ];
        OnFailure = [ "overnight-fail@${n}.service" ];
      };
    });

    systemd.user.paths.overnight-notify = {
      Unit.Description = "Watch for finished overnight services";
      Path.PathChanged = [ spool "/var/lib/overnight" ];
      Install.WantedBy = [ "paths.target" ];
    };
  };
}
