# GCC 16 defaults to -std=gnu++20, where pegasus's MOVE_ONLY types
# (user-declared ctors) are no longer aggregates, so the brace-init in
# MetaFile.cpp stops compiling. Pin C++17.
# drop when: pegasus-frontend builds under GCC 16 without the flag.
{ ... }:
_final: prev: {
  pegasus-frontend = prev.pegasus-frontend.overrideAttrs (old: {
    cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
  });
}
