{ lib, stdenvNoCC, python3, gtk4, libadwaita, gobject-introspection
, wrapGAppsHook4, makeWrapper
, setDefaultSink ? "", setWaybarMode ? "", tvCriteria ? ""
, hdmiSink ? "", spdifSink ? "", isDesktop ? true }:
let
  pythonEnv = python3.withPackages (ps: with ps; [ pygobject3 pycairo pytest ]);
in
stdenvNoCC.mkDerivation {
  pname = "niri-panel";
  version = "0.1.0";
  src = ./.;

  nativeBuildInputs = [ wrapGAppsHook4 gobject-introspection makeWrapper ];
  buildInputs = [ gtk4 libadwaita pythonEnv ];

  postPatch = ''
    substituteInPlace niri_panel/config.py \
      --replace '@SET_DEFAULT_SINK@' '${setDefaultSink}' \
      --replace '@SET_WAYBAR_MODE@'  '${setWaybarMode}' \
      --replace '@TV_CRITERIA@'      '${tvCriteria}' \
      --replace '@HDMI_SINK@'        '${hdmiSink}' \
      --replace '@SPDIF_SINK@'       '${spdifSink}' \
      --replace '@IS_DESKTOP@'       '${lib.boolToString isDesktop}'
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    python -m pytest tests -q
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    mkdir -p "$out/${python3.sitePackages}" "$out/bin"
    cp -r niri_panel "$out/${python3.sitePackages}/"
    makeWrapper ${pythonEnv}/bin/python3 "$out/bin/niri-panel" \
      --add-flags "-m niri_panel" \
      --prefix PYTHONPATH : "$out/${python3.sitePackages}"
    runHook postInstall
  '';

  preFixup = ''
    gappsWrapperArgs+=( --prefix PATH : "/run/current-system/sw/bin" )
  '';

  meta = with lib; {
    description = "niri display + drmis theme quick panel";
    platforms = platforms.linux;
    mainProgram = "niri-panel";
  };
}
