# GCC 16 defaults to -std=gnu++20, where pegasus's MOVE_ONLY types
# (user-declared ctors) are no longer aggregates, so the brace-init in
# MetaFile.cpp stops compiling. Pin C++17 only on the toolchains that
# need it so the 26.05 (GCC 15) surface build keeps its cached output.
# drop when: pegasus-frontend builds under GCC 16 without the flag.
{ ... }:
final: prev: {
  pegasus-frontend = if prev.lib.versionAtLeast prev.stdenv.cc.version "16"
    then prev.pegasus-frontend.overrideAttrs (old: {
      cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
    })
    else prev.pegasus-frontend;
}
