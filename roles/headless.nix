# retro and pi: no home-manager, deployed from desktop over ssh.
{ config, pkgs, lib, ... }:
let
  user = config.myConfig.user;
in
{
  imports = [
    ./common.nix
    ./nix-hygiene.nix
  ];

  # identities/prepko.nix lists groups that don't exist here and sets zsh.
  users.users.${user} = {
    shell = lib.mkForce pkgs.bash;
    extraGroups = lib.mkForce [ "wheel" "networkmanager" ];
  };
  # Passwordless on purpose: remote deploys (nixos-rebuild --sudo over ssh) can't prompt, and
  # scoping NOPASSWD to deploy commands buys nothing since nix-env/systemd-run/switch-to-configuration
  # are root-equivalent. A wrong rule would lock out deploys.
  security.sudo.wheelNeedsPassword = false;

  # No home-manager here, so no themed ff: stock fastfetch under the usual name.
  environment.systemPackages = [ pkgs.fastfetch pkgs.ghostty.terminfo ];
  environment.shellAliases.ff = "fastfetch";

  networking.networkmanager.enable = true;
  sops.age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];

  services.tailscale.enable = true;
  networking.firewall.checkReversePath = "loose";

  # Logs in RAM (SD card on the pi, idle fleet-status chatter on retro's SSD);
  # each host sets its own RuntimeMaxUse.
  services.journald.extraConfig = ''
    Storage=volatile
  '';
}
