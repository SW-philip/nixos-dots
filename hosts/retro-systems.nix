# One entry per emulated system; `dir` becomes /srv/roms/<dir>. The full
# (desktop) list lives here; surface imports it and filters to the subset
# its Intel iGPU can actually run (hosts/surface/config.nix). Keeping one
# ordered definition is what stops the two host copies from drifting.
{ pkgs }:
let
  emu = import ../pkgs/emulator-overrides.nix { inherit pkgs; };
in
[
  { dir = "nes";     collection = "Nintendo Entertainment System"; shortname = "nes";     extensions = "nes, fds, unf, unif"; launch = ''${pkgs.libretro.nestopia}/bin/retroarch-nestopia "{file.path}"''; }
  { dir = "snes";    collection = "Super Nintendo Entertainment System"; shortname = "snes"; extensions = "sfc, smc, swc, fig"; launch = ''${pkgs.libretro.bsnes}/bin/retroarch-bsnes "{file.path}"''; }
  { dir = "genesis"; collection = "Sega Genesis"; shortname = "genesis"; extensions = "md, bin, gen, smd"; launch = ''${pkgs.libretro.genesis-plus-gx}/bin/retroarch-genesis-plus-gx "{file.path}"''; }
  { dir = "gba";     collection = "Game Boy Advance"; shortname = "gba"; extensions = "gba";           launch = ''${pkgs.libretro.mgba}/bin/retroarch-mgba "{file.path}"''; }
  { dir = "psx";     collection = "PlayStation"; shortname = "psx"; extensions = "cue, chd, pbp, exe, toc, ccd, m3u"; launch = ''${pkgs.libretro.beetle-psx}/bin/retroarch-mednafen-psx "{file.path}"''; }
  { dir = "n64";     collection = "Nintendo 64"; shortname = "n64"; extensions = "n64, z64, v64, bin, u1"; launch = ''${pkgs.libretro.mupen64plus}/bin/retroarch-mupen64plus-next "{file.path}"''; }
  { dir = "saturn";  collection = "Sega Saturn"; shortname = "saturn"; extensions = "cue, chd, iso, mds, ccd, zip, m3u"; launch = ''${pkgs.libretro.yabause}/bin/retroarch-yabause "{file.path}"''; }
  { dir = "gamecube-wii"; collection = "GameCube / Wii"; shortname = "gcwii"; extensions = "iso, rvz, wbfs, ciso, gcz, wia, tgc, gcm"; launch = ''${pkgs.dolphin-emu}/bin/dolphin-emu -b -e "{file.path}"''; }
  { dir = "ps2";     collection = "PlayStation 2"; shortname = "ps2"; extensions = "iso, bin, chd, cue, cso, mdf, nrg, gz"; launch = ''${emu.pcsx2}/bin/pcsx2-qt -batch "{file.path}"''; }
  { dir = "psp";     collection = "PlayStation Portable"; shortname = "psp"; extensions = "iso, cso, pbp, chd"; launch = ''${pkgs.ppsspp}/bin/ppsspp "{file.path}"''; }
  # PS3: RPCS3 games are a directory tree (PS3_GAME/USRDIR/EBOOT.BIN +
  # sibling folders), not a single file. `extensions: BIN` would match every
  # .bin under the tree (save data, audio banks, etc, not just the game) —
  # `regex` matches on relative path instead, so anchor on the exact
  # executable name.
  { dir = "ps3";     collection = "PlayStation 3"; shortname = "ps3"; regex = ''EBOOT\.BIN$'';         launch = ''${emu.rpcs3}/bin/rpcs3 --no-gui "{file.path}"''; }
  { dir = "wiiu";    collection = "Wii U"; shortname = "wiiu"; extensions = "wux, rpx, iso, wud, wua"; launch = ''${pkgs.cemu}/bin/cemu -g "{file.path}"''; }
  # -full-screen/-f dropped: exclusive fullscreen (not niri's own
  # maximize) on this box coincides with the Bluetooth adapter dropping
  # its connected device — see home/niri/config.kdl.nix's emulator
  # window-rules, which maximize these instead.
  { dir = "xbox";    collection = "Xbox"; shortname = "xbox"; extensions = "iso";                     launch = ''${pkgs.xemu}/bin/xemu -dvd_path "{file.path}"''; }
  { dir = "3ds";     collection = "Nintendo 3DS"; shortname = "n3ds"; extensions = "3ds, cia, cci, cxi, 3dsx"; launch = ''${pkgs.azahar}/bin/azahar "{file.path}"''; }
  { dir = "switch";  collection = "Nintendo Switch"; shortname = "switch"; extensions = "nsp, xci, nro, nso"; launch = ''${pkgs.eden}/bin/eden "{file.path}"''; }
  { dir = "dreamcast"; collection = "Sega Dreamcast"; shortname = "dreamcast"; extensions = "chd, gdi, cdi, cue, elf"; launch = ''${pkgs.libretro.flycast}/bin/retroarch-flycast "{file.path}"''; }
]
