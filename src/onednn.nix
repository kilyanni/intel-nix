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
  symlinkJoin,
  levelZeroSupport ? true,
  rocmSupport ? false,
  cudaSupport ? false,
  rocmPackages ? {},
  cudaPackages ? {},
  # CUDA 13 dropped sm_60 support; minimum is sm_75 (Turing)
  cudaGpuArch ? "sm_75",
}: let
  useSycl = levelZeroSupport || rocmSupport || cudaSupport;
  stdenv =
    if useSycl
    then intel-llvm.stdenv
    # then ccacheIntelStdenv
    else stdenv;

  # Combined CUDA toolkit for compiler to find libdevice.10.bc
  cudatoolkit_joined = symlinkJoin {
    name = "cuda-toolkit-joined";
    paths = with cudaPackages; [
      cuda_cudart
      cuda_nvcc
      libcublas
      libcublas.lib
      libcublas.include
      libcublas.stubs
      cudnn
      cudnn.lib
      cudnn.include
    ];
    # Make stubs available at lib64 for FindCUDA
    postBuild = ''
      mkdir -p $out/lib64
      ln -s $out/lib/stubs/libcuda.so $out/lib64/libcuda.so
      ln -s $out/lib/stubs $out/lib64/stubs
    '';
  };
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

    nativeBuildInputs = [cmake]
      ++ lib.optionals useSycl [gcc]
      # cuda_nvcc provides ptxas which the SYCL compiler uses to locate
      # libdevice.10.bc for GPU math functions. Needs to be native since
      # the compiler runs on the build machine.
      ++ lib.optionals cudaSupport [cudaPackages.cuda_nvcc];

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
      ++ lib.optionals cudaSupport [
        cudatoolkit_joined
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
      ]
      ++ lib.optionals cudaSupport [
        (lib.cmakeFeature "ONEDNN_GPU_VENDOR" "NVIDIA")
        (lib.cmakeFeature "CUDA_TOOLKIT_ROOT_DIR" "${cudatoolkit_joined}")
        (lib.cmakeFeature "CUDA_DRIVER_LIBRARY" "${cudaPackages.cuda_cudart}/lib/stubs/libcuda.so")
      ];

    # Patch SYCL.cmake to add --cuda-path so libdevice.10.bc can be found
    # Note: \${CUDA_TOOLKIT_ROOT_DIR} is a CMake variable (escaped from Nix)
    postPatch = lib.optionalString cudaSupport ''
      substituteInPlace cmake/SYCL.cmake \
        --replace-fail \
          'suppress_warnings_for_nvidia_target()' \
          'suppress_warnings_for_nvidia_target()
    append(CMAKE_CXX_FLAGS "--cuda-path=\''${CUDA_TOOLKIT_ROOT_DIR}")
    append(CMAKE_CXX_FLAGS "-Xsycl-target-backend=nvptx64-nvidia-cuda --cuda-gpu-arch=${cudaGpuArch}")'
    '';

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
