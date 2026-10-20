#!/usr/bin/env bash
# health-check.sh — system health audit for NixOS
#   HC_HOST=<flake name>   host identity when run piped over ssh (no repo/jq there)
#   HC_NONINTERACTIVE=1    never prompt for sudo; root-only checks report `?` (unchecked)
#                          instead of guessing. Set by goodnight-audit.sh.

set -uo pipefail

HOST=$(hostname)
FLEET_JSON=${FLEET_JSON:-/etc/fleet.json}
[[ -r $FLEET_JSON ]] || FLEET_JSON=$(dirname "$0")/../hosts/inventory.json
# short flake name for a nickname (SWphil) or Tailscale label (swphil); empty if unknown
fleet_self() { jq -r --arg n "${1,,}" 'to_entries[] | select(.key == $n or (.value.nick | ascii_downcase) == $n) | .key' "$FLEET_JSON" | head -n1; }
ME=${HC_HOST:-$(fleet_self "$HOST" 2>/dev/null || true)}
IS_SURFACE=false; IS_DESKTOP=false
[[ "$ME" == surface ]] && IS_SURFACE=true
[[ "$ME" == desktop ]] && IS_DESKTOP=true
# prepko's graphical session (user services) exists only on these two.
IS_GRAPHICAL=false; { $IS_SURFACE || $IS_DESKTOP; } && IS_GRAPHICAL=true
IS_UEFI=false; [ -d /sys/firmware/efi ] && IS_UEFI=true
SUDO=sudo; [ "${HC_NONINTERACTIVE:-}" = 1 ] && SUDO="sudo -n"
# Root-only reads: desktop/surface have a validated NOPASSWD wrapper (modules/health-root.nix);
# retro/pi have passwordless sudo and run the plain commands.
ROOTQ=/run/current-system/sw/bin/health-check-root
root_q() { # btrfs-stats <mp> | tpm <dev> | efi-images | smart <dev>
  if [ -x "$ROOTQ" ]; then
    $SUDO "$ROOTQ" "$@"
  else
    case $1 in
      btrfs-stats) $SUDO btrfs device stats "$2" ;;
      tpm) $SUDO systemd-cryptenroll "$2" ;;
      efi-images) $SUDO sh -c 'ls /boot/EFI/Linux/*.efi' ;;
      smart) $SUDO smartctl -H -i -A -l devstat -n standby,0 -- "$2" || true ;;
    esac
  fi
}

PASS=0; WARN=0; FAIL=0

pass() { echo "  ✔ $1"; ((PASS++)); }
warn() { echo "  ~ $1"; ((WARN++)); }
fail() { echo "  ✗ $1"; ((FAIL++)); }
unk()  { echo "  ? $1"; }   # could not look; not scored

echo "system health check"
echo "host:  $HOST${ME:+ ($ME)}"
echo "date:  $(date)"
echo "user:  $(whoami)"
echo

# Sample CPU before work
read -r _cpu _user _nice _system _idle _iowait _irq _softirq _steal _ < /proc/stat 2>/dev/null || true

if $IS_UEFI; then
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
elif root_q efi-images 2>/dev/null | grep -q "."; then
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
  if ! enroll=$(root_q tpm "/dev/$part" 2>/dev/null); then
    unk "TPM2 enrollment of /dev/$part unchecked (needs root)"
    continue
  fi
  tpm_enrolled=$(grep -c "tpm2" <<<"$enroll" || true)
  if [ "$tpm_enrolled" -gt 0 ]; then
    pass "TPM2 enrolled in /dev/$part"
  else
    warn "TPM2 not enrolled in /dev/$part — run: sudo systemd-cryptenroll --tpm2-device=auto --tpm2-pcrs=0+7 /dev/$part"
  fi
done < <(lsblk -o NAME,TYPE,FSTYPE | awk '$3=="crypto_LUKS"{print $1}')
fi

########################################
echo "── CPU & Thermals"
########################################
governor=$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || true)
if [ "$governor" = "powersave" ]; then
  pass "CPU governor: powersave (intel_pstate active)"
elif [ -n "$governor" ] && [ ! -d /sys/devices/system/cpu/intel_pstate ]; then
  pass "CPU governor: $governor"
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
elif $IS_UEFI; then
  loaded=$(lsmod 2>/dev/null | awk '$1=="xe" || $1=="i915" {printf "%s ", $1}' | sed 's/ $//')
  if [ -n "$loaded" ]; then
    pass "Intel GPU module(s) loaded: $loaded"
  else
    warn "no Intel GPU driver detected"
  fi
else
  pass "no discrete GPU stack expected"
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
  if mountpoint -q "$mp" 2>/dev/null && [ "$(findmnt -no FSTYPE "$mp")" = btrfs ]; then
    if ! stats=$(root_q btrfs-stats "$mp" 2>/dev/null); then
      unk "btrfs $mp device errors unchecked (needs root)"
      continue
    fi
    errors=$(awk '{sum += $2} END {print sum+0}' <<<"$stats")
    [ "$errors" -eq 0 ] && pass "btrfs $mp: no device errors" || fail "btrfs $mp: $errors corruption/write error(s) found!"
  fi
done

########################################
echo "── SMART"
########################################
# CRC errors are link (cable/port) faults, not media wear, and the counter never resets —
# only growth means anything, so each disk's last count is kept per serial number.
SMART_STATE=${XDG_STATE_HOME:-$HOME/.local/state}/health-check
mkdir -p "$SMART_STATE" 2>/dev/null || true
ata_raw() { awk -v id="$1" '$1 == id {print $10; exit}' <<<"$2"; }
while read -r dev; do
  out=$(root_q smart "/dev/$dev" 2>/dev/null)
  if [ -z "$out" ]; then unk "SMART on /dev/$dev unchecked (needs root)"; continue; fi
  if grep -q "STANDBY" <<<"$out"; then unk "/dev/$dev asleep — SMART skipped"; continue; fi
  if ! grep -q "overall-health" <<<"$out"; then unk "/dev/$dev reports no SMART (USB bridge?)"; continue; fi
  model=$(awk -F': *' '/^(Device Model|Model Number):/ {print $2; exit}' <<<"$out")
  label="/dev/$dev${model:+ ($model)}"

  if ! grep -q "overall-health.*PASSED" <<<"$out"; then
    fail "$label: SMART overall health FAILED — back up and replace"
    continue
  fi

  realloc=$(ata_raw 5 "$out"); pending=$(ata_raw 197 "$out"); offline=$(ata_raw 198 "$out")
  media=$(awk -F': *' '/^Media and Data Integrity Errors:/ {print $2; exit}' <<<"$out")
  if [ "${pending:-0}" -gt 0 ] || [ "${offline:-0}" -gt 0 ] || [ "${media:-0}" -gt 0 ]; then
    fail "$label: unreadable sectors (pending ${pending:-0}, offline ${offline:-0}, media ${media:-0}) — scrub and plan a replacement"
  elif [ "${realloc:-0}" -gt 0 ]; then
    warn "$label: ${realloc} reallocated sector(s) — watch for growth"
  else
    pass "$label: no bad sectors"
  fi

  crc=$(ata_raw 199 "$out")
  serial=$(awk -F': *' '/^Serial Number:/ {print $2; exit}' <<<"$out")
  if [ -n "$crc" ] && [ -n "$serial" ]; then
    state="$SMART_STATE/crc-$serial"
    prev=$(cat "$state" 2>/dev/null || true)
    echo "$crc" >"$state" 2>/dev/null || true
    if [ -z "$prev" ]; then
      pass "$label: SATA CRC count $crc (baseline recorded)"
    elif [ "$crc" -gt "$prev" ]; then
      warn "$label: $((crc - prev)) new SATA CRC error(s) ($prev → $crc) — reseat/replace the data cable or try another port"
    else
      pass "$label: SATA link clean (CRC count steady at $crc)"
    fi
  fi

  # Endurance left, in order of trust: NVMe "Percentage Used", ATA device statistics,
  # then the vendor attributes (ADATA/SMI report remaining % in 169's raw value).
  used=$(awk -F': *' '/^Percentage Used:/ {sub(/%/, "", $2); print $2; exit}' <<<"$out")
  [ -z "$used" ] && used=$(awk '/Percentage Used Endurance Indicator/ {print $4; exit}' <<<"$out")
  if [ -n "$used" ]; then
    life=$((100 - used))
  else
    life=$(awk '$2 == "Remaining_Lifetime_Perc" {print $10; exit} $2 ~ /^(SSD_Life_Left|Percent_Lifetime_Remain)$/ {print $4 + 0; exit}' <<<"$out")
  fi
  if [ -n "$life" ]; then
    if [ "$life" -le 10 ]; then fail "$label: ${life}% SSD endurance left — replace soon"
    elif [ "$life" -le 30 ]; then warn "$label: ${life}% SSD endurance left — plan a replacement"
    else pass "$label: ${life}% SSD endurance left"; fi
  fi
done < <(lsblk -dno NAME,TYPE | awk '$2 == "disk" && $1 !~ /^(zram|mmcblk|loop)/ {print $1}')

########################################
echo "── Services & Custom Daemons"
########################################
services=("NetworkManager" "sshd")
$IS_GRAPHICAL && services+=("pipewire")
$IS_DESKTOP && services+=("smartd" "iptv-serve")

# iptv-serve is off on purpose unless iptv.enable is set (hosts/desktop/iptv.nix).
if $IS_DESKTOP && ! systemctl cat iptv-serve.service &>/dev/null; then
  for i in "${!services[@]}"; do [ "${services[$i]}" = iptv-serve ] && unset 'services[i]'; done
fi

for svc in "${services[@]}"; do
  if systemctl is-active --quiet "$svc" 2>/dev/null || systemctl --user is-active --quiet "$svc" 2>/dev/null; then
    pass "$svc active"
  else
    fail "$svc down"
  fi
done

# Checking your custom internet radio daemon
if $IS_GRAPHICAL; then
  if systemctl --user is-active --quiet sqlch-daemon 2>/dev/null; then
    pass "sqlch-daemon running"
  else
    warn "sqlch-daemon not running"
  fi
fi

########################################
echo "── Nix Generation Cleanup Health"
########################################
# The links are world-readable; `nix-env --list-generations` needs root for its lock file.
old_gens=$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' 2>/dev/null | wc -l)
if [ "$old_gens" -eq 0 ]; then
  unk "system generations unchecked (no profile links found)"
elif [ "$old_gens" -le 6 ]; then
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
