{ lib, stdenvNoCC, python3, gtk4, gtk4-layer-shell, gobject-introspection
, librsvg, wrapGAppsHook4, makeWrapper, writeText
, nixFlakeSvg ? ../../assets/nix/nix-flake.svg }:
let
  pythonEnv = python3.withPackages (ps: with ps; [ pygobject3 pycairo pytest ]);
  snarkLinesFile = writeText "greeter-snark-lines.txt" (builtins.readFile ../../assets/snark-lines.txt);
in
stdenvNoCC.mkDerivation {
  pname = "greeter";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection makeWrapper ];
  # librsvg supplies the gdk-pixbuf SVG loader the nix-flake mark needs at
  # runtime; wrapGAppsHook4 then wires GDK_PIXBUF_MODULE_FILE.
  buildInputs = [ gtk4 gtk4-layer-shell librsvg pythonEnv ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m pytest tests -q -k "not app"
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/${python3.sitePackages}" "$out/bin"
    cp -r greeter "$out/${python3.sitePackages}/"
    install -Dm444 ${nixFlakeSvg} \
      "$out/${python3.sitePackages}/greeter/assets/nix-flake.svg"
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/greeter" \
      --add-flags "-m greeter" \
      --prefix PYTHONPATH : "$out/${python3.sitePackages}"
    runHook postInstall
  '';

  # greetd's session inherits a restricted PATH; ensure cage/systemctl resolve.
  preFixup = ''
    gappsWrapperArgs+=( --prefix PATH : "/run/current-system/sw/bin" )
    gappsWrapperArgs+=( --set GREETER_SNARK_FILE "${snarkLinesFile}" )
  '';

  meta = with lib; {
    description = "Custom GTK4 greetd greeter — flat, theme-following or DSA preset";
    platforms = platforms.linux;
    mainProgram = "greeter";
  };
}
