{ config, osConfig ? null, lib, ... }:
let
  inventory = import ../hosts/inventory.nix;
in
{
  options.myConfig.isDesktop = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this is the desktop (dual monitor) profile.";
  };

  # Capability flags derived from isDesktop. Call sites should ask for the
  # capability they mean, not the hostname; a profile can override any of them.
  options.myConfig = {
    hasTouch = lib.mkOption {
      type = lib.types.bool;
      default = !config.myConfig.isDesktop;
      description = "Touchscreen/tablet host: OSK, tablet shell, 3-finger-tap middle-click, ambient backlight.";
    };
    lowMemory = lib.mkOption {
      type = lib.types.bool;
      default = !config.myConfig.isDesktop;
      description = "Memory-constrained host (8 GB): gates Firefox pref trimming and other resident-set savers.";
    };
    onBattery = lib.mkOption {
      type = lib.types.bool;
      default = if osConfig != null then osConfig.myConfig.onBattery else !config.myConfig.isDesktop;
      description = "Portable host: battery widgets, slower polling, bluetooth gadget modules.";
    };
    hasBacklight = lib.mkOption {
      type = lib.types.bool;
      default = !config.myConfig.isDesktop;
      description = "Internal panel with a backlight (brightnessctl); otherwise monitors dim over DDC.";
    };
    hiDpi = lib.mkOption {
      type = lib.types.bool;
      default = if osConfig != null then osConfig.myConfig.hiDpi else !config.myConfig.isDesktop;
      description = "Fractional-scale high-DPI panel: larger cursor, doubled lock-screen metrics.";
    };
    nick = lib.mkOption {
      type = lib.types.str;
      default = inventory.${config.myConfig.self}.nick;
      description = "networking.hostName of this machine (hosts/inventory.nix).";
    };
    self = lib.mkOption {
      type = lib.types.str;
      default = if config.myConfig.isDesktop then "desktop" else "surface";
      description = "Short name of this machine, as used in ssh aliases and fleet tooling.";
    };
    peer = lib.mkOption {
      type = lib.types.str;
      default = if config.myConfig.isDesktop then "surface" else "desktop";
      description = "Short name of the other machine two-way sync tooling talks to.";
    };
  };

  options.waybar.allBars = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = if config.myConfig.isDesktop then [ "leftBar" "rightBar" "tvTopBar" ] else [ "surfaceTopBar" ];
    description = "Every bar that exists on this host; for modules that appear on all of them.";
  };

  options.waybar.primaryBar = lib.mkOption {
    type = lib.types.str;
    default = if config.myConfig.isDesktop then "leftBar" else "surfaceTopBar";
    description = "Bar that hosts the main status modules (volume, sync, fleet, sqlch, ...).";
  };
  options.waybar.secondaryBar = lib.mkOption {
    type = lib.types.str;
    default = if config.myConfig.isDesktop then "rightBar" else "surfaceTopBar";
    description = "Bar for clock/weather; same as primaryBar on single-bar hosts.";
  };

  options.waybar.barName = lib.mkOption {
    type = lib.types.str;
    default = "";
    description = "Override the waybar bar name for all modules. Empty = use per-module defaults.";
  };

  options.myConfig.sidebarToggleScript = lib.mkOption {
    type = lib.types.package;
    description = "Script that toggles the swaync control center (defined in home/niri/default.nix as `sidebarToggleBin`); shared so other modules (e.g. the TV-bar hamburger) invoke the same toggle as the Mod+B keybind.";
  };

  options.myConfig.drmisBin = lib.mkOption {
    type = lib.types.str;
    description = "Path to the drmis binary, for units that run drmis subcommands.";
  };

  options.myConfig.lockScreenScript = lib.mkOption {
    type = lib.types.package;
    description = "Script that locks the screen (defined in home/niri/default.nix as `lockScreenBin`): picks a random snark line into a throwaway copy of the deployed hyprlock.conf and execs hyprlock against it, falling back to plain hyprlock on any failure. Shared so profiles/base.nix's hypridle lock_cmd/listener use the same launcher as the Mod+Escape keybind.";
  };
}
