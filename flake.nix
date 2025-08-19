{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    zig = {
      url = "github:mitchellh/zig-overlay";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      nixpkgs,
      utils,
      ...
    }@inputs:
    utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        riscvPkgs = import nixpkgs {
          localSystem = "${system}";
          crossSystem = {
            config = "riscv64-unknown-linux-gnu";
            abi = "lp64";
          };
        };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            inputs.zig.packages.${system}.master
            riscvPkgs.buildPackages.binutils
          ];
          buildInputs = with pkgs; [ qemu ];
        };
      }
    );
}
