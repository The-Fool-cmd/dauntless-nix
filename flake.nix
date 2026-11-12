{
  description = "dauntless-nix: Linux/NixOS packaging for a self-hosted Dauntless 1.14.7 server and clients";

  # Pinned independently of any host's system nixpkgs so Proton/Wine and tools never move on a system update.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a50de1b7d8a586adc18d2395c19de7d6058e6030";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      lib = nixpkgs.lib;

      # Unfree pieces, each allowed by name: the Steam FHS runtime that hosts Proton, Microsoft's SDK (separately gated
      # by its own license switch below), and Dumper-7 (no upstream license: build locally, never redistribute).
      unfreeAllowed = [ "steam" "steam-run" "steam-unwrapped" "win-sdk" "xwin-fetch-msvc" "dumper7" ];

      # Microsoft's license for the MSVC CRT/Windows SDK download must be accepted by whoever builds, never inherited
      # from this repo. Modules pass it explicitly; CLI builds opt in per command:
      #   DAUNTLESS_NIX_ACCEPT_MSVC_LICENSE=1 nix build --impure .#dumper7
      mkPkgs = { acceptMicrosoftVisualStudioLicense ? false }: import nixpkgs {
        inherit system;
        config.allowUnfreePredicate = p: builtins.elem (lib.getName p) unfreeAllowed;
        config.microsoftVisualStudioLicenseAccepted = acceptMicrosoftVisualStudioLicense;
      };
      pkgs = mkPkgs { };
      # Only true for `DAUNTLESS_NIX_ACCEPT_MSVC_LICENSE=1 nix ... --impure`. Pure evaluation (nix flake check, CI,
      # anyone who has not opted in) never sees the MSVC packages, so nothing evaluates the license gate.
      msvcAccepted = builtins.getEnv "DAUNTLESS_NIX_ACCEPT_MSVC_LICENSE" == "1";
      pkgsMsvc = mkPkgs { acceptMicrosoftVisualStudioLicense = msvcAccepted; };

      msvcPackagesFor = p: rec {
        msvc-toolchain = p.callPackage ./nix/pkgs/msvc-toolchain.nix { };
        dumper7 = p.callPackage ./nix/pkgs/dumper7.nix { msvcToolchain = msvc-toolchain; };
        # runtime { sdk = <CppSDK store path>; publicHost = "..."; }
        runtime = args: p.callPackage ./nix/pkgs/runtime.nix ({
          msvcToolchain = msvc-toolchain;
          runtimeLoader = p.callPackage ./nix/pkgs/runtime-loader.nix { };
        } // args);
      };
    in {
      packages.${system} = {
        legendary = pkgs.callPackage ./nix/pkgs/legendary.nix { };
        gitleaks = pkgs.gitleaks; # used by nix/git-hooks/pre-commit, same pin as everything else
        backend = pkgs.callPackage ./nix/pkgs/backend.nix { };
        runtime-loader = pkgs.callPackage ./nix/pkgs/runtime-loader.nix { };
        director = pkgs.callPackage ./nix/pkgs/director.nix { };
        launcher = pkgs.callPackage ./nix/pkgs/launcher.nix { };
        gameserver-wine = pkgs.callPackage ./nix/pkgs/gameserver-wine.nix { };
        proton-run = pkgs.callPackage ./nix/pkgs/proton-run.nix { };
        default = self.packages.${system}.legendary;
      } // lib.optionalAttrs msvcAccepted (removeAttrs (msvcPackagesFor pkgsMsvc) [ "runtime" ]);

      # For modules / downstream flakes: lib.msvcPackages { acceptMicrosoftVisualStudioLicense = true; }
      lib.msvcPackages = args: msvcPackagesFor (mkPkgs args);

      nixosModules.server = { lib, ... }: {
        imports = [ ./nix/modules/server.nix ./nix/modules/director.nix ./nix/modules/wireguard.nix ];
        services.dauntless-nix.package = lib.mkDefault self.packages.${system}.backend;
        services.dauntless-nix.director.package = lib.mkDefault self.packages.${system}.director;
        services.dauntless-nix.director.gameserverBinary =
          lib.mkDefault (lib.getExe self.packages.${system}.gameserver-wine);
      };

      nixosModules.client = { lib, ... }: {
        imports = [ ./nix/modules/client.nix ];
        services.dauntless-nix-client = {
          launcherPackage = lib.mkDefault self.packages.${system}.launcher;
          protonRunPackage = lib.mkDefault self.packages.${system}.proton-run;
          legendaryPackage = lib.mkDefault self.packages.${system}.legendary;
        };
      };

      checks.${system}.server = import ./nix/tests/server.nix { inherit self pkgs; };
    };
}
