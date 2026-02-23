{
  lib,
  fetchFromGitHub,
  intel-llvm,
  python3,
  cmake,
  opencl-headers,
  ocl-icd,
  ninja,
  procps,
  cudaPackages ? {},
  rocmSupport ? false,
  cudaSupport ? false,
  levelZeroSupport ? !(rocmSupport || cudaSupport),
  # Arch passed to --offload-arch for ROCm
  rocmOffloadArch ? "gfx1030",
  # CUDA 13 dropped sm_60 support; minimum is sm_75 (Turing)
  cudaGpuArch ? "sm_75",
}:
intel-llvm.stdenv.mkDerivation (finalAttrs: {
  pname = "khronos-sycl-cts";
  version = "unstable-2025-09-19";

  src = fetchFromGitHub {
    owner = "KhronosGroup";
    repo = "SYCL-CTS";
    rev = "71ebbc15e07310d8ae4b0db7cfb871d9a7207c82";
    hash = "sha256-AqkFglhuOGhSY7jRb1ufOvQLIggKpj6j9LweEif5Rec=";
    fetchSubmodules = true;
  };

  nativeBuildInputs = [
    python3
    cmake
    ninja
  ];

  buildInputs = [
    opencl-headers
    ocl-icd
  ];

  hardeningDisable = ["all"];

  cmakeFlags =
    [
      (lib.cmakeFeature "SYCL_IMPLEMENTATION" "DPCPP")
      (lib.cmakeFeature "SYCL_CTS_EXCLUDE_TEST_CATEGORIES" "/build/disabled_categories")
    ]
    ++ lib.optional rocmSupport (lib.cmakeFeature "DPCPP_TARGET_TRIPLES" "amdgcn-amd-amdhsa")
    ++ lib.optional cudaSupport (lib.cmakeFeature "DPCPP_TARGET_TRIPLES" "nvptx64-nvidia-cuda");

  # We need to set this via the shell because it contains spaces
  preConfigure =
    ''
      touch /build/disabled_categories
    ''
    + lib.optionalString rocmSupport ''
      cmakeFlagsArray+=(
        "-DDPCPP_FLAGS=-Xsycl-target-backend=amdgcn-amd-amdhsa;--offload-arch=${rocmOffloadArch}"
      )

      cat << EOF > /build/disabled_categories
      atomic_ref
      EOF
    ''
    + lib.optionalString cudaSupport ''
      cmakeFlagsArray+=(
        "-DDPCPP_FLAGS=-Xsycl-target-backend=nvptx64-nvidia-cuda;--cuda-gpu-arch=${cudaGpuArch};--cuda-path=${cudaPackages.cuda_cudart}"
      )
    '';

  installPhase = ''
    runHook preInstall

    mkdir -p $out/bin
    cp -r bin/* $out/bin

    runHook postInstall
  '';

  passthru = {
    generate_exclude_filter = finalAttrs.finalPackage.overrideAttrs (old: {
      nativeBuildInputs = old.nativeBuildInputs ++ [procps];
      buildPhase = ''
        runHook preBuild

        cd ..
        mkdir $out
        python ci/generate_exclude_filter.py --cmake-args "$cmakeFlags" --output $out/generated.filter --verbose DPCPP

        runHook postBuild
      '';

      dontInstall = true;
    });
  };
})
