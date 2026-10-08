{ p, l, barHeight ? 45, cursorSize ? 48, isDesktop ? false, toggleOskBin ? "toggle-osk", launcherBin ? "launcher", sidebarToggleBin ? "swaync-toggle", lockScreenBin ? "hyprlock" }:
let
  # Remote-window colours: which accent is far enough from ROOT (the local focused border)
  # depends on the theme, so rank FIFTH/SEVENTH/SOTTO by RGB distance from ROOT and hand
  # the farthest to desktop, the next to surface, the last to retro/pi.
  hexDigit = {
    "0" = 0; "1" = 1; "2" = 2; "3" = 3; "4" = 4; "5" = 5; "6" = 6; "7" = 7; "8" = 8; "9" = 9;
    a = 10; b = 11; c = 12; d = 13; e = 14; f = 15;
    A = 10; B = 11; C = 12; D = 13; E = 14; F = 15;
  };
  hexByte = s: i: 16 * hexDigit.${builtins.substring i 1 s} + hexDigit.${builtins.substring (i + 1) 1 s};
  sq = x: x * x;
  dist2 = a: b:
    sq (hexByte a 1 - hexByte b 1) + sq (hexByte a 3 - hexByte b 3) + sq (hexByte a 5 - hexByte b 5);
  ranked = builtins.sort (a: b: dist2 p.ROOT a > dist2 p.ROOT b) [ p.FIFTH p.SEVENTH p.SOTTO ];
  remoteColor = {
    desktop = builtins.elemAt ranked 0;
    surface = builtins.elemAt ranked 1;
    other   = builtins.elemAt ranked 2;
  };
in
''
// home/niri/config.kdl — niri cleanroom compositor config

// ── Input ──────────────────────────────────────────────────
input {
    keyboard {
        xkb {
            layout "us"
        }
        repeat-delay 250
        repeat-rate 40
    }

    touchpad {
        tap
        natural-scroll
        scroll-factor 0.6
    }

    mouse {
        accel-speed 0.0
    }

    focus-follows-mouse max-scroll-amount="0%"
}

// ── XWayland bridge ────────────────────────────────────────
// xwayland-satellite provides rootful XWayland for X11 apps under niri.
// It is NOT spawned here anymore — niri itself spawns it lazily, on its
// own, the moment any X11 client actually tries to connect (confirmed
// live; no launcher wrapper involved). Niri never tears it back down on
// its own, though, so home/niri/xwayland-satellite.nix runs a generic
// systemd --user timer that kills it once no XWayland windows remain —
// covers any X11 app, not just a specific one.
//
// Env propagation lives in the `environment {}` block below + `niri --session`'s
// own import into systemd/D-Bus.

// ── Outputs ────────────────────────────────────────────────
// Desktop: dual 1080p
output "DP-1" {
    mode "1920x1080@60.000"
    position x=0 y=0
    scale 1.25
}
output "DP-2" {
    mode "1920x1080@60.000"
    position x=1536 y=0
    scale 1.25
}
// Surface: HiDPI internal display
output "eDP-1" {
    mode "2736x1824@60.000"
    scale 2.0
}
// Desktop couch mode: 65" Samsung 4K TV. EDID has no 4K60 mode at all (cable/port
// bandwidth cap) — niri's preferred-mode pick was 3840x2160@30, which
// judders any 60fps-vsync'd content (RetroArch cores, niri's own window
// animations). Pinned to a real 60Hz mode instead; scale 1.5 keeps the
// same 1280x720 logical/couch-readable size that scale 3.0 gave at 4K.
// If still too small try scale 1.125 (→ 1706×960). Check name with: niri msg outputs
output "HDMI-A-1" {
    mode "1920x1080@60.000"
    scale 1.5
}

// ── Layout ────────────────────────────────────────────────
layout {
    gaps ${toString l.gap}

    // Transparent so the backdrop-pinned swaybg wallpaper (see layer-rule
    // below) shows through instead of niri's own opaque per-workspace fill.
    background-color "transparent"

    border {
        width ${toString l.borderW}
        active-color "${p.ROOT}"
        // Neutral flat keyline, not a solid tone — 0x26/0xff ≈ 0.15,
        // matching alpha(SCORE, 0.15) in home/waybar/style.nix.
        inactive-color "${p.SCORE}26"
        urgent-color "${p.FORTE}"
    }

    shadow {
        // The house hard offset — same as waybar/swaync's shellOffset
        // (3px 4px 0 0 rgba(STAFF, STAFF_A_DROP)). niri windows are shells.
        on
        softness 0
        spread 0
        offset x=3 y=4
        color "rgba(${p.STAFF}, ${p.STAFF_A_DROP})"
    }

    focus-ring {
        off
    }

    preset-column-widths {
        proportion 0.333
        proportion 0.5
        proportion 0.666
        proportion 1.0
    }

    default-column-width { proportion 0.5; }

    struts {
        top 0
        bottom 0
    }
}

// ── Workspaces ────────────────────────────────────────────
// Declared in this order so Mod+1-5 (binds below) keep targeting these
// positionally.
workspace "code"
workspace "browse"
workspace "media"
workspace "scratch"
workspace "office"

// ── Appearance ────────────────────────────────────────────
prefer-no-csd

cursor {
    xcursor-theme "posys_cursor_scalable"
    xcursor-size ${toString cursorSize}
}

environment {
    XCURSOR_THEME "posys_cursor_scalable"
    XCURSOR_SIZE "${toString cursorSize}"
    XDG_CURRENT_DESKTOP "niri"
    XDG_SESSION_DESKTOP "niri"
    // xwayland-satellite binds to :0; set DISPLAY here so all niri-spawned
    // apps (Steam, etc.) inherit it rather than racing import-environment.
    DISPLAY ":0"
}

// ── Animations ────────────────────────────────────────────
animations {
    slowdown 0.8

    workspace-switch {
        spring damping-ratio=1.0 stiffness=800 epsilon=0.001
    }
    window-open {
        duration-ms 150
    }
    window-close {
        duration-ms 100
    }
}

// niri 26.04+ background blur (ext-background-effect). `on` is explicit
// (matching this file's shadow{}/focus-ring{} convention below) rather
// than relying on an unconfirmed default. Xray mode — cheap, blurs a
// static wallpaper snapshot rather than live content — is a per-rule
// background-effect property, not set here. Desktop (GTX 1660) drops
// xray on fuzzel + the ghostty surfaces for real live frost; surface
// (Iris iGPU) keeps xray everywhere. The auto-wallpaper is smooth and
// same-palette, so xray blur over it is visually a no-op — live blur is
// the only way the effect actually reads.
blur {
    on
    passes 3
}

// Pin swaybg into the backdrop so it stays put during workspace-switch/
// overview animations instead of sliding with the viewport.
layer-rule {
    match namespace="^wallpaper$"
    place-within-backdrop true
}

// ── Window rules ──────────────────────────────────────────
// No `match` predicate — applies to every window. radiusMd (8): a middle
// rounding between waybar's 7px modules and its 18px shell panels.
window-rule {
    geometry-corner-radius ${toString l.radiusMd}
    clip-to-geometry true
}
window-rule {
    match app-id="weather-radar"
    open-floating true
    default-column-width { fixed 512; }
    default-window-height { fixed 512; }
    opacity 0.92
    background-effect {
        blur true
        xray true
    }
}
window-rule {
    match app-id="dev.prepko.drmis-pick"
    open-floating true
    default-column-width { fixed 720; }
    default-window-height { fixed 560; }
}
window-rule {
    match app-id="com.prepko.uniremote"
    open-floating true
    default-column-width { fixed 320; }
    default-window-height { fixed 680; }
    opacity 0.92
    background-effect {
        blur true
        xray true
    }
}
// No fixed size — lix-logout should hug its own content (a small button
// row), not be forced to a guessed dimension. Floating windows open
// centered by default.
// quivr: a floating, square-cornered panel (waybar fleet click toggles it).
// Later rule, so the zero radius overrides the global radiusMd.
window-rule {
    match app-id="dev.prepko.quivr"
    open-floating true
    default-column-width { fixed 880; }
    default-window-height { fixed 520; }
    geometry-corner-radius 0
    clip-to-geometry true
}
window-rule {
    match app-id="dev.prepko.lix-logout"
    open-floating true
    opacity 0.92
    background-effect {
        blur true
        xray true
    }
}
// Steam Big Picture (Steam launched with -uimode=7) reports app-id "steam" —
// identical to the desktop library window — so match its title to fullscreen
// only Big Picture, not the library. Without this, niri opens it as a 0.5
// proportion column beside whatever game Steam launches, so the two share the
// screen half-and-half. Title confirmed live via `niri msg windows` 2026-08-27.
window-rule {
    match title="^Steam Big Picture Mode$"
    open-fullscreen true
}

// Native Steam games report their title as app-id and otherwise open as a
// small window in a new column beside Pegasus, off-screen and unfocused: you
// hear the game while Pegasus stays on top. Stardew confirmed live 2026-10-03.
window-rule {
    match app-id="^Stardew Valley$"
    open-fullscreen true
    open-focused true
}

// Emulators: niri-fullscreen (compositor-level, no waybar strip or gaps, so
// no top/bottom bars), still not the emulators' own exclusive fullscreen.
// xemu/azahar/eden used to launch with their own -full-screen/-f flags
// (hosts/desktop/config.nix); on this box that coincided with the Bluetooth
// adapter dropping its connected device, so those flags stay dropped and
// RetroArch's video_fullscreen is pinned to false (home/emulation/default.nix):
// every emulator opens windowed, then niri fullscreens it here. If the
// Bluetooth drop returns, swap open-fullscreen back to open-maximized.
// App-ids confirmed live via `niri msg windows` on 2026-08-09 — re-check the
// same way after any emulator update, since at least one (eden) didn't match
// its own .desktop file's declared StartupWMClass.
window-rule {
    match app-id="com.libretro.RetroArch"   // nes/snes/genesis/gba/psx/n64/saturn/dreamcast
    match app-id="dolphin-emu"              // gamecube/wii
    match app-id="cemu"                     // wiiu
    match app-id="app.xemu.xemu"            // xbox
    match app-id="org.azahar_emu.Azahar"    // 3ds
    match app-id="dev.eden_emu.eden"        // switch
    open-fullscreen true
}
// ppsspp (psp) and rpcs3 (ps3) below are UNVERIFIED best-guesses (from
// each package's Exec name / declared StartupWMClass) — neither would
// launch a window in the sandbox used to confirm the others above. Check
// with `niri msg windows` next time either is open and fix the app-id if
// it silently isn't going fullscreen.
window-rule {
    match app-id="ppsspp"
    match app-id="rpcs3"
    open-fullscreen true
}
// pcsx2-qt (ps2) reports an empty app-id under niri (XWayland gap — see
// "Things Claude Gets Wrong Here" in CLAUDE.md), so no window-rule can
// target it. It already launches windowed (no fullscreen flag), so it
// was never part of the Bluetooth-drop issue; maximize manually with
// Mod+M if wanted.

// Floating utilities (weather-radar, uniremote, drmis-pick) inherit the
// layout{} shadow — no override. Their focus cue stays neutral (the flat
// "thread" tone, 0x8c/0xff ≈ 0.55) so a transient popup never grabs the
// ROOT accent. inactive-color is inherited (keyline).
window-rule {
    match is-floating=true
    border {
        active-color "${p.SCORE}8c"
    }
}

// Windows running on another fleet host (`on` / app-launch, via waypipe's
// --title-prefix "[<host>] "). Shape first, shared by every host: square corners
// (local windows are rounded), a 4px border (local is 2) and a hard offset shadow,
// the house shadow's shape in the host's colour instead of STAFF. Colour per host
// next, none of them ROOT (the local focused border), inactive dimmed so a remote
// window stays recognisable when unfocused. After the is-floating rule so a
// floating remote window keeps all of it.
window-rule {
    match title="^\\[(desktop|surface|retro|pi)\\] "
    geometry-corner-radius 0
    border {
        width 4
    }
    shadow {
        on
        softness 0
        spread 0
        offset x=6 y=7
    }
}
window-rule {
    match title="^\\[desktop\\] "
    border {
        active-color "${remoteColor.desktop}"
        inactive-color "${remoteColor.desktop}66"
    }
    shadow {
        color "${remoteColor.desktop}99"
    }
}
window-rule {
    match title="^\\[surface\\] "
    border {
        active-color "${remoteColor.surface}"
        inactive-color "${remoteColor.surface}66"
    }
    shadow {
        color "${remoteColor.surface}99"
    }
}
window-rule {
    match title="^\\[(retro|pi)\\] "
    border {
        active-color "${remoteColor.other}"
        inactive-color "${remoteColor.other}66"
    }
    shadow {
        color "${remoteColor.other}99"
    }
}

// Frosted terminal: ghostty's own background-opacity (set in
// home/ghostty/config.nix) fades only the background, not text — paired
// with blur true here so what's behind shows through blurred. Also
// matches ghostty windows spawned with a custom --class (drmis-pick,
// volume-popup): they still inherit ghostty's global
// background-opacity even though niri sees a different app-id, so they
// need this rule too or they'd render translucent with nothing blurred
// behind them. drmis-pick gets its opacity/blur ONLY here, not also in
// its own floating-window rule above — ghostty's background-opacity
// already dims it; stacking niri's window opacity on top would
// double-dim its text. Deliberately its own block, not merged into the
// app-id="com.mitchellh.ghostty" rule below (which also matches Zed,
// which should stay opaque). Desktop drops xray for live frost (blurs
// the real windows behind, not the flat same-palette wallpaper);
// surface keeps xray for the iGPU.
window-rule {
    match app-id="com.mitchellh.ghostty"
    match app-id="dev.prepko.drmis-pick"
    match app-id="dev.prepko.volume-popup"
    match app-id="dev.prepko.quivr"
    background-effect {
        blur true
        ${if isDesktop then "" else "xray true"}
    }
}

// ── Workspace routing ─────────────────────────────────────
// Multiple `match` lines in one window-rule are OR'd, so apps sharing a
// destination workspace are grouped into a single block.
window-rule {
    match app-id="com.mitchellh.ghostty"
    match app-id="dev.zed.Zed"
    open-on-workspace "code"
}
window-rule {
    match app-id="firefox"
    match app-id="thunderbird"
    match app-id="element"
    open-on-workspace "browse"
}
window-rule {
    match app-id="vlc"
    match app-id="steam"
    match app-id="spotify"
    open-on-workspace "media"
}
window-rule {
    match app-id="nemo"
    match app-id="nwg-look"
    match app-id="org.kde.kdenlive"
    match app-id="krita"
    match app-id="org.kde.easyeffects"
    open-on-workspace "scratch"
}
// LibreOffice's app-id is module-specific (e.g. "libreoffice-writer"), so
// a prefix match catches Writer/Calc/Impress/etc. under one rule.
window-rule {
    match app-id="^libreoffice"
    open-on-workspace "office"
}
// ── Layer rules ───────────────────────────────────────────
// PARKED 2026-07-23: sidebar blur removed. waybar and swaync are fully
// opaque on purpose — matching swaync's .control-center — not a translucent
// fill meant to be frosted by this blur. Blurring behind a fully opaque
// surface has no visible effect, so the layer-rules were dead weight.
// waybar/swaync stay opaque on purpose (still true as of 2026-09-04) —
// this doesn't apply to them.

// fuzzel's wlr-layer-shell namespace defaults to "launcher" — still used
// for the dmenu-style pickers (Mod+V clipboard, power-profile). Paired with
// home/fuzzel/colors.nix's alpha background. Desktop drops xray for live
// frost; surface keeps xray.
layer-rule {
    match namespace="^launcher$"
    background-effect {
        blur true
        ${if isDesktop then "" else "xray true"}
    }
}

// ── Bindings ──────────────────────────────────────────────
binds {
    // Apps
    Mod+Return { spawn "ghostty"; }
    Mod+Space  { spawn "${launcherBin}"; }
    Mod+E      { spawn "nemo"; }
    Mod+V      { spawn "bash" "-c" "cliphist list | fuzzel --dmenu | cliphist decode | wl-copy"; }
    Mod+B      { spawn "${sidebarToggleBin}"; }
    ${if !isDesktop then ''Mod+Shift+W { spawn "${toggleOskBin}"; }'' else ""}
    // Triple-finger tap on the touchpad = middle-click by niri's default
    // tap-button-map (left-right-middle), so this binding doubles as a
    // 3-finger-tap toggle without needing a separate gesture config.
    ${if !isDesktop then ''MouseMiddle { spawn "${sidebarToggleBin}"; }'' else ""}

    // Windows
    Mod+Q { close-window; }
    Mod+F { fullscreen-window; }
    Mod+Shift+F  { toggle-window-floating; }
    Mod+Ctrl+F   { switch-focus-between-floating-and-tiling; }
    Mod+M        { maximize-column; }
    Mod+BracketLeft  { consume-or-expel-window-left; }
    Mod+BracketRight { consume-or-expel-window-right; }

    // Focus — hjkl or arrows
    Mod+H { focus-column-left; }
    Mod+L { focus-column-right; }
    Mod+J { focus-window-down; }
    Mod+K { focus-window-up; }
    Mod+Left  { focus-column-left; }
    Mod+Right { focus-column-right; }
    Mod+Down  { focus-window-down; }
    Mod+Up    { focus-window-up; }

    // Move windows
    Mod+Shift+H { move-column-left; }
    Mod+Shift+L { move-column-right; }
    Mod+Shift+J { move-window-down; }
    Mod+Shift+K { move-window-up; }

    // Resize
    Mod+R { switch-preset-column-width; }
    Mod+Shift+R { spawn "niri" "msg" "action" "load-config-file"; }
    Mod+Minus { set-column-width "-5%"; }
    Mod+Equal { set-column-width "+5%"; }
    Mod+Shift+Minus { set-window-height "-5%"; }
    Mod+Shift+Equal { set-window-height "+5%"; }

    // Workspaces
    Mod+1 { focus-workspace 1; }
    Mod+2 { focus-workspace 2; }
    Mod+3 { focus-workspace 3; }
    Mod+4 { focus-workspace 4; }
    Mod+5 { focus-workspace 5; }
    Mod+Shift+1 { move-column-to-workspace 1; }
    Mod+Shift+2 { move-column-to-workspace 2; }
    Mod+Shift+3 { move-column-to-workspace 3; }
    Mod+Shift+4 { move-column-to-workspace 4; }
    Mod+Shift+5 { move-column-to-workspace 5; }
    Mod+Tab              { focus-workspace-down; }
    Mod+Shift+Tab        { focus-workspace-up; }
    Mod+Ctrl+Tab         { move-column-to-workspace-down; }
    Mod+Ctrl+Shift+Tab   { move-column-to-workspace-up; }

    // Monitors
    Mod+Comma  { focus-monitor-left; }
    Mod+Period { focus-monitor-right; }
    Mod+Shift+Comma  { move-column-to-monitor-left; }
    Mod+Shift+Period { move-column-to-monitor-right; }
    Mod+Ctrl+Shift+Comma  { spawn "drmis" "prev"; }
    Mod+Ctrl+Shift+Period { spawn "drmis" "next"; }
    Mod+Ctrl+Shift+M      { spawn "drmis" "mode" "toggle"; }
    Mod+Ctrl+D { spawn "kanshictl" "switch" "desktop-dual"; }
    Mod+Ctrl+S { spawn "kanshictl" "switch" "desktop-single-dp2"; }

    // Panel edges (wing/ledger eww bars — see home/eww/scripts/panel-edge.sh)
    Mod+Ctrl+Left  { spawn "eww-panel-step" "wing" "left"; }
    Mod+Ctrl+Right { spawn "eww-panel-step" "wing" "right"; }
    Mod+Ctrl+Up    { spawn "eww-panel-step" "ledger" "up"; }
    Mod+Ctrl+Down  { spawn "eww-panel-step" "ledger" "down"; }

    // Scroll through columns
    Mod+WheelScrollRight cooldown-ms=150 { focus-column-right; }
    Mod+WheelScrollLeft  cooldown-ms=150 { focus-column-left; }

    // Media / system
    XF86AudioRaiseVolume  allow-when-locked=true { spawn "bash" "-c" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"; }
    XF86AudioLowerVolume  allow-when-locked=true { spawn "bash" "-c" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"; }
    XF86AudioMute         allow-when-locked=true { spawn "bash" "-c" "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
    F6  allow-when-locked=true { spawn "bash" "-c" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%+"; }
    F5  allow-when-locked=true { spawn "bash" "-c" "wpctl set-volume @DEFAULT_AUDIO_SINK@ 5%-"; }
    F4  allow-when-locked=true { spawn "bash" "-c" "wpctl set-mute @DEFAULT_AUDIO_SINK@ toggle"; }
    XF86AudioPlay  { spawn "playerctl" "play-pause"; }
    XF86AudioNext  { spawn "playerctl" "next"; }
    XF86AudioPrev  { spawn "playerctl" "previous"; }
    XF86MonBrightnessUp   { spawn "brightnessctl" "set" "+5%"; }
    XF86MonBrightnessDown { spawn "brightnessctl" "set" "5%-"; }

    // Screenshot
    Print { screenshot; }
    Ctrl+Print { screenshot-screen; }
    Alt+Print  { screenshot-window; }
    Mod+Print  { spawn "shoot-annotate"; }
    Mod+Shift+Print { spawn "screen-record-toggle"; }

    // Overview / help
    Mod+O     { toggle-overview; }
    Mod+Slash { show-hotkey-overlay; }

    // Session
    Mod+Escape { spawn "${lockScreenBin}"; }
    Mod+Shift+E { quit; }
    Mod+Shift+P { power-off-monitors; }
}
''
