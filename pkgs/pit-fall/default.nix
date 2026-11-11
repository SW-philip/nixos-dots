{ lib, stdenvNoCC, python3, gtk4, gtk4-layer-shell, gobject-introspection, wrapGAppsHook4, niri }:

let
  pythonEnv = python3.withPackages (ps: [ ps.pygobject3 ]);
in
stdenvNoCC.mkDerivation {
  pname = "pit-fall";
  version = "0.1.0";
  src = ./.;
  dontUnpack = true;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection ];
  buildInputs = [ gtk4 gtk4-layer-shell pythonEnv ];

  installPhase = ''
    install -Dm755 $src/pit-fall.py $out/bin/pit-fall
    substituteInPlace $out/bin/pit-fall \
      --replace-fail '#!/usr/bin/env python3' '#!${pythonEnv}/bin/python3'
  '';

  # gtk4-layer-shell must load before libwayland-client or init_for_window silently no-ops
  preFixup = ''
    gappsWrapperArgs+=(--prefix LD_PRELOAD : ${gtk4-layer-shell}/lib/libgtk4-layer-shell.so)
    # follows the overview through `niri msg event-stream`
    gappsWrapperArgs+=(--prefix PATH : ${lib.makeBinPath [ niri ]})
  '';

  meta.mainProgram = "pit-fall";
}
