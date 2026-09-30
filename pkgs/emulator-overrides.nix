{ pkgs }:
{
  # pcsx2 2.6.3's GSCapture.cpp and rpcs3's recording_settings_dialog.cpp
  # still read AVCodec.{pix_fmts,sample_fmts} directly, fields FFmpeg's
  # default 8.x line dropped in favor of avcodec_get_supported_config().
  # Pin their linked ffmpeg back to the 7.1 branch (last one with the
  # fields, deprecated-but-present) until nixpkgs/upstream catches up.
  # NOTE: nixpkgs renamed pcsx2's ffmpeg arg to `ffmpeg_8` (was `ffmpeg`).
  # Shared by hosts/desktop/config.nix (Pegasus launch commands) and
  # home/emulation/default.nix (the installed packages) so the two can't
  # drift.
  pcsx2 = pkgs.pcsx2.override { ffmpeg_8 = pkgs.ffmpeg_7; };
  rpcs3 = pkgs.rpcs3.override { ffmpeg = pkgs.ffmpeg_7; };
}
