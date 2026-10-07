# nixos-dots

A NixOS flake for four machines: a desktop, a Surface Pro 7+, a thin client on the TV and a Raspberry Pi. Its distinctive parts are a theme engine that recolours the whole desktop live, a tablet mode that follows the Surface's keyboard, and some fleet tooling that keeps the machines in step.

It succeeds [dotfiles](https://github.com/SW-philip/dotfiles), which I no longer update. That one has a very different aesthetic and is still there if you want to fork it.

![desktop](assets/screenshots/desktop.png)

This is tuned to my hardware and habits. Read it and borrow from it, but expect me to break things regularly and fix them a day or two later. It started as a learning project and still is one.

![control center](assets/screenshots/control-center.png)

## Machines

| host | what | nixpkgs |
|---|---|---|
| `desktop` | i5-9600K, GTX 1660, two FHD monitors on DP (sometimes a TV over HDMI) | unstable |
| `surface` | Surface Pro 7+, linux-surface kernel, 8 GB RAM | nixos-26.05 |
| `retro` | Dell Inspiron 5579 on the TV, a Moonlight kiosk streaming games from the desktop | nixos-26.05 |
| `pi` | Raspberry Pi 3B+, headless git hub that mirrors this repo | nixos-26.05 |

| desktop | surface |
|---|---|
| ![fastfetch on desktop](assets/screenshots/fastfetch-desktop.png) | ![fastfetch on surface](assets/screenshots/fastfetch-surface.png) |

The hosts are on different channels on purpose, so a shared module can't assume either one's option shapes. The Surface offloads its builds to the desktop, because 8 GB of RAM and a kernel build don't mix.

Desktop and Surface use [Lix](https://lix.systems), lanzaboote secure boot, LUKS, btrfs subvolumes and impermanence. Secrets are sops-nix with age.

## What's in it

- **[niri](https://github.com/YaLTeR/niri)** compositor with Waybar, swaync, fuzzel and ghostty. hyprlock is still the lock screen, and the login greeter is a small GTK app in `pkgs/greeter`.
- **Theming.** Every colour comes from a palette file. `scripts/auto-theme.py` generates a palette from a few seed colours, and `drmis` switches the whole desktop to one live. There are 19 palettes in `themes/`; most wallpapers aren't in the repo.
- **[sqlch](https://github.com/SW-philip/sqlch)**, an internet radio player I wrote, is its own flake input.
- **Emulation.** Pegasus, RetroArch cores and standalone emulators in `home/emulation`. The Surface gets a lighter set in `home/emulation-light`.
- **Game streaming.** Sunshine on the desktop, with `retro` as a Moonlight kiosk (`hosts/retro/kiosk.nix`).
- **Shared keyboard and mouse** between desktop and Surface over the network (`pkgs/niri-bridge`).
- **Fleet tooling.**
  - `tree-sync` keeps the working tree in step across machines through the Pi.
  - `fleet-status` records what each host is running and how far behind it is.
  - `quivr` shows live per-host stats in the terminal.
  - `ff` and a Waybar module read the same snapshot.
- **A locked-down kid account** with its own touch-friendly dashboard.
- **Small scripts** for Bluetooth battery levels, notifications, backups and recovery, in `scripts/` and `home/*.nix`.

## Tablet mode

![tablet mode](assets/recordings/tablet-mode.webp)

Detaching the Surface keyboard switches the desktop into tablet mode. The ledger bar grows, and the wing and ledger menus get pull-tabs. Squeekboard opens when you tap a text field or tap the screen with three fingers. A four-finger tap asks in Pegasus whether you want to close it.

## The snark engine

Waybar tooltips, dialogs, the lock screen and failed password attempts get short, dry commentary: insults, passive aggression, the occasional burn. The lines live in `assets/snark-lines.txt`, shared across all of them. It's a joke, but it's wired in properly.

## Layout

```
hosts/<name>/       one machine: hardware, boot, its own services
roles/              system config shared by more than one host
modules/            one-service opt-in modules
identities/         user account declarations
profiles/           per-person, per-host home-manager entrypoints
home/               reusable home-manager modules
pkgs/               things I packaged or wrote
themes/             palettes and per-app theme files
scripts/            helper scripts, one-off and otherwise
assets/             small shared files: icons, snark lines, screenshots
```

## Borrowing from it

Good places to start:

- `scripts/auto-theme.py` and `home/niri/`: palette generation and live theming
- `scripts/tree-sync.sh` and `scripts/fleet-status.sh`: cross-machine sync and drift reporting
- `home/emulation/`: shared emulator setup
- `hosts/retro/kiosk.nix`: the Moonlight kiosk

Before building anything:

- `secrets/*.yaml` are placeholders with my key names and no real values. Make your own age keys, put them in `.sops.yaml` and re-encrypt, or anything that reads a secret will fail.
- Search for `AAAA-REPLACE-WITH-YOUR-PUBLIC-KEY`, `example.ts.net` and the `00:00:00:00:00:0x` Bluetooth addresses. Those were scrubbed from my real values.
- `hosts/*/hardware.nix` is for my disks. Generate your own.
- The username `prepko` is hardcoded in places.

Flakes only see tracked files, so `git add` new ones first. Build a host with:

```
nh os switch --hostname desktop .     # or surface
```

`retro` and `pi` are deployed remotely with `nixos-rebuild --target-host`. `pi` is aarch64, so build it from a machine with aarch64 binfmt.

## About the history

This repo gets one commit per release, tagged by date (`2026.09.30`). The day-to-day work lives in a private repo, so `git blame` here won't tell you much.

## License

MIT.
