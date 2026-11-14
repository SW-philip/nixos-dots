# The passwordless guest account: a tmpfs home that exists only while its user
# manager runs (so every login starts clean and logout leaves nothing), and
# logind killing whatever the guest leaves behind so nothing outlives the
# session to watch the next one.
{ config, pkgs, ... }:
let
  user = config.users.users.guest;
  unit = "user@${toString user.uid}.service";
in
{
  imports = [ ../identities/guest.nix ];

  systemd.services.guest-home = {
    description = "Fresh tmpfs home for the guest session";
    requiredBy  = [ unit ];
    before      = [ unit ];
    partOf      = [ unit ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.util-linux}/bin/mount -t tmpfs -o size=4G,mode=0700,uid=${toString user.uid},gid=${toString config.users.groups.${user.group}.gid},nosuid,nodev guest-home ${user.home}";
      ExecStop  = "${pkgs.util-linux}/bin/umount --lazy ${user.home}";
    };
  };

  services.logind.settings.Login = {
    KillUserProcesses = true;
    KillOnlyUsers     = [ "guest" ];
  };

  # greetd substacks `login`, which NixOS already gives nullok, so the empty
  # password logs in as is. hyprlock doesn't, and a guest who presses
  # Mod+Escape would otherwise be locked out of the session. Every other
  # account has a real or locked password, so nullok opens only the guest.
  security.pam.services.hyprlock.allowNullPassword = true;

  services.openssh.settings.DenyUsers = [ "guest" ];

  # The guest gets the internet and nothing of ours: no service on this machine
  # (Proton Bridge, Jellyfin, sshd, NFS, Sunshine, the model sockets — on any of
  # its addresses), nothing on the LAN or tailnet. Tailscale's resolver is the
  # one exception, since it is the system DNS.
  # Match the guest positively: kernel-sent packets (RSTs, ICMP replies, NDP)
  # have no socket, so `skuid != guest accept` let them fall into the rejects —
  # loopback RSTs vanished and rpc.mountd hung on its rpcbind probe.
  networking.nftables.tables.guest-fence = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid ${toString user.uid} jump guest
      }
      chain guest {
        ip daddr 100.100.100.100 accept
        ip6 daddr fd7a:115c:a1e0::53 accept
        fib daddr type local reject
        ip daddr { 10.0.0.0/8, 172.16.0.0/12, 192.168.0.0/16, 100.64.0.0/10, 169.254.0.0/16 } reject
        ip6 daddr { fc00::/7, fe80::/10 } reject
      }
    '';
  };
}
