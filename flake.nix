{
  description = "dauntless-nix: Linux/NixOS packaging for a self-hosted Dauntless 1.14.7 server and clients";

  # Pinned independently of any host's system nixpkgs so Proton/Wine and tools never move on a system update.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a50de1b7d8a586adc18d2395c19de7d6058e6030";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        # Only the Steam FHS runtime used to host Proton is unfree.
        config.allowUnfreePredicate = p: builtins.elem (nixpkgs.lib.getName p) [ "steam" "steam-run" "steam-unwrapped" ];
      };
    in {
      packages.${system} = {
        legendary = pkgs.callPackage ./nix/pkgs/legendary.nix { };
        gitleaks = pkgs.gitleaks; # used by nix/git-hooks/pre-commit, same pin as everything else
        backend = pkgs.callPackage ./nix/pkgs/backend.nix { };
        runtime-loader = pkgs.callPackage ./nix/pkgs/runtime-loader.nix { };
        proton-run = pkgs.callPackage ./nix/pkgs/proton-run.nix { };
        default = self.packages.${system}.legendary;
      };

      nixosModules.server = { lib, ... }: {
        imports = [ ./nix/modules/server.nix ];
        services.dauntless-nix.package = lib.mkDefault self.packages.${system}.backend;
      };

      checks.${system}.server = import ./nix/tests/server.nix { inherit self pkgs; };
    };
}
