{ pkgs, ... }:
{
  ############################################################
  # Kid — kid account. No sudo (not in wheel); the few NOPASSWD
  # rules (tailscale, goodnight-activate) are scoped to myConfig.user.
  # Only the groups needed to USE the device.
  ############################################################
  users.users.kid = {
    isNormalUser = true;
    description  = "Kid";
    shell        = pkgs.bash;
    extraGroups  = [ "video" "audio" "input" "bluetooth" ];
    # mutableUsers=false: the hash is a sops secret, wired in hosts/surface/config.nix.
    # No ssh into their account (sshd denies it in hosts/surface/config.nix). Remote help:
    # `ssh surface`, then `sudo machinectl shell kid@`.
  };
}
