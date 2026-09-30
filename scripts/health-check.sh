#!/usr/bin/env bash
# health-check.sh — system health audit for NixOS

set -uo pipefail

HOST=$(hostname)
IS_SURFACE=false; IS_DESKTOP=false
[[ "$HOST" == "SWsurface" ]] && IS_SURFACE=true
[[ "$HOST" == "SWphil"   ]] && IS_DESKTOP=true

PASS=0; WARN=0; FAIL=0

pass() { echo "  ✔ $1"; ((PASS++)); }
warn() { echo "  ~ $1"; ((WARN++)); }
fail() { echo "  ✗ $1"; ((FAIL++)); }

echo "system health check"
echo "host:  $HOST"
echo "date:  $(date)"
echo "user:  $(whoami)"
echo

# Sample CPU before work
read -r _cpu _user _nice _system _idle _iowait _irq _softirq _steal _ < /proc/stat 2>/dev/null || true

########################################
echo "── Secure Boot"
########################################
sb=$(bootctl status 2>/dev/null | grep -i "secure boot" | head -1 || true)
if echo "$sb" | grep -qi "enabled"; then
  pass "Secure Boot enabled"
elif echo "$sb" | grep -qi "disabled"; then
  fail "Secure Boot disabled — enable in UEFI firmware"
else
  warn "Secure Boot status unknown"
fi

if { bootctl status 2>/dev/null || true; } | grep -qi "lanzastub"; then
  pass "lanzaboote (lanzastub) detected"
elif sudo ls /boot/EFI/Linux/*.efi 2>/dev/null | grep -q "."; then
  pass "lanzaboote unified kernel images found in /boot/EFI/Linux"
else
  warn "lanzaboote not confirmed — check: ls /boot/EFI/Linux/"
fi

########################################
echo "── TPM2 / LUKS"
########################################
if [ -e /dev/tpm0 ] || [ -e /dev/tpmrm0 ]; then
  pass "TPM2 device present"
else
  fail "no TPM2 device found at /dev/tpm0 or /dev/tpmrm0"
fi

luks_count=$(lsblk -o TYPE | grep -c "^crypt$" || true)
if $IS_DESKTOP; then
  if [ "$luks_count" -ge 2 ]; then
    pass "both LUKS devices active ($luks_count crypt devices)"
  elif [ "$luks_count" -eq 1 ]; then
    warn "only 1 LUKS device active — /srv or root drive may not be unlocked"
  else
    fail "no active LUKS devices found"
  fi
else
  if [ "$luks_count" -ge 1 ]; then
    pass "LUKS device active ($luks_count crypt device(s))"
  else
    fail "no active LUKS devices found"
  fi
fi

while IFS= read -r raw; do
  part=$(echo "$raw" | tr -d ' └─├─')
  [ -z "$part" ] && continue
  tpm_enrolled=$(sudo systemd-cryptenroll "/dev/$part" 2>/dev/null | grep -c "tpm2" || true)
  if [ "$tpm_enrolled" -gt 0 ]; then
    pass "TPM2 enrolled in /dev/$part"
  else
    warn "TPM2 not enrolled in /dev/$part — run: sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/$part"
  fi
done < <(lsblk -o NAME,TYPE,FSTYPE | awk '$3=="crypto_LUKS"{print $1}')

########################################
echo "── CPU & Thermals"
########################################
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
if [ "$governor" = "powersave" ]; then
  pass "CPU governor: powersave (intel_pstate active)"
elif [ -n "$governor" ]; then
  warn "CPU governor: $governor — expected powersave"
else
  warn "could not read CPU governor"
fi

if command -v sensors &>/dev/null; then
  max_temp=$(sensors 2>/dev/null | awk '/^coretemp/,/^$/' | grep -E "^(Package|Core)" | grep -oP '^\S.*?\+\K[0-9]+(?=\.[0-9]°C)' | sort -n | tail -1 || true)
  if [ -n "$max_temp" ]; then
    if [ "$max_temp" -le 60 ]; then pass "CPU temp OK at ${max_temp}°C idle"
    elif [ "$max_temp" -le 78 ]; then warn "CPU temp elevated at ${max_temp}°C idle"
    else fail "CPU temp high at ${max_temp}°C idle"; fi
  else
    warn "sensors installed but no temp data returned"
  fi
else
  warn "sensors not installed (lm_sensors)"
fi

########################################
echo "── GPU"
########################################
if $IS_DESKTOP; then
  nvidia_mod=$(lsmod 2>/dev/null | grep -c "^nvidia " || true)
  if [ "$nvidia_mod" -gt 0 ]; then
    pass "nvidia kernel module loaded"
  else
    fail "nvidia module not loaded"
  fi

  if command -v nvidia-smi &>/dev/null; then
    gpu_temp=$(nvidia-smi --query-gpu=temperature.gpu --format=csv,noheader 2>/dev/null | head -1 | tr -d ' ' || true)
    if [ -n "$gpu_temp" ] && [[ "$gpu_temp" =~ ^[0-9]+$ ]]; then
      if [ "$gpu_temp" -le 55 ]; then pass "GPU temp OK at ${gpu_temp}°C idle"
      else warn "GPU temp elevated at ${gpu_temp}°C idle"; fi
    fi
  fi
else
  loaded=$(lsmod 2>/dev/null | awk '$1=="xe" || $1=="i915" {printf "%s ", $1}' | sed 's/ $//')
  if [ -n "$loaded" ]; then
    pass "Intel GPU module(s) loaded: $loaded"
  else
    warn "no Intel GPU driver detected"
  fi
fi

########################################
echo "── Memory & Mountpoints"
########################################
total=$(free -m | awk '/^Mem:/{print $2}')
used=$(free -m | awk '/^Mem:/{print $3}')
pct=$(( used * 100 / total ))
pass "RAM usage ${pct}% (${used}MB / ${total}MB)"

root_pct=$(df / | awk 'NR==2{print $5}' | tr -d '%')
[ "$root_pct" -le 85 ] && pass "root filesystem ${root_pct}% full" || fail "root filesystem filling up"

boot_pct=$(df /boot | awk 'NR==2{print $5}' | tr -d '%')
[ "$boot_pct" -le 85 ] && pass "/boot ${boot_pct}% full" || warn "/boot space low — clean old generations"

if $IS_DESKTOP; then
  if mountpoint -q /srv 2>/dev/null; then
    srv_pct=$(df /srv | awk 'NR==2{print $5}' | tr -d '%')
    [ "$srv_pct" -le 90 ] && pass "/srv ${srv_pct}% full" || warn "/srv drive filling up"
  else
    fail "/srv not mounted"
  fi
fi

########################################
echo "── btrfs Device Errors"
########################################
btrfs_mps=(/)
$IS_DESKTOP && btrfs_mps+=(/srv)
for mp in "${btrfs_mps[@]}"; do
  if mountpoint -q "$mp" 2>/dev/null; then
    errors=$(sudo btrfs device stats "$mp" 2>/dev/null | awk '{sum += $2} END {print sum+0}')
    [ "$errors" -eq 0 ] && pass "btrfs $mp: no device errors" || fail "btrfs $mp: $errors corruption/write error(s) found!"
  fi
done

########################################
echo "── Services & Custom Daemons"
########################################
services=("NetworkManager" "sshd" "pipewire")
$IS_DESKTOP && services+=("smartd" "iptv-serve")

for svc in "${services[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl --user is-active --quiet "$svc" 2>/dev/null; then
    pass "$svc active"
  else
    fail "$svc down"
  fi
done

# Checking your custom internet radio daemon
if systemctl --user is-active --quiet sqlch-daemon 2>/dev/null; then
  pass "sqlch-daemon running"
else
  warn "sqlch-daemon not running"
fi

########################################
echo "── Nix Generation Cleanup Health"
########################################
old_gens=$(sudo nix-env --list-generations --profile /nix/var/nix/profiles/system 2>/dev/null | wc -l || true)
if [ "$old_gens" -le 6 ]; then
  pass "$old_gens system generations active"
else
  warn "$old_gens generations stored — target a garbage collection sweep"
fi

########################################
echo "── CPU Idle Verification"
########################################
if [ -n "${_idle:-}" ]; then
  read -r _ u2 n2 s2 i2 w2 r2 f2 t2 _ < /proc/stat 2>/dev/null || true
  _dtotal=$(( (u2+n2+s2+i2+w2+r2+f2+t2) - (_user+_nice+_system+_idle+_iowait+_irq+_softirq+_steal) ))
  _didle=$(( i2 - _idle ))
  _idle_pct=$(( 100 * _didle / _dtotal ))
  [ "$_idle_pct" -ge 60 ] && pass "CPU idle stable at ${_idle_pct}%" || warn "CPU idle low (${_idle_pct}%) — background work executing"
fi

# Final Evaluation Pipeline
TOTAL=$((PASS + WARN + FAIL))
[ "$TOTAL" -eq 0 ] && TOTAL=1
SCORE=$(( (PASS * 100 + WARN * 60) / TOTAL ))

echo -e "\n────────────────────────────────"
echo "Results: $TOTAL checks [Pass: $PASS | Warn: $WARN | Fail: $FAIL]"
if [ "$SCORE" -ge 90 ]; then echo "Grade: A ($SCORE/100) — System healthy."; else echo "Grade: B/C ($SCORE/100) — Triage suggested."; fi
