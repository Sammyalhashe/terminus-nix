{
  description = "NixOS module to run usetrmnl/terminus (a TRMNL server) as a podman OCI stack";

  # nixpkgs is not needed to evaluate the module itself (it is a plain NixOS
  # module). It is declared so the flake is self-contained; consumers should set
  # `terminus.inputs.nixpkgs.follows = "nixpkgs"` to avoid a second nixpkgs.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    {
      nixosModules.terminus = import ./module.nix;
      nixosModules.default = self.nixosModules.terminus;
    };
}
