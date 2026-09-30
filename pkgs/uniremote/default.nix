{ lib, python3Packages, gtk4, libadwaita, adwaita-icon-theme, gobject-introspection, wrapGAppsHook3
, makeDesktopItem, copyDesktopItems }:

python3Packages.buildPythonApplication {
  pname = "uniremote";
  version = "0.1.0";

  src = ./.;
  pyproject = true;

  nativeBuildInputs = with python3Packages; [
    setuptools
    wheel
    wrapGAppsHook3
    gobject-introspection
  ] ++ [ copyDesktopItems ];

  propagatedBuildInputs = with python3Packages; [
    pygobject3
    requests
  ];

  buildInputs = [ gtk4 libadwaita adwaita-icon-theme ];

  # wrapGAppsHook3 only wires the package's own share/ + gsettings schemas into
  # XDG_DATA_DIRS; the icon theme's share/ has to be added by hand or GTK falls
  # back to the ambient session theme (or nothing, on a lean session).
  preFixup = ''
    gappsWrapperArgs+=(--prefix XDG_DATA_DIRS : "${adwaita-icon-theme}/share")
  '';

  nativeCheckInputs = with python3Packages; [
    pytestCheckHook
    requests-mock
  ];

  desktopItems = [
    (makeDesktopItem {
      name = "uniremote";
      desktopName = "Uniremote";
      exec = "uniremote";
      icon = "tv-symbolic";
      startupWMClass = "com.prepko.uniremote";
      categories = [ "AudioVideo" ];
    })
  ];

  pythonImportsCheck = [
    "uniremote"
    "uniremote.widgets"
    "uniremote.views.samsung"
    "uniremote.views.roku"
    "uniremote.preferences"
    "uniremote.status"
    "uniremote.tablet"
    "uniremote.header"
    "uniremote.app"
  ];

  meta = with lib; {
    description = "GTK4 + libadwaita Roku/Samsung remote";
    platforms = platforms.linux;
  };
}
