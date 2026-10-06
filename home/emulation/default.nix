{ pkgs, ... }:
let
  emu = import ../../pkgs/emulator-overrides.nix { inherit pkgs; };
in
{
  # Emulator + Pegasus library setup for prepko's niri session on desktop
  # (home/pegasus). Split out from home/pegasus itself so it can still be
  # shared if another account ever needs the same library — desktop
  # previously also had a dedicated `retro` kiosk account importing this,
  # retired since Pegasus is just launched directly from niri now.
  home.packages = with pkgs; [
    pegasus-frontend

    # Standalone emulators
    dolphin-emu
    # pcsx2/rpcs3 ffmpeg_7 pin — shared with hosts/desktop/config.nix's
    # Pegasus launch commands via pkgs/emulator-overrides.nix so the two
    # can't drift. See that file for the why.
    emu.pcsx2
    ppsspp
    emu.rpcs3
    cemu
    xemu
    azahar
    eden

    # RetroArch cores (each ships its own retroarch-<core> launcher binary)
    libretro.nestopia
    libretro.bsnes
    libretro.genesis-plus-gx
    libretro.mgba
    libretro.beetle-psx
    libretro.mupen64plus
    libretro.yabause
    libretro.flycast
  ];

  # Tells Pegasus where to look for collections. This build of Pegasus does
  # NOT recurse into subdirectories looking for metadata.pegasus.txt — each
  # system directory must be listed explicitly, or its games are silently
  # never found. Keep this list in sync with retroSystems in
  # hosts/desktop/config.nix.
  # `libretro.<core>` launchers are `retroarch-bare` (no bundled assets) with
  # no autoconfig dir wired in — joypad_autoconfig_dir is unset by default,
  # so RetroArch never autoconfigures ANY controller: it shows as "connected"
  # in the input menu but zero buttons/axes are bound. Point it at the
  # nixpkgs autoconfig profile set (has a "Wireless Controller" / VID 054C
  # PID 09CC entry for the DS4) so RetroArch's udev joypad driver can match
  # and bind it like the full `retroarch` package would out of the box.
  # config_save_on_exit = "false" is load-bearing: RetroArch's default is
  # "true", which rewrites this ENTIRE file on every quit — turning the
  # home-manager symlink into a plain writable file and silently reverting
  # joypad_autoconfig_dir back to RetroArch's own default, undoing the fix.
  # video_fullscreen pinned explicitly (rather than left to upstream's
  # default) so every RetroArch core opens windowed — niri's own
  # window-rule (home/niri/config.kdl.nix, app-id "com.libretro.RetroArch")
  # then maximizes it. Exclusive fullscreen on this box coincides with the
  # Bluetooth adapter dropping its connected device.
  # savefile_directory points every account at the shared NFS-backed save
  # store (docs/superpowers/specs/2026-08-29-shared-retroarch-saves-design.md);
  # savestates stay local.
  xdg.configFile."retroarch/retroarch.cfg" = {
    force = true;
    text = ''
      joypad_autoconfig_dir = "${pkgs.retroarch-joypad-autoconfig}/share/libretro/autoconfig"
      config_save_on_exit = "false"
      video_fullscreen = "false"
      savefile_directory = "/srv/game-saves"
    '';
  };

  # Mupen64Plus-Next ships no nix-pinned defaults, so RetroArch writes this
  # file itself on first N64 launch using whatever upstream currently
  # defaults to. cpucore defaulting to an interpreter instead of the JIT, or
  # rdp-plugin defaulting to the software-only "angrylion" renderer, both
  # produce single-digit framerates on hardware that should have no trouble
  # at all — pin the fast path explicitly so it can't silently regress.
  # force = true for the same reason as retroarch.cfg above: RetroArch
  # rewrites this file the moment a core option is changed from the Quick
  # Menu, which would otherwise turn the home-manager symlink into a plain
  # file and detach it from nix.
  xdg.configFile."retroarch/config/Mupen64Plus-Next/Mupen64Plus-Next.opt" = {
    force = true;
    text = ''
      mupen64plus-cpucore = "dynamic_recompiler"
      mupen64plus-rdp-plugin = "gliden64"
      mupen64plus-rsp-plugin = "hle"
    '';
  };

  # Dolphin is a standalone emulator, not a RetroArch core, so the
  # joypad_autoconfig_dir fix above doesn't reach it — it needs its own
  # controller binding file. This machine already had a live, hand-set
  # GCPadNew.ini (never Nix-managed) binding GCPad1 to keyboard keys, plus
  # `Triforce/Test`/`Service`/`Coin` — origin unconfirmed (possibly Dolphin's
  # own stock first-run default, since it auto-generates keyboard + Triforce
  # bindings on first launch; Phil doesn't recall setting it up manually).
  # Preserved byte-for-byte here rather than risk breaking a Triforce arcade
  # setup nobody remembers configuring. Each binding below is the original
  # keyboard control OR'd (`|`) with a fully-qualified reference to the DS4
  # (Dolphin's expression parser allows binding an input from a device other
  # than GCPad1's default `Device =` line via `DeviceString:ControlName`),
  # so both keyboard and pad keep working side by side. DS4 side uses SDL's
  # cross-platform button naming (`Button A`/`Shoulder R`/`Left X+`/etc.),
  # the same scheme Dolphin's own bundled "SDL Gamepad.ini" profile uses,
  # mapped onto GameCube buttons: Cross/Circle/Square/Triangle -> A/B/X/Y,
  # R1 -> Z (GC has no 6th face button), L2/R2 -> L/R triggers, sticks ->
  # Main/C-Stick, Options -> Start.
  # force = true defensively, same reasoning as retroarch.cfg above: Dolphin
  # rewrites this file when the Controllers dialog is touched, which would
  # detach the home-manager symlink.
  #
  # The device string is `PS4 Controller`, NOT `Wireless Controller`. Those
  # are two different subsystems naming the same pad: "Wireless Controller"
  # is the udev/evdev name (correct for the RetroArch autoconfig above and
  # for controller-home.nix), but SDL's GameController layer renames known
  # PS4 pads to "PS4 Controller", and Dolphin resolves `SDL/…` expressions
  # through SDL. An earlier revision guessed the evdev name here, so every
  # qualified binding pointed at a device that does not exist and the pad
  # was silently dead in Dolphin. Verified two ways: SDL2's
  # SDL_GameControllerNameForIndex(0) returns "PS4 Controller", and Dolphin
  # itself rewrote GCPad1's `Device =` line to `SDL/0/PS4 Controller` when
  # the Controllers dialog was opened.
  xdg.configFile."dolphin-emu/GCPadNew.ini" = {
    force = true;
    text = ''
      [GCPad1]
      Device = XInput2/0/Virtual core pointer
      Buttons/A = `X` | `SDL/0/PS4 Controller:Button A`
      Buttons/B = `Z` | `SDL/0/PS4 Controller:Button B`
      Buttons/X = `C` | `SDL/0/PS4 Controller:Button X`
      Buttons/Y = `S` | `SDL/0/PS4 Controller:Button Y`
      Buttons/Z = `D` | `SDL/0/PS4 Controller:Shoulder R`
      Buttons/Start = `Return` | `SDL/0/PS4 Controller:Start`
      Main Stick/Up = `Up` | `SDL/0/PS4 Controller:Left Y+`
      Main Stick/Down = `Down` | `SDL/0/PS4 Controller:Left Y-`
      Main Stick/Left = `Left` | `SDL/0/PS4 Controller:Left X-`
      Main Stick/Right = `Right` | `SDL/0/PS4 Controller:Left X+`
      Main Stick/Modifier = `Shift`
      Main Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      C-Stick/Up = `I` | `SDL/0/PS4 Controller:Right Y+`
      C-Stick/Down = `K` | `SDL/0/PS4 Controller:Right Y-`
      C-Stick/Left = `J` | `SDL/0/PS4 Controller:Right X-`
      C-Stick/Right = `L` | `SDL/0/PS4 Controller:Right X+`
      C-Stick/Modifier = `Ctrl`
      C-Stick/Calibration = 100.00 141.42 100.00 141.42 100.00 141.42 100.00 141.42
      Triggers/L = `Q` | `SDL/0/PS4 Controller:Trigger L`
      Triggers/R = `W` | `SDL/0/PS4 Controller:Trigger R`
      Triggers/L-Analog = `SDL/0/PS4 Controller:Trigger L`
      Triggers/R-Analog = `SDL/0/PS4 Controller:Trigger R`
      D-Pad/Up = `T` | `SDL/0/PS4 Controller:Pad N`
      D-Pad/Down = `G` | `SDL/0/PS4 Controller:Pad S`
      D-Pad/Left = `F` | `SDL/0/PS4 Controller:Pad W`
      D-Pad/Right = `H` | `SDL/0/PS4 Controller:Pad E`
      Triforce/Test = `1`
      Triforce/Service = `2`
      Triforce/Coin = `3`
      [GCPad2]
      Device = XInput2/0/Virtual core pointer
      [GCPad3]
      Device = XInput2/0/Virtual core pointer
      [GCPad4]
      Device = XInput2/0/Virtual core pointer
    '';
  };

  xdg.configFile."pegasus-frontend/game_dirs.txt".text = ''
    /srv/roms/nes
    /srv/roms/snes
    /srv/roms/genesis
    /srv/roms/gba
    /srv/roms/psx
    /srv/roms/n64
    /srv/roms/saturn
    /srv/roms/gamecube-wii
    /srv/roms/ps2
    /srv/roms/psp
    /srv/roms/ps3
    /srv/roms/wiiu
    /srv/roms/xbox
    /srv/roms/3ds
    /srv/roms/switch
    /srv/roms/dreamcast
  '';
}
