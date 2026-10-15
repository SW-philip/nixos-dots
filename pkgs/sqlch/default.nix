{ lib, pkgs, python3Packages, fetchFromGitHub }:

python3Packages.buildPythonApplication {
  pname = "sqlch";
  version = "0.2.0";

  src = fetchFromGitHub {
    owner = "SW-philip";
    repo  = "sqlch";
    rev   = "cdeec7e0f50aed5bf9cdb4556179b4f51a3e5c76";
    sha256 = "sha256-mJtPANXxy5Jpnqlw3ZgnMK8EZEM0PrCNO6kEv4QI0RA=";
  };

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
