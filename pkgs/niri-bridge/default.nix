# pkgs/niri-bridge/default.nix
{ lib, rustPlatform, fetchFromGitHub, pkg-config, wayland }:

rustPlatform.buildRustPackage rec {
  pname = "niri-bridge";
  version = "0.2.0-beta.3";

  src = fetchFromGitHub {
    owner = "blackdream1890";
    repo = "niri-bridge";
    rev = "v${version}";
    hash = "sha256-fL0vrQ2xINm2kWeZWFOn4zl0DpukyHhKjeWQrl9ixcY=";
  };

  cargoLock = {
    lockFile = "${src}/Cargo.lock";
    # Only non-crates.io dependency: a pinned evdev fork carrying an
    # upstream fix for UI_SET_PHYS's pointer-sized ioctl payload (0.13.2
    # on crates.io returns EINVAL). See Cargo.toml's inline comment.
    outputHashes = {
      "evdev-0.13.2" = "sha256-P3V3hhz7l0/K/CawBymsqG+8HzxuRTRDzkHRisYlaJI=";
    };
  };

  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ wayland ];

  # Upstream's integration tests open real evdev/uinput/wayland devices and
  # a live compositor connection -- not runnable in the Nix build sandbox.
  doCheck = false;

  meta = {
    description = "Bidirectional keyboard, pointer and native touchpad sharing for Niri on Wayland";
    homepage = "https://github.com/blackdream1890/niri-bridge";
    license = lib.licenses.gpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "niri-bridge";
  };
}
