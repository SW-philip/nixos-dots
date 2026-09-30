{ lib, stdenvNoCC, python3, resvg, fetchurl }:

let
  pythonEnv = python3.withPackages (ps: with ps; [ pycairo pytest ]);
  antonFont = fetchurl {
    url = "https://github.com/google/fonts/raw/main/ofl/anton/Anton-Regular.ttf";
    sha256 = "sha256-pLo6kjUOuwMdoMtHYwrEnrJlCCyhvARQRC9Kg6uUfKs=";
  };
in
stdenvNoCC.mkDerivation {
  pname = "plymouth-dsa-rose";
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
    mkdir -p layers frames/rays frames/medallion

    # fist+rose icon, rasterised at the working icon width
    resvg -w $(python render.py icon-width) dsa.svg layers/icon.png

    # "DSA" wordmark: rasterised with the vendored Anton font. --skip-system-fonts
    # + an explicit --use-font-file keeps this deterministic in the build
    # sandbox (no fontconfig scan, no dependency on host-installed fonts).
    cat > layers/text.svg <<SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="400" height="90">
    <text x="200" y="70" font-family="Anton" font-size="60" fill="#f0e9d8"
          text-anchor="middle" letter-spacing="8">DSA</text>
    </svg>
    SVG
    resvg --use-font-file ${antonFont} --skip-system-fonts \
      -w $(python render.py text-width) layers/text.svg layers/text.png

    python render.py background frames/background.png
    python render.py sunburst frames/rays
    python render.py medallion layers/icon.png layers/text.png frames/medallion
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    theme="$out/share/plymouth/themes/dsa-rose"
    mkdir -p "$theme"
    cp frames/background.png "$theme/"
    cp frames/rays/*.png "$theme/"
    cp frames/medallion/*.png "$theme/"
    cp dsa-rose.plymouth "$theme/"
    substitute dsa-rose.script "$theme/dsa-rose.script" \
      --replace-fail '@RAY_FRAME_COUNT@' "$(ls frames/rays/*.png | wc -l)" \
      --replace-fail '@MEDALLION_FRAME_COUNT@' "$(ls frames/medallion/*.png | wc -l)"
    runHook postInstall
  '';

  meta = with lib; {
    description = "DSA rose sunburst Plymouth boot splash, WPA/New Left poster style";
    platforms = platforms.linux;
  };
}
