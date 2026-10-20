# azahar 2125.1.3's cubeb_sink.cpp/cubeb_input.cpp call std::memset /
# std::memcpy but never #include <cstring> directly -- they relied on
# it arriving transitively through another standard header. GCC 15
# (this system's stdenv.cc) tightened libstdc++'s transitive includes,
# so the build now fails with "'memset' is not a member of 'std'".
# drop when: azahar includes <cstring> itself in those two files.
{ ... }:
final: prev: {
  azahar = prev.azahar.overrideAttrs (old: {
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
