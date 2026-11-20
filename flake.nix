{
  description = "NixOS flake: desktop + surface (unstable), retro + pi (26.05)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    # Desktop's kernel only (hosts/desktop/hardware.nix): the last unstable
    # with zen 7.2.x. 7.3.4-zen1 panicked at boot in a QEMU test of this config.
    nixpkgs-kernel.url = "github:NixOS/nixpkgs/f4a03c008967841f2a0b3cb7c436fc6fc31671f6";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
    home-manager-unstable.url = "github:nix-community/home-manager/master";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";
    # Only lanzaboote's own dev checks use it.
    lanzaboote.inputs.pre-commit.follows = "";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
    impermanence.inputs.home-manager.follows = "home-manager-unstable";
    claude-code.url = "github:sadjow/claude-code-nix";
    claude-code.inputs.nixpkgs.follows = "nixpkgs";
    posys-cursor = {
      url = "github:Morxemplum/posys-cursor-scalable";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    nirinit.url = "github:amaanq/nirinit";
    nirinit.inputs.nixpkgs.follows = "nixpkgs";
    sqlch.url = "github:SW-philip/sqlch/unstable";
    sqlch.inputs.nixpkgs.follows = "nixpkgs";
    tether.url = "github:zackb/tether";
    tether.inputs.nixpkgs.follows = "nixpkgs-unstable";
    parsly.url = "git+ssh://git@github.com/SW-philip/parsly";
    parsly.inputs.nixpkgs.follows = "nixpkgs-unstable";

  };

  outputs = inputs@{
    self,
    nixpkgs,
    nixpkgs-unstable,
    home-manager-unstable,
    lanzaboote,
    claude-code,
    ...
  }:
  let
    system = "x86_64-linux";
    # Module args for every NixOS and home-manager module: the port registry,
    # fleet inventory and themes, so no module imports them by relative path.
    fleetArgs = {
      inherit inputs;
      ports     = import ./hosts/ports.nix;
      inventory = import ./hosts/inventory.nix;
      allThemes = import ./lib/themes.nix { inherit (nixpkgs) lib; };
    };
    pkgsFor = system:
      import nixpkgs {
        inherit system;
        overlays = [ self.overlays.default ];
        config.allowUnfree = true;
      };
    overlayModule = {
      nixpkgs.overlays = [
        self.overlays.default
        claude-code.overlays.default
      ];
    };
    allowUnfreeModule = {
      nixpkgs.config.allowUnfree = true;
    };
    # `nixos-version --configuration-revision` reads this back; fleet-status compares it to git.
    revModule = {
      system.configurationRevision = self.rev or self.dirtyRev or "unknown";
    };

    hmBase = {
      home-manager.useGlobalPkgs = true;
      home-manager.useUserPackages = true;
      home-manager.extraSpecialArgs = fleetArgs;
      # Activate each user's HM environment on-demand at their own login instead
      # of gating all logins on every configured user's activation at boot.
      home-manager.startAsUserService = true;
    };

    # Lix 2.96 from nixpkgs-unstable (cached; stable's `latest` is 2.95, which had
    # regressions) instead of building the upstream flake locally. Workstations only:
    # retro and pi keep their channel's nix, since they're deployed from desktop
    # and never evaluate the flake themselves.
    # pkgs.nix is Lix too, so comma/nix-direnv follow.
    # drop when: unstable's default lixPackageSets is >= 2.96.
    lixModule = { ... }:
      let lix = inputs.nixpkgs-unstable.legacyPackages.${system}.lixPackageSets.lix_2_96.lix;
      in {
        nix.package = lix;
        nixpkgs.overlays = [ (_final: _prev: { inherit lix; nix = lix; }) ];
      };

    # desktop + surface: unstable, lix, impermanence, home-manager. users maps
    # each account to its home-manager entrypoint.
    mkWorkstation = host: users: nixpkgs-unstable.lib.nixosSystem {
      inherit system;
      specialArgs = fleetArgs;
      modules = [
        overlayModule
        allowUnfreeModule
        lanzaboote.nixosModules.lanzaboote
        lixModule
        inputs.impermanence.nixosModules.impermanence
        inputs.nirinit.nixosModules.nirinit
        ./hosts/${host}/config.nix
        home-manager-unstable.nixosModules.home-manager
        hmBase
        { home-manager.users = users; }
        revModule
        { system.stateVersion = "25.11"; }
      ];
    };
  in
  {
    overlays.default = import ./overlays { inherit inputs system; };
    packages.${system} = {
      default          = (pkgsFor system).sqlch;
      uniremote        = (pkgsFor system).uniremote;
      greeter          = (pkgsFor system).greeter;
      niri-bridge      = (pkgsFor system).niri-bridge;
    };
    checks.${system} = {
      surface = self.nixosConfigurations.surface.config.system.build.toplevel;
      desktop = self.nixosConfigurations.desktop.config.system.build.toplevel;
      retro   = self.nixosConfigurations.retro.config.system.build.toplevel;
    };
    checks.aarch64-linux.pi = self.nixosConfigurations.pi.config.system.build.toplevel;
    nixosConfigurations = {
      surface = mkWorkstation "surface" {
        prepko     = ./profiles/prepko/surface.nix;
        kid = ./profiles/kid/surface.nix;
      };
      desktop = mkWorkstation "desktop" {
        prepko = ./profiles/prepko/desktop.nix;
        guest  = ./profiles/guest/desktop.nix;
      };
      retro = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = fleetArgs;
        modules = [
          lanzaboote.nixosModules.lanzaboote
          ./hosts/retro/config.nix
          revModule
          { system.stateVersion = "24.11"; }
        ];
      };

      pi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = fleetArgs;
        modules = [
          ./hosts/pi/config.nix
          revModule
          { system.stateVersion = "26.05"; }
        ];
      };

      installer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = fleetArgs // { inherit self; };
        modules = [
          overlayModule
          allowUnfreeModule
          ./hosts/installer/config.nix
        ];
      };

    };
  };
}
