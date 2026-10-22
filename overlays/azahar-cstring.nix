# azahar 2125.1.3's cubeb_sink.cpp/cubeb_input.cpp call std::memset /
# std::memcpy but never #include <cstring> directly -- they relied on
# it arriving transitively through another standard header. GCC 15
# (this system's stdenv.cc) tightened libstdc++'s transitive includes,
# so the build now fails with "'memset' is not a member of 'std'".
# unstable (26.11pre sorts below 26.11, so gate at 26.10) already ships the
# include; only stable's 2125.x needs the patch.
# drop when: stable's azahar includes <cstring> itself in those two files.
{ ... }:
final: prev: {
  azahar = if prev.lib.versionAtLeast prev.lib.version "26.10" then prev.azahar
  else prev.azahar.overrideAttrs (old: {
    postPatch = (old.postPatch or "") + ''
      substituteInPlace src/audio_core/cubeb_sink.cpp \
        --replace-fail '#include <cubeb/cubeb.h>' \
                       '#include <cstring>
      #include <cubeb/cubeb.h>'
      substituteInPlace src/audio_core/cubeb_input.cpp \
        --replace-fail '#include <cubeb/cubeb.h>' \
                       '#include <cstring>
      #include <cubeb/cubeb.h>'
    '';
  });
}
