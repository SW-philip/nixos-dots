{ lib
, stdenvNoCC
, python3
, gtk4
, gtk4-layer-shell
, gobject-introspection
, wrapGAppsHook4
, makeWrapper
}:

let
  pythonEnv = python3.withPackages (ps: with ps; [ pygobject3 pycairo pytest ]);
in
stdenvNoCC.mkDerivation {
  pname = "lix-logout";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection makeWrapper ];
  # gtk4 + gtk4-layer-shell in buildInputs so wrapGAppsHook4 auto-adds their
  # typelibs (Gtk-4.0, Gtk4LayerShell-1.0) to GI_TYPELIB_PATH.
  buildInputs = [ gtk4 gtk4-layer-shell pythonEnv ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m pytest tests -q
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/${python3.sitePackages}" "$out/bin"
    cp -r lix_logout "$out/${python3.sitePackages}/"

    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/lix-logout" \
      --add-flags "-m lix_logout" \
      --prefix PYTHONPATH : "$out/${python3.sitePackages}"

    install -Dm755 lix-logout-toggle "$out/bin/lix-logout-toggle"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Themed GTK4 logout/power popup";
    platforms = platforms.linux;
    mainProgram = "lix-logout";
  };
}
