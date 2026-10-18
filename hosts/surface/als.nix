{ config, ... }:
{
  # Stock apds9960 mis-drives the Surface's MSHW0184 (gain register, ATIME
  # direction), leaving it blind in a lit room. Same iio device, fixed driver.
  boot.extraModulePackages = [
    (config.boot.kernelPackages.callPackage ../../pkgs/apds9960-mshw0184 { })
  ];
  boot.blacklistedKernelModules = [ "apds9960" ];
}
