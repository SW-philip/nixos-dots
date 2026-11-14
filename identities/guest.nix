{ pkgs, ... }:
{
  ############################################################
  # Guest — prepko's look and apps with nothing of his (profiles/guest/).
  # Passwordless; the home is a fresh tmpfs per login (modules/guest.nix).
  # No groups: niri gets input through the logind seat, and pads/audio
  # through uaccess, like any active local session.
  ############################################################
  users.users.guest = {
    isNormalUser   = true;
    uid            = 1100;  # pinned: modules/guest.nix keys the tmpfs to user@1100.service
    description    = "Guest";
    shell          = pkgs.zsh;
    hashedPassword = "";
    # Its own group, not `users`: nothing of prepko's that is group-users is its business.
    group          = "guest";
  };
  users.groups.guest.gid = 1100;
}
