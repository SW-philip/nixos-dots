{ pkgs, inventory, ... }:
let
  # from= pins a key to its origin's tailnet IP, so a copy of the file (backup,
  # snapshot, stray repo) is useless off that machine.
  pinned = host: key:
    ''from="${inventory.${host}.ip}",no-agent-forwarding,no-X11-forwarding ${key}'';
in
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
      # Passphrase-protected interactive keys, kept as a break-glass path.
      (pinned "desktop" "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY")
      (pinned "surface" "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY")
      # Passphrase-free id_fleet, for unattended jobs (goodnight, tree-sync, fleet-status).
      (pinned "desktop" "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY")
      (pinned "surface" "ssh-ed25519 AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY")
    ];
  };
}
