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
    lix = {
      # main-branch snapshot, tracking unreleased 2.96.0-dev (no 2.96 tag exists yet).
      # Includes 81084c7fc, the curl >= 8.21 thread-wakeup fix for lix #1234
      # (2.95.3 predates it and hangs flake fetches). Re-pin to a proper
      # release tag once 2.95.4/2.96 ships officially.
      #
      # git+https, not the /archive/<rev>.tar.gz endpoint: git.lix.systems's
      # Forgejo is back up, but its on-demand archive-tarball route still hangs.
      # The git smart-HTTP protocol works and resolves to the same narHash
      # (sha256-Ax+ETbOHatrUnnQqLEwFMAlb+MwJrIjN88c5gTSDRc8=), so lix does not
      # rebuild. rev pinned so the module still sees lix.shortRev.
      url = "git+https://git.lix.systems/lix-project/lix?ref=main&rev=f51148a75bd991fcf9545bb11a0626879795537c";
      flake = false;
    };
    lix-module = {
      url = "git+https://git.lix.systems/lix-project/nixos-module?ref=main&rev=5e56f5a973e24292b125dca9e9d506b0a91d6903";
      inputs.nixpkgs.follows = "nixpkgs";
      inputs.lix.follows = "lix";
    };
    posys-cursor = {
      url = "github:Morxemplum/posys-cursor-scalable";
      inputs.nixpkgs.follows = "nixpkgs-unstable";
    };
    niri-session-manager.url = "github:MTeaHead/niri-session-manager";
    niri-session-manager.inputs.nixpkgs.follows = "nixpkgs";
    sqlch.url = "github:SW-philip/sqlch";
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
    lix,
    lix-module,
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

    lixNoCheck = { lib, ... }: {
      # lib.mkAfter ensures this overlay runs after lix-module's overlay.
      # Override both lix and nix (comma/nix-direnv depend on pkgs.nix).
      # doCheck=false skips checkPhase (meson --suite=check); installCheckPhase=: skips installCheck.
      # doInstallCheck alone is ignored by lix — both overrides are needed.
      nixpkgs.overlays = lib.mkAfter [
        (_: prev: let
          noCheck = prev.lix.overrideAttrs (_: { doCheck = false; installCheckPhase = ":"; });
        in { lix = noCheck; nix = noCheck; })
      ];
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
    overlays.default = final: prev: {
      sqlch                  = prev.callPackage ./pkgs/sqlch { };
      uniremote              = prev.callPackage ./pkgs/uniremote { };
      pandora                = prev.callPackage ./pkgs/pandora { };
      python-ember-mug       = prev.callPackage ./pkgs/python-ember-mug { };
      plymouth-silent-splash = prev.callPackage ./pkgs/plymouth-silent-splash { };
      lix-plymouth           = prev.callPackage ./pkgs/lix-plymouth { };
      dsa-plymouth            = prev.callPackage ./pkgs/dsa-plymouth { };
      greeter                 = prev.callPackage ./pkgs/greeter { };
      lix-logout              = prev.callPackage ./pkgs/lix-logout { };
      # niri-bridge needs rustc >=1.98; nixos-26.05 (the pinned `nixpkgs`
      # this overlay applies to) ships 1.95. Pull just the toolchain from
      # nixpkgs-unstable's raw legacyPackages (an overlay-applied unstable set
      # would re-apply this overlay and recurse on itself).
      # This mixes an unstable-channel rustPlatform/stdenv with stable-channel
      # buildInputs (wayland, pkg-config, fetchFromGitHub) on surface's
      # nixos-26.05-based pkgsFor — confirmed it links fine, but a Task 3
      # home-manager module consuming this package should know it's a
      # cross-channel build, not a from-scratch surprise if it ever breaks.
      niri-bridge             = prev.callPackage ./pkgs/niri-bridge {
        rustPlatform = nixpkgs-unstable.legacyPackages.${system}.rustPlatform;
      };

      # GCC 16 defaults to -std=gnu++20, where pegasus's MOVE_ONLY types
      # (user-declared ctors) are no longer aggregates, so the brace-init in
      # MetaFile.cpp stops compiling. Pin C++17 only on the toolchains that
      # need it so the 26.05 (GCC 15) surface build keeps its cached output.
      pegasus-frontend = if prev.lib.versionAtLeast prev.stdenv.cc.version "16"
        then prev.pegasus-frontend.overrideAttrs (old: {
          cmakeFlags = (old.cmakeFlags or [ ]) ++ [ "-DCMAKE_CXX_STANDARD=17" ];
        })
        else prev.pegasus-frontend;

      # cage 0.2.1 documents XCURSOR_THEME/XCURSOR_SIZE but never passes them to
      # wlroots: the seat cursor is created with (NULL, 24), so wlroots loads the
      # theme literally named "default" (→ black embedded fallback when absent)
      # at a fixed 24px regardless of env. Make it honor the two env vars it
      # already advertises so the greeter can use the posys cursor at a real size.
      cage = prev.cage.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace seat.c \
            --replace-fail 'wlr_xcursor_manager_create(NULL, XCURSOR_SIZE)' \
                           'wlr_xcursor_manager_create(getenv("XCURSOR_THEME"), getenv("XCURSOR_SIZE") ? atoi(getenv("XCURSOR_SIZE")) : XCURSOR_SIZE)'
        '';
      });

      # setuptools 82 dropped pkg_resources upstream. deluge 2.2.0 still does
      # `import pkg_resources` in pluginmanagerbase.py and hasn't been patched
      # in nixpkgs to stop, so deluged.service crashes on every start with
      # ModuleNotFoundError: No module named 'pkg_resources'. nixpkgs kept
      # setuptools_80 (last release that still ships pkg_resources) around for
      # exactly this transition — swap it in for deluge's runtime python env.
      # On channels where nixpkgs' default setuptools hasn't moved past 80.x
      # yet (e.g. stable 26.05), the setuptools_80 alias doesn't exist yet —
      # fall back to whatever setuptools already is in that case.
      deluge-gtk = prev.deluge-gtk.overridePythonAttrs (old: {
        propagatedBuildInputs =
          (prev.lib.filter (p: (p.pname or "") != "setuptools") old.propagatedBuildInputs)
          ++ [ (prev.python3Packages.setuptools_80 or prev.python3Packages.setuptools) ];
      });
      deluged = prev.deluged.overridePythonAttrs (old: {
        propagatedBuildInputs =
          (prev.lib.filter (p: (p.pname or "") != "setuptools") old.propagatedBuildInputs)
          ++ [ (prev.python3Packages.setuptools_80 or prev.python3Packages.setuptools) ];
      });
      deluge = final.deluge-gtk;

      # anyio 4.14.2's tests fail (test_tls_connectable, uvloop unraisable
      # warnings) in the python3.12 set, which Hydra hasn't cached. Scoped to
      # 3.12 on unstable (26.11pre sorts below 26.11, so gate at 26.10; surface's
      # 26.05 keeps its cached builds): python3 (3.14) anyio is cached, and touching it rebuilds
      # firefox/thunderbird/libreoffice from source. Drop once nixpkgs fixes anyio.
      pythonPackagesExtensions = (prev.pythonPackagesExtensions or [ ])
        ++ prev.lib.optional (prev.lib.versionAtLeast prev.lib.version "26.10") (_: pyPrev: prev.lib.optionalAttrs (pyPrev.python.pythonVersion == "3.12") {
          anyio = pyPrev.anyio.overridePythonAttrs (_: {
            doCheck = false;
            doInstallCheck = false;
          });
        });

      # nixos-rebuild-ng's own test suite asserts tempfile.gettempdir() stays
      # under a hardcoded 45-byte limit, but Nix build-sandbox TMPDIRs
      # (/nix/var/nix/b/<hash>/b) are always longer than that — so
      # installCheckPhase (this package's tests run there, gated by
      # doInstallCheck, not doCheck/checkPhase) fails on every build
      # regardless of anything in this config. Broken in nixpkgs as of the
      # 2026-07-14 channel bump; drop this once upstream fixes test_tmpdir.py.
      nixos-rebuild-ng = prev.nixos-rebuild-ng.overrideAttrs (old: {
        doInstallCheck = false;
      });

      # azahar 2125.1.3's cubeb_sink.cpp/cubeb_input.cpp call std::memset /
      # std::memcpy but never #include <cstring> directly -- they relied on
      # it arriving transitively through another standard header. GCC 15
      # (this system's stdenv.cc) tightened libstdc++'s transitive includes,
      # so the build now fails with "'memset' is not a member of 'std'".
      # Upstream hasn't picked up the missing include yet; patch it in.
      azahar = prev.azahar.overrideAttrs (old: {
        postPatch = (old.postPatch or "") + ''
          substituteInPlace src/audio_core/cubeb_sink.cpp \
            --replace-fail '#include <cubeb/cubeb.h>' \
                           '#include <cstring>
          #include <cubeb/cubeb.h>'
          substituteInPlace src/audio_core/cubeb_input.cpp \
            --replace-fail '#include <cubeb/cubeb.h>' \
                           '#include <cstring>
          #include <cubeb/cubeb.h>'
        '';
      });
    };
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
          lix-module.nixosModules.default
          lixNoCheck
          inputs.impermanence.nixosModules.impermanence
          inputs.niri-session-manager.nixosModules.niri-session-manager
          ./hosts/surface/config.nix
          ./cachix.nix
          ./modules/cachix-push.nix
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
          lix-module.nixosModules.default
          lixNoCheck
          inputs.impermanence.nixosModules.impermanence
          inputs.niri-session-manager.nixosModules.niri-session-manager
          ./hosts/desktop/config.nix
          ./cachix.nix
          ./modules/cachix-push.nix
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
