# Out-of-tree build of the in-tree apds9960 driver with MSHW0184 fixes (see
# mshw0184.patch). Built as its own module so the stock apds9960 can be
# blacklisted instead of relying on depmod search order.
{ stdenv, lib, kernel }:

stdenv.mkDerivation {
  pname = "apds9960-mshw0184";
  inherit (kernel) version;

  inherit (kernel) src;
  nativeBuildInputs = kernel.moduleBuildDependencies;

  # kernel.src is the full tarball; only this one file is needed.
  unpackPhase = ''
    mkdir build
    tar -xf $src --wildcards '*/drivers/iio/light/apds9960.c' -O > build/apds9960_mshw0184.c
    echo 'obj-m := apds9960_mshw0184.o' > build/Makefile
    cd build
  '';

  patchPhase = ''
    patch -p3 apds9960_mshw0184.c < ${./mshw0184.patch}
  '';

  hardeningDisable = [ "pic" ];

  buildPhase = ''
    make -C ${kernel.dev}/lib/modules/${kernel.modDirVersion}/build M=$PWD modules
  '';

  installPhase = ''
    install -D -t $out/lib/modules/${kernel.modDirVersion}/extra apds9960_mshw0184.ko
  '';

  meta = {
    description = "apds9960 ALS driver fixed for the Surface MSHW0184 sensor";
    license = lib.licenses.gpl2Only;
    platforms = [ "x86_64-linux" ];
  };
}
