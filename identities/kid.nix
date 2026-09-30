{ pkgs, ... }:
{
  ############################################################
  # Kid — kid account. No sudo (not in wheel); roles/base.nix's
  # NOPASSWD rule is scoped to myConfig.user (prepko), so they is excluded.
  # Only the groups needed to USE the device.
  ############################################################
  users.users.kid = {
    isNormalUser = true;
    description  = "Kid";
    shell        = pkgs.bash;
    extraGroups  = [ "video" "audio" "input" "bluetooth" ];
    # mutableUsers=false: the hash is a sops secret, wired in hosts/surface/config.nix.
    # Desktop SSH-in for remote help/admin of their account.
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY"
    ];
  };
}
