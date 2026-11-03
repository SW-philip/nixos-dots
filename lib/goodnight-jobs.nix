# The goodnight.jobs option, shared by the NixOS (modules/goodnight-jobs.nix) and home-manager
# (home/goodnight-jobs.nix) halves. Spec: docs/superpowers/specs/2026-11-02-goodnight-umbrella-design.md
{ lib }:
lib.mkOption {
  default = { };
  description = "Services goodnight starts itself, in place of their own timers.";
  type = lib.types.attrsOf (lib.types.submodule ({ name, ... }: {
    options = {
      every = lib.mkOption {
        type = lib.types.enum [ "day" "week" "month" ];
        description = "Due once its last success is older than 20 h / 6.5 d / 29 d.";
      };
      stage = lib.mkOption {
        type = lib.types.enum [ "data" "upkeep" "long" ];
        default = "upkeep";
        description = "data and upkeep run before the reboots; long runs last, and not on a night this host reboots itself.";
      };
      timer = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = "The timer this replaces; a template (btrfs-scrub@) covers all its instances.";
      };
    };
  }));
}
