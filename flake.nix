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
      pkgsMsvc = mkPkgs { acceptMicrosoftVisualStudioLicense = builtins.getEnv "DAUNTLESS_NIX_ACCEPT_MSVC_LICENSE" == "1"; };

      msvcPackagesFor = p: rec {
        msvc-toolchain = p.callPackage ./nix/pkgs/msvc-toolchain.nix { };
        dumper7 = p.callPackage ./nix/pkgs/dumper7.nix { msvcToolchain = msvc-toolchain; };
      };
    in {
      packages.${system} = {
        legendary = pkgs.callPackage ./nix/pkgs/legendary.nix { };
        gitleaks = pkgs.gitleaks; # used by nix/git-hooks/pre-commit, same pin as everything else
        backend = pkgs.callPackage ./nix/pkgs/backend.nix { };
        runtime-loader = pkgs.callPackage ./nix/pkgs/runtime-loader.nix { };
        proton-run = pkgs.callPackage ./nix/pkgs/proton-run.nix { };
        default = self.packages.${system}.legendary;
      } // msvcPackagesFor pkgsMsvc;

      # For modules / downstream flakes: lib.msvcPackages { acceptMicrosoftVisualStudioLicense = true; }
      lib.msvcPackages = args: msvcPackagesFor (mkPkgs args);

      nixosModules.server = { lib, ... }: {
        imports = [ ./nix/modules/server.nix ];
        services.dauntless-nix.package = lib.mkDefault self.packages.${system}.backend;
      };

      checks.${system}.server = import ./nix/tests/server.nix { inherit self pkgs; };
    };
}
