{ lib, stdenvNoCC, python3, resvg }:

let
  pythonEnv = python3.withPackages (ps: with ps; [ pycairo pytest ]);
in
stdenvNoCC.mkDerivation {
  pname = "plymouth-lix-icecream";
  version = "1.0";
  src = ./.;

  nativeBuildInputs = [ pythonEnv resvg ];

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m pytest tests -q
    runHook postCheck
  '';

  buildPhase = ''
    runHook preBuild
    mkdir -p frames layers
    # The wallpaper logo (cone + swirl) is what comes down; rasterise it whole.
    resvg -w 720 cone.svg layers/logo.png
    # Carve the Nix snowflake out of the brand logo for the machine badge.
    python render.py snowflake nixos-logo.svg layers/flake.svg
    resvg -w 4000 layers/flake.svg layers/flake.png
    python render.py compose frames layers/logo.png layers/flake.png
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    theme="$out/share/plymouth/themes/lix-icecream"
    mkdir -p "$theme"
    cp frames/*.png "$theme/"
    cp lix-icecream.plymouth "$theme/"
    substitute lix-icecream.script "$theme/lix-icecream.script" \
      --replace-fail '@FRAME_COUNT@' "$(ls frames/*.png | wc -l)"
    runHook postInstall
  '';

  meta = with lib; {
    description = "Animated soft-serve Plymouth boot splash in Lix colors";
    platforms = platforms.linux;
  };
}
