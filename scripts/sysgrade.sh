#!/usr/bin/env bash

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}${BLUE}=========================================${NC}"
echo -e "${BOLD}${BLUE}    SYSTEMD PERFORMANCE & SECURITY EVAL   ${NC}"
echo -e "${BOLD}${BLUE}=========================================${NC}\n"

# --- 1. TIME ANALYSIS ---
echo -e "${BOLD}[1/5] Analyzing Startup Timings...${NC}"
TIME_DATA=$(systemd-analyze time 2>/dev/null || echo "Startup finished in 0s (firmware) + 0s (loader) + 0s (kernel) + 0s (initrd) + 0s (userspace) = 0s")
echo "$TIME_DATA"

# Enhanced regex parsing to correctly convert text like "1min 31.283s" into raw milliseconds
parse_to_ms() {
    local raw
    raw=$(echo "$1" | grep -oP "\d+(\.\d+)?s \($2\)" | sed "s/s ($2)//")
    if echo "$1" | grep -qP "\d+min \d+(\.\d+)?s \($2\)"; then
        local mins secs
        mins=$(echo "$1" | grep -oP "\d+(?=min)")
        secs=$(echo "$1" | grep -oP "\d+(\.\d+)?(?=s \($2\))")
        awk -v m="$mins" -v s="$secs" 'BEGIN {print (m * 60 + s) * 1000}'
    elif [ -n "$raw" ]; then
        awk -v s="$raw" 'BEGIN {print s * 1000}'
    else
        echo ""
    fi
}

LOADER_MS=$(parse_to_ms "$TIME_DATA" "loader")
INITRD_MS=$(parse_to_ms "$TIME_DATA" "initrd")
USER_MS=$(parse_to_ms "$TIME_DATA" "userspace")

# --- 2. CRITICAL CHAIN ---
echo -e "\n${BOLD}[2/5] Fetching Critical Chain Target...${NC}"
systemd-analyze critical-chain | head -n 12

# --- 3. BLAME ANALYSIS ---
echo -e "\n${BOLD}[3/5] Pinpointing Top Execution Bottlenecks...${NC}"
systemd-analyze blame | head -n 5

# --- 4. SECURITY AUDIT ---
echo -e "\n${BOLD}[4/5] Running Core System Security Audit...${NC}"
SEC_DATA=$(systemd-analyze security --no-pager 2>/dev/null)

# Units whose EXPOSED/UNSAFE score reflects a privilege they need by design —
# raw hardware/device access, PAM+fork session handling, broad IPC mediation,
# root-only build/recovery tooling — rather than a lack of hardening effort.
# A real desktop always carries ~25 of these; scoring against a 0 baseline
# that assumes they're all fixable grades against a system that can't exist.
export STRUCTURAL_EXEMPT='^(serial-)?getty@|^rescue\.service$|^emergency\.service$|^actkbd@|^rpcbind\.service$|^rpc-|^nix-daemon\.service$|^greetd\.service$|^udisks2\.service$|^tailscaled\.service$|^sshd\.service$|^smartd\.service$|^reload-systemd-vconsole-setup\.service$|^iptsd@|^user@[0-9]+\.service$|^systemd-rfkill\.service$|^systemd-ask-password-(wall|console)\.service$|^NetworkManager\.service$|^dbus-broker\.service$|^iio-sensor-proxy\.service$'
# Feature daemons and early-boot plumbing whose sandboxing was deliberately
# skipped (libvirt/samba/nfs need broad host access to do their job; plymouth
# needs DRM+tty at boot and a black screen there is not worth a lower score).
# Reported on their own line rather than hidden, and kept out of the average.
export ACCEPTED_RISK='^virt[a-z]*d\.service$|^libvirt(d|-guests)\.service$|^samba-|^nfs-|^nfsdcld\.service$|^plymouth-|^systemd-ask-password-plymouth\.service$'
# Passed via ENVIRON, not -v: gawk's -v assignment runs C-style escape
# processing on the value first, which mangles the \. sequences above.

if [ -n "$SEC_DATA" ]; then
    echo "$SEC_DATA" | head -n 1

    # Both EXPOSED and UNSAFE are risk tiers (UNSAFE is worse) — a prior
    # version of this script only looked at EXPOSED and silently missed
    # every UNSAFE service, understating real exposure.
    RISKY=$(echo "$SEC_DATA" | awk 'NR>1 && ($3=="EXPOSED"||$3=="UNSAFE") && $1 !~ ENVIRON["STRUCTURAL_EXEMPT"] && $1 !~ ENVIRON["ACCEPTED_RISK"]' | sort -k2 -n -r)
    RISKY_COUNT=$(echo "$RISKY" | grep -c . || true)
    STRUCTURAL_COUNT=$(echo "$SEC_DATA" | awk 'NR>1 && ($3=="EXPOSED"||$3=="UNSAFE") && $1 ~ ENVIRON["STRUCTURAL_EXEMPT"]' | grep -c . || true)

    ACCEPTED=$(echo "$SEC_DATA" | awk 'NR>1 && ($3=="EXPOSED"||$3=="UNSAFE") && $1 ~ ENVIRON["ACCEPTED_RISK"] {print $1}')
    ACCEPTED_COUNT=$(echo "$ACCEPTED" | grep -c . || true)
    if [ "$ACCEPTED_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}Accepted risk ($ACCEPTED_COUNT, not scored):${NC} $(echo "$ACCEPTED" | tr '\n' ' ')"
    fi

    if [ "$RISKY_COUNT" -gt 0 ]; then
        echo "$RISKY"
        echo ""
        echo -e "${YELLOW}Note: $STRUCTURAL_COUNT more service(s) score EXPOSED/UNSAFE but need broad${NC}"
        echo -e "${YELLOW}privileges by design (sshd, greetd, tailscaled, nix-daemon, udisks2, etc.) —${NC}"
        echo -e "${YELLOW}excluded from scoring. Full list: systemd-analyze security${NC}"
    else
        echo -e "${GREEN}No actionable EXPOSED/UNSAFE services found.${NC}"
    fi

    AVG_EXPOSURE=$(echo "$SEC_DATA" | awk 'NR>1 && $1 !~ ENVIRON["STRUCTURAL_EXEMPT"] && $1 !~ ENVIRON["ACCEPTED_RISK"] && $2+0 == $2 {sum+=$2; count++} END {if (count>0) printf "%.2f", sum/count; else print 0}')
    echo -e "\nAverage Service Exposure Score: ${BOLD}${AVG_EXPOSURE}/10${NC} (lower is better, structural services excluded)"
    echo -e "Actionable EXPOSED/UNSAFE services: ${BOLD}${RISKY_COUNT}${NC}"
else
    echo "Security analysis unavailable or requires higher privileges."
    AVG_EXPOSURE=0
fi

# --- 5. GENERATING VISUAL PLOT ---
echo -e "\n${BOLD}[5/5] Generating Boot Profile Vector Timeline...${NC}"
PLOT_PATH="$(dirname "$0")/boot_profile.html"
systemd-analyze plot > "$PLOT_PATH" 2>/dev/null
echo -e "${GREEN}✓ Graphical boot timeline saved to: ${PLOT_PATH}${NC}"

# --- SCORECARD ---
echo -e "\n${BOLD}${BLUE}=========================================${NC}"
echo -e "${BOLD}${BLUE}             SYSTEM SCORECARD            ${NC}"
echo -e "${BOLD}${BLUE}=========================================${NC}"

if [ -z "$LOADER_MS" ]; then
    echo -e "Loader Phase:  ${BLUE}N/A (Skipped/EFI Boot)${NC}"
else
    # Measured Boot (lanzaboote UKI + TPM2) has systemd-stub extend several
    # PCR-11 measurements before handoff. On slow fTPM implementations
    # (e.g. Surface's Intel PTT) this alone can add multiple seconds and
    # is not a menu-timeout misconfiguration, so widen the bands when active.
    if bootctl status 2>/dev/null | grep -q "Measured UKI: yes"; then
        LOADER_FAST_MS=4000; LOADER_MOD_MS=9000
    else
        LOADER_FAST_MS=2000; LOADER_MOD_MS=5000
    fi

    if [ "$LOADER_MS" -lt "$LOADER_FAST_MS" ]; then echo -e "Loader Phase:  ${GREEN}A+ (Fast Menu Handoff)${NC}"
    elif [ "$LOADER_MS" -lt "$LOADER_MOD_MS" ]; then echo -e "Loader Phase:  ${YELLOW}B  (Moderate Splash/Menu Padding)${NC}"
    else echo -e "Loader Phase:  ${RED}C  (High Menu Timeout Delay Detected)${NC}"; fi

    if [ "$LOADER_FAST_MS" -eq 4000 ]; then
        echo -e "  ${BLUE}Note: TPM2 Measured Boot active — PCR-extend ops on slow fTPM hardware${NC}"
        echo -e "  ${BLUE}(e.g. Surface's Intel PTT) routinely add several seconds here.${NC}"
    fi
fi

# Strict check for 90s systemd device timeouts
if [ -z "$INITRD_MS" ]; then
    echo -e "Initrd Phase:  ${BLUE}N/A (No Ramdisk)${NC}"
elif [ "$(awk -v i="$INITRD_MS" 'BEGIN {print (i >= 89000)?1:0}')" -eq 1 ]; then
    echo -e "Initrd Phase:  ${RED}F  (CRITICAL HARDWARE TIMEOUT — Check ESP/Device UUIDs)${NC}"
else
    # TPM2-sealed LUKS unlock (tpm2-device=auto in boot.initrd.luks.devices)
    # waits on the same slow fTPM (Surface's Intel PTT) as the loader-phase
    # PCR extension above — widen the bands when systemd-tpm2-setup ran
    # this boot, same reasoning as Loader Phase.
    if systemctl show systemd-tpm2-setup.service -p LoadState 2>/dev/null | grep -q "LoadState=loaded"; then
        INITRD_FAST_MS=2500; INITRD_MOD_MS=6000
    else
        INITRD_FAST_MS=1500; INITRD_MOD_MS=3500
    fi

    if [ "$INITRD_MS" -lt "$INITRD_FAST_MS" ]; then echo -e "Initrd Phase:  ${GREEN}A+ (Instantaneous Drive Mounting)${NC}"
    elif [ "$INITRD_MS" -lt "$INITRD_MOD_MS" ]; then echo -e "Initrd Phase:  ${GREEN}A  (Highly Optimized Hardware Hook)${NC}"
    else echo -e "Initrd Phase:  ${YELLOW}B- (Sluggish Device Initialization)${NC}"; fi

    if [ "$INITRD_FAST_MS" -eq 2500 ]; then
        echo -e "  ${BLUE}Note: TPM2-sealed LUKS unlock active — fTPM device readiness on slow${NC}"
        echo -e "  ${BLUE}hardware (e.g. Surface's Intel PTT) routinely adds several seconds here.${NC}"
    fi
fi

if [ -z "$USER_MS" ]; then
    echo -e "Userspace:     ${BLUE}N/A${NC}"
elif [ "$USER_MS" -lt 2000 ]; then echo -e "Userspace:     ${GREEN}A+ (Fast Service Handoff)${NC}"
elif [ "$USER_MS" -lt 5000 ]; then echo -e "Userspace:     ${GREEN}A  (Crisp Service Handoff)${NC}"
else echo -e "Userspace:     ${YELLOW}B  (Serialized Service Bottleneck)${NC}"; fi

if [ "$(awk -v a="$AVG_EXPOSURE" 'BEGIN {print (a < 2.5)?1:0}')" -eq 1 ]; then
    echo -e "Security:      ${GREEN}A+ (Actionable Services Fully Hardened)${NC}"
elif [ "$(awk -v a="$AVG_EXPOSURE" 'BEGIN {print (a < 5.0)?1:0}')" -eq 1 ]; then
    echo -e "Security:      ${GREEN}A  (Minor Hardening Headroom)${NC}"
elif [ "$(awk -v a="$AVG_EXPOSURE" 'BEGIN {print (a < 7.0)?1:0}')" -eq 1 ]; then
    echo -e "Security:      ${YELLOW}B  (Some Actionable Services Unsandboxed)${NC}"
else
    echo -e "Security:      ${YELLOW}C  (Most Actionable Services Unsandboxed)${NC}"
fi

echo -e "${BOLD}${BLUE}=========================================${NC}"
