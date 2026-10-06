# Not in nixpkgs on either channel; same fetch as roles/base.nix so the store path is shared.
{ runCommand, fetchurl }:
runCommand "josefin-sans" { } ''
  install -Dm644 ${fetchurl {
    url    = "https://github.com/google/fonts/raw/main/ofl/josefinsans/JosefinSans%5Bwght%5D.ttf";
    sha256 = "sha256-klWr2185O8UeEBq70Hpxapd/0+FUcrG4SyYPQmo0K/0=";
  }} $out/share/fonts/truetype/JosefinSans-Variable.ttf
''
