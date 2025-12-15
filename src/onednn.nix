{
  cmake,
  fetchFromGitHub,
  lib,
  stdenv,
  llvmPackages,
  intel-llvm,
  ccacheIntelStdenv,
  gcc,
  onetbb,
  ocl-icd,
  levelZeroSupport ? true,
  rocmSupport ? true,
  rocmPackages ? {},
}: let
  useSycl = levelZeroSupport || rocmSupport;
  stdenv =
    if useSycl
    then intel-llvm.stdenv
    # then ccacheIntelStdenv
    else stdenv;
in
  # This was originally called mkl-dnn, then it was renamed to dnnl, and it has
  # just recently been renamed again to oneDNN. See here for details:
  # https://github.com/uxlfoundation/oneDNN#oneapi-deep-neural-network-library-onednn
  stdenv.mkDerivation (finalAttrs: {
    pname = "oneDNN";
    version = "3.10.1";

    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "oneDNN";
      rev = "v${finalAttrs.version}";
      hash = "sha256-v1A9bOjcveTg97RBI2Y/gikoeQKYN8ZfFrqJmD3lVys=";
    };

    outputs = [
      "out"
      "dev"
      "doc"
    ];

    nativeBuildInputs = [cmake] ++ lib.optionals useSycl [gcc];

    buildInputs =
      lib.optionals useSycl [
        ocl-icd
        onetbb
      ]
      ++ lib.optionals rocmSupport [
        rocmPackages.clr # Provides HIP
        rocmPackages.miopen
        rocmPackages.rocblas
      ]
      ++ lib.optionals stdenv.hostPlatform.isDarwin [llvmPackages.openmp];

    cmakeFlags =
      [
        (lib.cmakeFeature "ONEDNN_CPU_RUNTIME" "SYCL")
        (lib.cmakeFeature "ONEDNN_GPU_RUNTIME" "SYCL")
      ]
      ++ lib.optionals rocmSupport [
        (lib.cmakeFeature "ONEDNN_GPU_VENDOR" "AMD")
        (lib.cmakeBool "ONEDNN_BUILD_GRAPH" false)
      ];

    # Tests fail on some Hydra builders, because they do not support SSE4.2.
    doCheck = false;

    # Fixup bad cmake paths
    postInstall = ''
      substituteInPlace $out/lib/cmake/dnnl/dnnl-config.cmake \
        --replace "\''${PACKAGE_PREFIX_DIR}/" ""

      substituteInPlace $out/lib/cmake/dnnl/dnnl-targets.cmake \
        --replace "\''${_IMPORT_PREFIX}/" ""
    '';

    meta = {
      changelog = "https://github.com/oneapi-src/oneDNN/releases/tag/v${finalAttrs.version}";
      description = "oneAPI Deep Neural Network Library (oneDNN)";
      homepage = "https://01.org/oneDNN";
      license = lib.licenses.asl20;
      platforms = lib.platforms.all;
    };
  })
