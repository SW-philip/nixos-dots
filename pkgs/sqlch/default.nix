{ lib, pkgs, python3Packages, src }:

python3Packages.buildPythonApplication {
  pname = "sqlch";
  version = "0.2.0";

  inherit src;

  pyproject = true;

  nativeBuildInputs = with python3Packages; [
    setuptools
    wheel
    pygobject3
    pkgs.gobject-introspection
  ];

  propagatedBuildInputs = with python3Packages; [
    requests
    textual
    pygobject3
    pydbus
  ];

  buildInputs = [
    pkgs.mpv
    pkgs.procps
    pkgs.mpvScripts.mpris
  ];

  postFixup = ''
    wrapProgram $out/bin/sqlch \
      --set MPV_BIN ${pkgs.mpv}/bin/mpv \
      --set SQLCH_MPRIS_PLUGIN ${pkgs.mpvScripts.mpris}/share/mpv/scripts/mpris.so
  '';

  pythonImportsCheck = [
    "sqlch"
    "sqlch.cli.main"
    "sqlch.tui.app"
  ];

  doCheck = false;

  meta = with lib; {
    description = "Headless radio + TUI streaming controller";
    license = licenses.mit;
    platforms = platforms.linux;
  };
}
