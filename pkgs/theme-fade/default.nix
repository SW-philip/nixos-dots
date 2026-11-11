{ lib, stdenvNoCC, python3, gtk4, gtk4-layer-shell, gobject-introspection, wrapGAppsHook4 }:

let
  pythonEnv = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "theme-fade";
  version = "0.1.0";
  src = ./.;
  dontUnpack = true;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection ];
  buildInputs = [ gtk4 gtk4-layer-shell pythonEnv ];

  # re-execs itself as `overlay`, so sys.argv[0] must be the wrapped bin
  installPhase = ''
    install -Dm755 $src/theme-fade.py $out/bin/theme-fade
    substituteInPlace $out/bin/theme-fade \
      --replace-fail '#!/usr/bin/env python3' '#!${pythonEnv}/bin/python3'
  '';

  # gtk4-layer-shell must load before libwayland-client or init_for_window silently no-ops
  preFixup = ''
    gappsWrapperArgs+=(--prefix LD_PRELOAD : ${gtk4-layer-shell}/lib/libgtk4-layer-shell.so)
  '';

  meta.mainProgram = "theme-fade";
}
