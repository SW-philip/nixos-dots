{ lib, ... }:
{
  options.myConfig.isDesktop = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether this is the desktop (dual monitor) profile.";
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
