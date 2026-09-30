{ config, lib, pkgs, modulesPath, self, ... }:
let
  # Wrap the repo's recovery helpers as PATH commands so they're one word away
  # at 2am in a live shell. Bundled verbatim from scripts/ — kept as-is so the
  # bin name matches what's documented in CLAUDE.md / git history.
  recoveryScripts = pkgs.runCommand "rescue-scripts" { } ''
    mkdir -p $out/bin
    install -m755 ${./scripts/desktop-enter.sh}          $out/bin/desktop-enter
    install -m755 ${./scripts/surface-fix-bootloader.sh} $out/bin/surface-fix-bootloader
    install -m755 ${./scripts/surface-rebuild-enclosure.sh} $out/bin/surface-rebuild-enclosure
    install -m755 ${./scripts/enroll-secureboot-tpm2.sh} $out/bin/enroll-secureboot-tpm2
  '';
in
{
  imports = [
    "${modulesPath}/installer/cd-dvd/installation-cd-minimal.nix"
  ];

  networking.hostName = "nixos-rescue";

  image.fileName = lib.mkForce "nixos-rescue-${config.system.nixos.label}-${pkgs.stdenv.hostPlatform.system}.iso";

  # Disk + boot surgery toolkit, plus the flake's own recovery scripts.
  environment.systemPackages = with pkgs; [
    recoveryScripts
    cryptsetup btrfs-progs sbctl
    parted gptfdisk dosfstools e2fsprogs ntfs3g
    nvd git tmux vim ripgrep fd bat fastfetch
    pciutils usbutils lshw smartmontools nvme-cli
    rsync curl wget
  ];

  # Reliable rescue shell over fancy: system-wide zsh with the niceties, no
  # home-manager (keeps the ISO lean and the build from dragging in the HM
  # closure). p10k lives in the daily config, not the rescue stick.
  programs.zsh = {
    enable = true;
    autosuggestions.enable = true;
    syntaxHighlighting.enable = true;
  };
  users.users.root.shell = pkgs.zsh;
  users.users.nixos.shell = pkgs.zsh;

  # The flake itself, frozen at the git-tracked snapshot this ISO was built
  # from, for offline `nixos-install --flake /etc/nixos-flake#<host>`.
  environment.etc."nixos-flake".source = self;

  # Login banner: point future-2am-Phil at the tools.
  services.getty.helpLine = lib.mkAfter ''

    nixos-rescue — flake at /etc/nixos-flake
      desktop-enter            chroot into the desktop install (LUKS+btrfs)
      surface-fix-bootloader   re-sign / fix lanzaboote on surface
      enroll-secureboot-tpm2   re-enroll secure boot + TPM2
      offline rebuild:  nixos-install --flake /etc/nixos-flake#desktop
  '';

  # Bigger ISO is fine; this is a rescue stick, not a download.
  isoImage.squashfsCompression = "zstd -Xcompression-level 6";
}
