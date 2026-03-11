{
  callPackage,
  deps,
}: rec {
  base = callPackage ./wrapper.nix {
    kit = callPackage ./base.nix {inherit deps;};
  };

  # hpc.nix uses base.makeKit (via passthru) to share installer.nix logic
  hpc = callPackage ./wrapper.nix {
    kit = callPackage ./hpc.nix {inherit base;};
  };
}
