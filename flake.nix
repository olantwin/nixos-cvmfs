{
  description = "CVMFS client package and NixOS module with systemd automount";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};
    in
    {
      # The CVMFS client package, built from source
      packages.${system} = {
        cvmfs = pkgs.callPackage ./pkgs/cvmfs.nix { };
        default = self.packages.${system}.cvmfs;
      };

      # NixOS module for declarative CVMFS configuration
      nixosModules = {
        cvmfs = import ./modules/cvmfs.nix;
        default = self.nixosModules.cvmfs;
      };

      # Optional overlay: adds pkgs.cvmfs to your package set
      overlays.default = final: prev: {
        cvmfs = self.packages.${system}.cvmfs;
      };
    };
}
