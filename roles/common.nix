# The floor every host imports: the user option, locale, and the ssh and
# kernel hardening baseline. Workstation-only config stays in roles/base.nix,
# the headless pair's in roles/headless.nix.
{ lib, ... }:
let
  ports = import ../hosts/ports.nix;
in
{
  options.myConfig.user = lib.mkOption {
    type        = lib.types.str;
    default     = "prepko";
    description = "Primary user account name, used wherever a literal username is needed.";
  };

  config = {
    # Fleet name map for scripts (scripts/fleet-status.sh, reaper, nixfetch, quivr).
    environment.etc."fleet.json".source = ../hosts/inventory.json;

    time.timeZone = "America/New_York";
    i18n.defaultLocale = "en_US.UTF-8";
    hardware.enableRedistributableFirmware = true;
    # No host has a modem; NetworkManager pulls ModemManager in by default.
    networking.modemmanager.enable = false;

    nix.settings.experimental-features = [ "nix-command" "flakes" ];

    services.openssh = {
      enable = true;
      settings = {
        UseDns = false;
        PermitRootLogin = "no";
        PasswordAuthentication = false;
        # With UsePAM, keyboard-interactive still prompts for the account password.
        KbdInteractiveAuthentication = false;
        X11Forwarding = false;
        AllowTcpForwarding = false;
        ClientAliveInterval = 300;
        ClientAliveCountMax = 2;
      };
    };
    networking.firewall = {
      enable = true;
      allowedTCPPorts = [ ports.ssh ];
    };

    # Also sets kexec_load_disabled and adds `nohibernate` (no swap-backed resume is configured).
    security.protectKernelImage = true;
    boot.kernel.sysctl = {
      "kernel.kptr_restrict" = 2;
      "kernel.dmesg_restrict" = 1;
      "kernel.unprivileged_bpf_disabled" = 1;
      "fs.protected_fifos" = 2;
      "fs.protected_regular" = 2;
      "net.ipv4.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.default.accept_redirects" = 0;
      "net.ipv6.conf.all.accept_redirects" = 0;
      "net.ipv4.conf.all.send_redirects" = 0;
      "net.ipv4.conf.all.accept_source_route" = 0;
    };
  };
}
