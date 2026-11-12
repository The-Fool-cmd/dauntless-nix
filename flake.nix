{
  description = "dauntless-nix: Linux/NixOS packaging for a self-hosted Dauntless 1.14.7 server and clients";

  # Pinned independently of any host's system nixpkgs so Proton/Wine and tools never move on a system update.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/a50de1b7d8a586adc18d2395c19de7d6058e6030";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs { inherit system; };
    in {
      packages.${system} = {
        legendary = pkgs.callPackage ./nix/pkgs/legendary.nix { };
        default = self.packages.${system}.legendary;
      };
    };
}
