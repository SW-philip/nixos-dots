{
  description = "NixOS flake: desktop (unstable) + surface (26.05)";
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixos-unstable";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
    nixos-hardware.inputs.nixpkgs.follows = "nixpkgs";
    home-manager.url = "github:nix-community/home-manager/release-26.05";
    home-manager.inputs.nixpkgs.follows = "nixpkgs";
    home-manager-unstable.url = "github:nix-community/home-manager/master";
    home-manager-unstable.inputs.nixpkgs.follows = "nixpkgs-unstable";
    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";
    lanzaboote.url = "github:nix-community/lanzaboote";
    lanzaboote.inputs.nixpkgs.follows = "nixpkgs";
    impermanence.url = "github:nix-community/impermanence";
    impermanence.inputs.nixpkgs.follows = "nixpkgs";
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

  };

  outputs = inputs@{
    self,
    nixpkgs,
    nixpkgs-unstable,
    nixos-hardware,
    home-manager,
    home-manager-unstable,
    lanzaboote,
    claude-code,
    ...
  }:
  let
    system = "x86_64-linux";
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
      home-manager.extraSpecialArgs = { inherit inputs; };
      # Activate each user's HM environment on-demand at their own login instead
      # of gating all logins on every configured user's activation at boot.
      home-manager.startAsUserService = true;
    };

    # Lix 2.96 from nixpkgs-unstable (cached; stable's `latest` is 2.95, which had
    # regressions) on both channels instead of building the upstream flake locally.
    # pkgs.nix is Lix too, so comma/nix-direnv follow.
    # drop when: the default lixPackageSets on both channels is >= 2.96.
    lixModule = { ... }:
      let lix = inputs.nixpkgs-unstable.legacyPackages.${system}.lixPackageSets.lix_2_96.lix;
      in {
        nix.package = lix;
        nixpkgs.overlays = [ (final: prev: { inherit lix; nix = lix; }) ];
      };

    hmPrepkoDesktop = {
      home-manager.users.prepko = ./profiles/prepko/desktop.nix;
    };
    hmPrepkoSurface = {
      home-manager.users.prepko = ./profiles/prepko/surface.nix;
    };

    hmKid = {
      home-manager.users.kid = ./profiles/kid/surface.nix;
    };
  in
  {
    overlays.default = import ./overlays { inherit inputs system; };
    packages.${system} = {
      default          = (pkgsFor system).sqlch;
      uniremote        = (pkgsFor system).uniremote;
      greeter          = (pkgsFor system).greeter;
      lix-plymouth     = (pkgsFor system).lix-plymouth;
      dsa-plymouth     = (pkgsFor system).dsa-plymouth;
      niri-bridge      = (pkgsFor system).niri-bridge;
    };
    checks.${system} = {
      surface = self.nixosConfigurations.surface.config.system.build.toplevel;
      desktop = self.nixosConfigurations.desktop.config.system.build.toplevel;
      retro   = self.nixosConfigurations.retro.config.system.build.toplevel;
    };
    checks.aarch64-linux.pi = self.nixosConfigurations.pi.config.system.build.toplevel;
    nixosConfigurations = {
      surface = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit inputs;
        };
        modules = [
          overlayModule
          allowUnfreeModule
          lanzaboote.nixosModules.lanzaboote
          lixModule
          inputs.impermanence.nixosModules.impermanence
          inputs.nirinit.nixosModules.nirinit
          ./hosts/surface/config.nix
          ./cachix.nix
          home-manager.nixosModules.home-manager
          hmBase
          hmPrepkoSurface
          hmKid
          revModule
          { system.stateVersion = "25.11"; }
        ];
      };
      desktop = nixpkgs-unstable.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          overlayModule
          allowUnfreeModule
          lixModule
          inputs.impermanence.nixosModules.impermanence
          inputs.nirinit.nixosModules.nirinit
          ./hosts/desktop/config.nix
          ./cachix.nix
          ./modules/virt.nix
          lanzaboote.nixosModules.lanzaboote
          home-manager-unstable.nixosModules.home-manager
          hmBase
          hmPrepkoDesktop
          revModule
          { system.stateVersion = "25.11"; }
        ];
      };
      retro = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs; };
        modules = [
          lanzaboote.nixosModules.lanzaboote
          ./hosts/retro/config.nix
          revModule
          { system.stateVersion = "24.11"; }
        ];
      };

      pi = nixpkgs.lib.nixosSystem {
        system = "aarch64-linux";
        specialArgs = { inherit inputs; };
        modules = [
          ./hosts/pi/config.nix
          revModule
          { system.stateVersion = "26.05"; }
        ];
      };

      installer = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = { inherit inputs self; };
        modules = [
          overlayModule
          allowUnfreeModule
          ./installer.nix
        ];
      };

    };
  };
}
