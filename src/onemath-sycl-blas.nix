{
  fetchFromGitHub,
  intel-llvm,
  cmake,
  ninja,
  lib,
  # The GPU to tune for. Does not affect dependencies pulled in.
  # Must be one of:
  #  DEFAULT, INTEL_GPU, NVIDIA_GPU, AMD_GPU
  gpuTarget ? "DEFAULT",
}:
assert lib.assertOneOf "gpuTarget" gpuTarget [
  "DEFAULT"
  "INTEL_GPU"
  "NVIDIA_GPU"
  "AMD_GPU"
];
  intel-llvm.stdenv.mkDerivation (finalAttrs: {
    # Upstream calls this `generic-sycl-components`; see nixpkgs#514640.
    pname = "oneMath-sycl-blas";
    version = "unstable-2025-08-04";

    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "generic-sycl-components";
      # There are currently no tagged releases, tracking issue:
      # https://github.com/uxlfoundation/generic-sycl-components/issues/16
      rev = "99241128f64b700392e4cfdd047caada024bf7dd";
      hash = "sha256-JIyWclCJVqrllP5zYFv8T9wurCLixAetLVzQYt27pGY=";
    };

    __structuredAttrs = true;
    strictDeps = true;

    nativeBuildInputs = [
      cmake
      ninja
    ];

    sourceRoot = "${finalAttrs.src.name}/onemath/sycl/blas";

    cmakeFlags = [
      (lib.cmakeFeature "TUNING_TARGET" gpuTarget)
    ];

    meta = {
      description = "SYCL-based BLAS kernels used as the generic BLAS backend for oneMath";
      homepage = "https://github.com/uxlfoundation/generic-sycl-components";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [kilyanni];
      platforms = lib.platforms.linux;
    };
  })
