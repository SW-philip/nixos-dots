{ pkgs, ... }:
# Pulls the pi's AdGuard query log (modules/adguardhome.nix) onto this disk.
# The pi keeps it on tmpfs only, so this copy is the history.
{
  systemd.services.dns-querylog-pull = {
    path = [ pkgs.openssh pkgs.coreutils pkgs.gnugrep pkgs.findutils ];
    serviceConfig = {
      Type = "oneshot";
      StateDirectory = "dns-querylog";
      # every device's browsing history; the kiosk account has no business here
      StateDirectoryMode = "0700";
      UMask = "0077";
      Nice = 19;
      IOSchedulingClass = "idle";
    };
    startAt = "*:0/15";
    script = ''
      dir=/var/lib/dns-querylog
      # The host key is already pinned on the pi as retro's identity; no extra secret to manage.
      ssh -i /etc/ssh/ssh_host_ed25519_key -T -o BatchMode=yes -o ConnectTimeout=10 \
        querylog@pi > "$dir/fetch.tmp"
      [ -s "$dir/fetch.tmp" ] || exit 0

      # Resume after the last line already saved. Not found means the pi rebooted
      # (tmpfs wiped) or retro missed a full rotation: take everything it still has.
      start=1
      if [ -s "$dir/last" ]; then
        n=$(grep -Fxn -f "$dir/last" "$dir/fetch.tmp" | tail -n1 | cut -d: -f1)
        if [ -n "$n" ]; then
          start=$((n + 1))
        else
          echo "last saved entry not on the pi; possible gap before $(head -c 40 "$dir/fetch.tmp")" >&2
        fi
      fi

      tail -n +"$start" "$dir/fetch.tmp" >> "$dir/$(date +%Y-%m).jsonl"
      tail -n1 "$dir/fetch.tmp" > "$dir/last"
      rm "$dir/fetch.tmp"
      find "$dir" -name '*.jsonl' -mtime +365 -delete
    '';
  };
  systemd.timers.dns-querylog-pull.timerConfig.Persistent = true;
}
