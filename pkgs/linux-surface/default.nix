{ pkgs, lib, ... }:

let
  version = "7.3";

  linux-surface-src = pkgs.fetchFromGitHub {
    owner = "linux-surface";
    repo = "linux-surface";
    rev = "8c62d84193a38bd097238b192a4f7262db8a9f7e";
    sha256 = "sha256-687H05hC6HDdOhJPG9C/bOszSdQy/YCWyf688mMytos=";
  };

  patchSrc = linux-surface-src + "/patches/${lib.versions.majorMinor version}";

  kernelPatches = pkgs.callPackage ./patches.nix {
    inherit (lib) kernel;
    inherit version patchSrc;
  };

  linuxSurface = pkgs.buildLinux {
    inherit version kernelPatches;
    modDirVersion = lib.versions.pad 3 version;
    src = pkgs.fetchurl {
      url = "mirror://kernel/linux/kernel/v${lib.versions.major version}.x/linux-${version}.tar.xz";
      sha256 = "sha256-hzY8JPEOBjIes2J2VSEJTpRHH2v/i84taz5A858ASVM=";
    };
    ignoreConfigErrors = true;
  };

in
  lib.recurseIntoAttrs (pkgs.linuxPackagesFor linuxSurface)
