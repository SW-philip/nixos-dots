{ pkgs, ... }:
let
  # one directory so quivr.py finds its sibling modules and sampler scripts
  src = pkgs.runCommand "quivr-src" { } ''
    mkdir -p $out
    cp ${../scripts/quivr.py} $out/quivr.py
    cp ${../scripts/quivr_view.py} $out/quivr_view.py
    cp ${../scripts/quivr_detail.py} $out/quivr_detail.py
    cp ${../scripts/quivr-sampler.sh} $out/quivr-sampler.sh
    cp ${../scripts/quivr-detail.sh} $out/quivr-detail.sh
  '';
  quivr = pkgs.writeShellScriptBin "quivr" ''
    exec ${pkgs.python3}/bin/python3 ${src}/quivr.py "$@"
  '';
in
{
  home.packages = [ quivr ];
}
