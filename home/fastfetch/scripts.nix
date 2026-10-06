pkgs:
let
  scripts = {
    vpn = pkgs.writeShellScript "ff-vpn" ''
      iface=$(ip link show type wireguard 2>/dev/null | grep -oP '(?<=\d: )protonvpn-\S+(?=:)' | head -1)
      if [[ -n "$iface" ]]; then
        region=$(echo "''${iface#protonvpn-}" | tr '[:lower:]' '[:upper:]')
        echo "On ($region)"
      else
        echo "Off"
      fi
    '';

    lix = pkgs.writeShellScript "ff-lix" "nix --version 2>&1 | head -1 | awk '{print $NF}'";

    rebuild = pkgs.writeShellScript "ff-rebuild" ''
      elapsed=$(( $(date +%s) - $(stat -c %Y /nix/var/nix/profiles/system) ))
      days=$(( elapsed / 86400 ))
      (( days >= 14 )) && echo "''${days}d (stale)" || ((( days >= 7 )) && echo "''${days}d (aging)" || echo "''${days}d (fresh)")
    '';
  };
in scripts
