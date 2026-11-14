pkgs: pkgs.python3.withPackages (ps: with ps; [
  pygobject3 textual rich pystray pillow pydbus cairosvg
  requests watchdog python-dateutil
  loguru platformdirs attrs typing-extensions
  build setuptools wheel pyyaml
])
