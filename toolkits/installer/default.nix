{
  callPackage,
  intel-oneapi,
}: rec {
  base = callPackage ./wrapper.nix {
    kit = intel-oneapi.base;
  };

  hpc = callPackage ./wrapper.nix {
    kit = intel-oneapi.hpc;
  };

  tests = callPackage ./tests.nix {stdenv = base;};
}
