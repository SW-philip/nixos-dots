{ config, pkgs, lib, ... }:

let
  # /home and /persist are the only subvolumes holding data that can't be
  # rebuilt from the flake. Snapshots sit inside each subvolume (.snapshots);
  # the daily run also sends them to the separate LUKS disk at /mnt/backup.
  sources = {
    home = "/home";
    persist = "/persist";
  };
  targetRoot = "/mnt/backup/btrbk";

  # Both instances share one retention policy: btrbk prunes by policy, so
  # differing snapshot_preserve values would delete each other's snapshots.
  common = {
    timestamp_format = "long";
    snapshot_preserve_min = "2d";
    snapshot_preserve = "24h 7d";
    target_preserve_min = "7d";
    target_preserve = "14d 8w 6m";
    snapshot_dir = ".snapshots";
    lockfile = "/var/lib/btrbk/btrbk.lock";
    volume = lib.mapAttrs' (name: path: lib.nameValuePair path {
      subvolume.".".snapshot_name = name;
    }) sources;
  };

  withTargets = common // {
    volume = lib.mapAttrs' (name: path: lib.nameValuePair path {
      subvolume.".".snapshot_name = name;
      target."${targetRoot}/${name}" = { };
    }) sources;
  };
in
{
  services.btrbk = {
    ioSchedulingClass = "idle";
    instances.hourly = {
      onCalendar = "hourly";
      snapshotOnly = true;
      settings = common;
    };
    instances.daily = {
      # Off the hour so it never queues behind the hourly snapshot's lock.
      onCalendar = "*-*-* 03:30:00";
      settings = withTargets;
    };
  };

  systemd.tmpfiles.rules = lib.mapAttrsToList (_: path: "d ${path}/.snapshots 0750 btrbk btrbk -") sources;

  # /mnt/backup is nofail: without the mount, mkdir would fill the root disk
  # and btrbk would send into it, so the unit must require the mount.
  systemd.services.btrbk-daily = {
    unitConfig.RequiresMountsFor = "/mnt/backup";
    # Page cache from the multi-GB send is charged to this cgroup (17 GB peak seen).
    serviceConfig.MemoryHigh = "4G";
    serviceConfig.CPUWeight = 20;
    serviceConfig.ExecStartPre = let dirs = lib.concatMapStringsSep " " (n: "${targetRoot}/${n}") (lib.attrNames sources);
    in [
      "+${pkgs.coreutils}/bin/mkdir -p ${dirs}"
      "+${pkgs.coreutils}/bin/chown btrbk:btrbk ${targetRoot} ${dirs}"
    ];
  };
}
