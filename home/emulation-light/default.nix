{ pkgs, ... }:
{
  # Light emulator + Pegasus setup for the Intel-iGPU hosts, which can't run
  # the heavy standalone emulators (dolphin-emu/pcsx2/rpcs3/cemu/xemu/azahar/
  # eden) — only ppsspp + libretro cores. Imported verbatim by
  # home/pegasus-surface (prepko) and home/kid, the same "hand-cloned
  # copies silently drift" trap that home/emulation solves for the desktop /
  # retro-kiosk pair. pegasus-frontend itself is a system package on surface
  # (hosts/surface/config.nix), so it is not listed here.
  home.packages = with pkgs; [
    ppsspp
    libretro.nestopia
    libretro.bsnes
    libretro.genesis-plus-gx
    libretro.mgba
    libretro.beetle-psx
    libretro.mupen64plus
    libretro.yabause
    libretro.flycast
  ];

  # libretro.<core> launchers ship with joypad_autoconfig_dir unset, so
  # RetroArch never autoconfigures the DS4 (connects fine, zero buttons
  # bound). Also, config_save_on_exit = "false" is load-bearing —
  # RetroArch's default ("true") rewrites this whole file on quit, turning
  # the home-manager symlink into a plain file and silently reverting the fix.
  # savefile_directory points every account at the shared NFS-backed save
  # store (docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md);
  # savestates stay local.
  xdg.configFile."retroarch/retroarch.cfg" = {
    force = true;
    text = ''
      joypad_autoconfig_dir = "${pkgs.retroarch-joypad-autoconfig}/share/libretro/autoconfig"
      config_save_on_exit = "false"
      savefile_directory = "/srv/game-saves"
    '';
  };

  # Mupen64Plus-Next ships no nix-pinned defaults, so RetroArch writes this
  # file itself on first N64 launch using whatever upstream currently
  # defaults to. cpucore defaulting to an interpreter instead of the JIT, or
  # rdp-plugin defaulting to the software-only "angrylion" renderer, both
  # produce single-digit framerates — pin the fast path explicitly so it
  # can't silently regress. force = true for the same reason as
  # retroarch.cfg above: changing a core option from the Quick Menu rewrites
  # this file, which would detach the home-manager symlink from nix.
  xdg.configFile."retroarch/config/Mupen64Plus-Next/Mupen64Plus-Next.opt" = {
    force = true;
    text = ''
      mupen64plus-cpucore = "dynamic_recompiler"
      mupen64plus-rdp-plugin = "gliden64"
      mupen64plus-rsp-plugin = "hle"
    '';
  };

  # Pegasus does NOT recurse into subdirectories looking for
  # metadata.pegasus.txt — each system dir must be listed explicitly, or
  # Pegasus just logs "No metadata files found" and shows nothing. Matches
  # the light system list hosts/surface/config.nix generates metadata for.
  xdg.configFile."pegasus-frontend/game_dirs.txt".text = ''
    /srv/roms/nes
    /srv/roms/snes
    /srv/roms/genesis
    /srv/roms/gba
    /srv/roms/psx
    /srv/roms/n64
    /srv/roms/saturn
    /srv/roms/psp
    /srv/roms/dreamcast
  '';

  # Bundled default theme ("Pegasus Grid") only shows if this is
  # missing/misnamed, so pin explicitly for a consistent look.
  xdg.configFile."pegasus-frontend/themes/homage".source = pkgs.fetchFromGitHub {
    owner = "asdfgasfhsn";
    repo = "pegasus-theme-homage";
    rev = "afcf0be9ec0d2298fc69381bcb72e3dd7b46e0db";
    sha256 = "0szlnlznn5q107jfk4hyrlfc7z95ynlcdpkm7769zflprdzznplp";
  };

  # Pegasus rewrites settings.txt on exit; force = true clobbers it back on
  # every rebuild. Value must include the "themes/" prefix or Pegasus falls
  # back to default even though the theme is found.
  xdg.configFile."pegasus-frontend/settings.txt" = {
    force = true;
    text = ''
      general.theme: themes/homage
    '';
  };
}
