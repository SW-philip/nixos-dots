# System-scope half of overnight notifications (scripts/overnight.sh): each listed service records
# its outcome in /var/lib/overnight on success or failure. Root can't reach the session bus, so
# the user session (home/overnight-notify.nix) turns those records into notifications.
{ config, lib, pkgs, ... }:
let
  cfg = config.overnight.notify;
  overnight = import ./overnight-package.nix { inherit pkgs; };
  template = outcome: {
    description = "Record that %i ${if outcome == "ok" then "finished" else "failed"}";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${overnight}/bin/overnight record system %i ${outcome}";
    };
  };
in
{
  options.overnight.notify.units = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    # Template instances (btrfs-scrub@-) are left out: defining one here would write a full unit
    # that shadows its NixOS-defined template.
    default = lib.filter (n: !lib.hasInfix "@" n) (lib.attrNames config.goodnight.jobs);
    defaultText = lib.literalExpression "goodnight.jobs names without template instances";
    description = "Existing system services (names without .service) whose outcome is recorded.";
  };

  config = lib.mkIf (cfg.units != [ ]) {
    environment.systemPackages = [ overnight ];
    # records are consumed within seconds of login; a week is for a host nobody logs into
    systemd.tmpfiles.rules = [ "d /var/lib/overnight 0755 root root 7d" ];
    systemd.services = {
      "overnight-ok@" = template "ok";
      "overnight-fail@" = template "fail";
    } // lib.genAttrs cfg.units (n: {
      onSuccess = [ "overnight-ok@${n}.service" ];
      onFailure = [ "overnight-fail@${n}.service" ];
    });
  };
}
