{ pkgs, ... }:
{
  ############################################################
  # prepko — primary user account
  ############################################################
  users.users.prepko = {
    isNormalUser = true;
    shell = pkgs.zsh;
    extraGroups = [
      "wheel"
      "networkmanager"
      "video"
      "audio"
      "input"
      "plugdev"
      "i2c"
      "bluetooth"
      "lp"
    ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY"
      "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY"
    ];
  };
}
