{ stdenv }:

stdenv.mkDerivation {
  pname = "plymouth-silent-splash";
  version = "1.0";

  src = ./theme;

  dontBuild = true;

  installPhase = ''
    mkdir -p $out/share/plymouth/themes/silent-splash
    cp -r . $out/share/plymouth/themes/silent-splash/
  '';
}
