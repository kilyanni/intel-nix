{
  fetchFromGitHub,
  lib,
  intel-llvm,
  cmake,
  ninja,
  oneDNN,
  oneMath,
  syclcompat,
  tbb_2022,
  mkl,
  git,
  opencl-headers,
  ocl-icd,
  curl,
  cudaSupport ? false,
  rocmSupport ? false,
  rocmPackages ? {},
  # CUDA 13 dropped sm_60 support; minimum is sm_75 (Turing)
  cudaGpuArch ? "sm_75",
}: let
  version = "b6524";
  syclTarget =
    if cudaSupport
    then "NVIDIA"
    else if rocmSupport
    then "AMD"
    else "INTEL";
  rocmGpuTargets =
    lib.optionalString (rocmPackages ? clr.gpuTargets)
    (builtins.concatStringsSep "," rocmPackages.clr.gpuTargets);
in
  intel-llvm.stdenv.mkDerivation {
    pname = "llama-cpp";
    inherit version;

    src = fetchFromGitHub {
      owner = "ggml-org";
      repo = "llama.cpp";
      tag = "${version}";
      hash = "sha256-zxWjSwB1ueHLAhFDAW49k5V6vv2MvUz+CkK9/mxdfrI=";
    };

    nativeBuildInputs = [
      cmake
      ninja
      git
    ];

    buildInputs = [
      oneDNN
      oneMath
      syclcompat
      tbb_2022
      mkl
      opencl-headers
      ocl-icd
      curl
    ];

    # For INTEL SYCL target, llama.cpp uses MKL::MKL_SYCL::BLAS — a domain-specific
    # SYCL target only available in newer Intel oneAPI MKL builds.  nixpkgs' MKL
    # (2023.1.0) doesn't export it.  Use oneMath's runtime dispatcher instead,
    # which works with any SYCL-capable MKL (same approach as whisper-cpp).
    postPatch = lib.optionalString (syclTarget == "INTEL") ''
      substituteInPlace ggml/src/ggml-sycl/CMakeLists.txt \
        --replace-fail "find_package(MKL REQUIRED)" "find_package(oneMath REQUIRED)" \
        --replace-fail "target_link_libraries(ggml-sycl PRIVATE MKL::MKL_SYCL::BLAS)" \
                       "target_link_libraries(ggml-sycl PRIVATE ONEMATH::onemath)" \
        --replace-fail "target_compile_definitions(ggml-sycl PRIVATE GGML_SYCL_USE_INTEL_ONEMKL)" \
                       "target_compile_definitions(ggml-sycl PRIVATE GGML_SYCL_GENERIC)"
    '';

    hardeningDisable = [
      "zerocallusedregs"
      "pacret"
      "shadowstack"
    ];

    cmakeFlags =
      [
        "-DGGML_SYCL=ON"
        (lib.cmakeFeature "GGML_SYCL_TARGET" syclTarget)
        (lib.cmakeBool "GGML_SYCL_DNN" true)
      ]
      ++ lib.optionals cudaSupport [
        (lib.cmakeFeature "GGML_SYCL_DEVICE_ARCH" cudaGpuArch)
      ]
      ++ lib.optionals (rocmSupport && rocmGpuTargets != "") [
        (lib.cmakeFeature "GGML_SYCL_DEVICE_ARCH" rocmGpuTargets)
      ];

    meta.mainProgram = "llama-cli";
  }
