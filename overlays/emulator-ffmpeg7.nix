# pcsx2 2.6.3's GSCapture.cpp and rpcs3's recording_settings_dialog.cpp
# still read AVCodec.{pix_fmts,sample_fmts} directly, fields FFmpeg's
# default 8.x line dropped in favor of avcodec_get_supported_config().
# Pin their linked ffmpeg back to the 7.1 branch (last one with the
# fields, deprecated-but-present).
# NOTE: nixpkgs renamed pcsx2's ffmpeg arg to `ffmpeg_8` (was `ffmpeg`).
# rpcs3 on unstable (26.11pre sorts below 26.11, so gate at 26.10) already
# uses avcodec_get_supported_config; only stable's rpcs3 still needs the pin.
# drop when: pcsx2 builds against ffmpeg 8 (and stable's rpcs3 is bumped).
{ ... }:
final: prev: {
  pcsx2 = prev.pcsx2.override { ffmpeg_8 = prev.ffmpeg_7; };
  rpcs3 =
    if prev.lib.versionAtLeast prev.lib.version "26.10" then prev.rpcs3
    else prev.rpcs3.override { ffmpeg = prev.ffmpeg_7; };
}
