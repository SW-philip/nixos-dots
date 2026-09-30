{ pkgs, lib, ... }:

{
  environment.systemPackages = [ pkgs.powertop ];

  # 1s runtime-autosuspend default for every USB device (digitizer/pen stack,
  # type cover, internal hub) — the PCI-level power/control=auto rule below
  # doesn't touch USB, so this was the one class of device powertop's
  # tunables tab would still flag "Bad" on.
  boot.kernelParams = lib.mkAfter [ "usbcore.autosuspend=1" ];

  boot.kernel.sysctl = {
    "vm.swappiness" = 10;
    "kernel.nmi_watchdog" = 0;
    "vm.dirty_writeback_centisecs" = 1500;
    "vm.dirty_background_ratio" = 5;
    "vm.dirty_ratio" = 10;
  };

  boot.kernelModules = [ "intel_pmc_core" ];

  boot.extraModprobeConfig = ''
    options snd_hda_intel power_save=1 power_save_controller=Y
    options snd_sof_intel_hda_common hda_model=dell-headset-multi
    # Intel BT L2CAP ERTM handling drops DS4/DS3 controllers seconds after
    # connect ("Connection terminated by remote user" loop in bluetoothctl).
    options bluetooth disable_ertm=1
  '';

  # ACTION=="add" alone covers this: systemd-udevd replays "add" for every
  # coldplugged device during boot, so this rule already applies to devices
  # present at boot as well as hotplug — no separate boot-time service needed.
  services.udev.extraRules = ''
    ACTION=="add", SUBSYSTEM=="pci", ATTR{power/control}="auto"
    ACTION=="change", SUBSYSTEM=="pci", ATTR{power/control}="auto"
    ACTION=="change", SUBSYSTEM=="power_supply", ATTR{type}=="Mains", RUN+="${pkgs.systemd}/bin/systemctl start --no-block auto-power-profile.service"
    ATTRS{name}=="Intel Touch Host Controller", ENV{ID_INPUT_MOUSE}="0", ENV{ID_INPUT_TOUCHSCREEN}="1"
  '';

  networking.networkmanager.wifi.powersave = true;

  services.power-profiles-daemon.enable = true;
  services.thermald.enable = true;
  services.irqbalance.enable = true;

  # thermald needs root + raw /dev/cpu/*/msr + /sys powercap access to
  # actually throttle — can't drop privileges or lock down kernel/device
  # access without breaking thermal control on fanless Surface hardware.
  # Only add what doesn't touch that: no home/tmp/IPC/namespace access needed.
  systemd.services.thermald.serviceConfig = {
    ProtectHome = true;
    PrivateTmp = true;
    NoNewPrivileges = true;
    ProtectKernelLogs = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictSUIDSGID = true;
    RestrictNamespaces = true;
    LockPersonality = true;
    RemoveIPC = true;
  };

  powerManagement.enable = true;

  # Default HandlePowerKey=suspend re-fires on the very press that woke the
  # machine from s2idle: logind sees "power key pressed" *after* resume
  # completes and immediately suspends again, flashing the screen on/off
  # (sometimes several times in a row — confirmed in journalctl: repeated
  # "PM: suspend entry" within 1-5s of "PM: suspend exit", each preceded by
  # a matching "Power key pressed short"). Phil only ever touches this
  # button to wake a stuck display, never to request suspend, so ignoring
  # the key removes the re-suspend trigger entirely without losing anything.
  services.logind.settings.Login.HandlePowerKey = "ignore";

  systemd.services.auto-power-profile = {
    description = "Auto-switch power profile based on AC state";
    wantedBy = [ "graphical.target" ];
    after = [ "power-profiles-daemon.service" "dbus.service" ];
    requires = [ "power-profiles-daemon.service" ];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "auto-power-profile" ''
        if [ "$(cat /sys/class/power_supply/ADP1/online)" = "1" ]; then
          ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set balanced
        else
          ${pkgs.power-profiles-daemon}/bin/powerprofilesctl set power-saver
        fi
      '';
    };
  };

  # systemd-sleep invokes this with $1=pre before sleep and $1=post after resume —
  # a guaranteed matched pair bracketing one real suspend. A WantedBy=sleep.target
  # service can't do this: WantedBy only starts it, nothing stops it on resume, so
  # ExecStop (the post capture) never fires.
  environment.etc."systemd/system-sleep/sleep-drain" = {
    mode = "0755";
    source = pkgs.writeShellScript "sleep-drain-hook" ''
      ${pkgs.coreutils}/bin/mkdir -p /home/prepko/.cache/sleep-drain
      energy="$(${pkgs.coreutils}/bin/cat /sys/class/power_supply/BAT1/energy_now 2>/dev/null || echo 0)"
      now="$(${pkgs.coreutils}/bin/date +%s)"
      s0ix="$(${pkgs.coreutils}/bin/cat /sys/kernel/debug/pmc_core/slp_s0_residency_usec 2>/dev/null || echo -1)"

      if [ "$1" = pre ]; then
        # Active, non-hub USB devices = things that may hold the SoC out of S0ix.
        suspects=""
        for d in /sys/bus/usb/devices/*/; do
          st="$(${pkgs.coreutils}/bin/cat "$d/power/runtime_status" 2>/dev/null)" || continue
          [ "$st" = active ] || continue
          [ "$(${pkgs.coreutils}/bin/cat "$d/bDeviceClass" 2>/dev/null)" = 09 ] && continue
          prod="$(${pkgs.coreutils}/bin/cat "$d/product" 2>/dev/null)" || continue
          [ -n "$prod" ] || continue
          suspects="''${suspects:+$suspects; }$prod"
        done
        printf '%s\n%s\n%s\n%s\n' "$energy" "$now" "$s0ix" "$suspects" \
          > /home/prepko/.cache/sleep-drain/pre
        # Phase 3: snapshot wake counters for the post hook to diff.
        # Line 1 = kernel wakeup_count; lines 2+ = "<source>\t<active_count>".
        {
          ${pkgs.coreutils}/bin/cat /sys/power/wakeup_count 2>/dev/null || echo 0
          ${pkgs.gawk}/bin/awk 'NR>1{print $1"\t"$2}' /sys/kernel/debug/wakeup_sources 2>/dev/null
        } > /home/prepko/.cache/sleep-drain/wake-pre
      elif [ "$1" = post ]; then
        wake_count=-1
        top_source=""
        if [ -f /home/prepko/.cache/sleep-drain/wake-pre ]; then
          wc_post="$(${pkgs.coreutils}/bin/cat /sys/power/wakeup_count 2>/dev/null || echo 0)"
          wc_pre="$(${pkgs.coreutils}/bin/head -1 /home/prepko/.cache/sleep-drain/wake-pre)"
          wake_count=$(( wc_post - wc_pre ))
          [ "$wake_count" -lt 0 ] && wake_count=0
          top_source="$(${pkgs.gawk}/bin/awk '
            NR==FNR { if (FNR>1) pre[$1]=$2; next }
            FNR==1 { next }
            { d=$2-pre[$1]; if (d>max){max=d; src=$1} }
            END { if (max>0) print src }
          ' /home/prepko/.cache/sleep-drain/wake-pre /sys/kernel/debug/wakeup_sources 2>/dev/null)"
        fi
        printf '%s\n%s\n%s\n%s\n%s\n' "$energy" "$now" "$s0ix" "$wake_count" "$top_source" \
          > /home/prepko/.cache/sleep-drain/post

        # history.log: post overwrites on every cycle, so a flapping burst
        # (suspend/resume repeating within seconds) clobbers its own evidence
        # before anyone can look at it. Append one line per cycle instead.
        pre_time="$(${pkgs.coreutils}/bin/sed -n 2p /home/prepko/.cache/sleep-drain/pre 2>/dev/null || echo "$now")"
        pre_suspects="$(${pkgs.coreutils}/bin/sed -n 4p /home/prepko/.cache/sleep-drain/pre 2>/dev/null)"
        duration=$(( now - pre_time ))
        {
          printf '%s\tduration=%ss\twake_count=%s\ttop_source=%s\tsuspects=%s\n' \
            "$(${pkgs.coreutils}/bin/date -d "@$now" -Iseconds)" \
            "$duration" "$wake_count" "''${top_source:-none}" "''${pre_suspects:-none}"
        } >> /home/prepko/.cache/sleep-drain/history.log
        # Cap growth — keep the most recent 2000 cycles.
        ${pkgs.coreutils}/bin/tail -n 2000 /home/prepko/.cache/sleep-drain/history.log \
          > /home/prepko/.cache/sleep-drain/history.log.tmp \
          && ${pkgs.coreutils}/bin/mv /home/prepko/.cache/sleep-drain/history.log.tmp /home/prepko/.cache/sleep-drain/history.log
      fi
    '';
  };
}
