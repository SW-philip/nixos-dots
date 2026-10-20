# pcsx2 2.6.3's GSCapture.cpp and rpcs3's recording_settings_dialog.cpp
# still read AVCodec.{pix_fmts,sample_fmts} directly, fields FFmpeg's
# default 8.x line dropped in favor of avcodec_get_supported_config().
# Pin their linked ffmpeg back to the 7.1 branch (last one with the
# fields, deprecated-but-present).
# NOTE: nixpkgs renamed pcsx2's ffmpeg arg to `ffmpeg_8` (was `ffmpeg`).
# drop when: pcsx2 and rpcs3 build against ffmpeg 8.
{ ... }:
final: prev: {
  pcsx2 = prev.pcsx2.override { ffmpeg_8 = prev.ffmpeg_7; };
  rpcs3 = prev.rpcs3.override { ffmpeg = prev.ffmpeg_7; };
}
