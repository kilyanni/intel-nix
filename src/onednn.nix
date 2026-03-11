{
  cmake,
  fetchFromGitHub,
  lib,
  llvmPackages,
  intel-llvm,
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
  stdenv = intel-llvm.stdenv;

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
    version = "3.11";

    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "oneDNN";
      rev = "v${finalAttrs.version}";
      hash = "sha256-QXwgc/f4b6xl8yuzdtjaBHe5Z/gU9fhyVb2KltnkuDc=";
    };

    outputs = [
      "out"
      "dev"
      "doc"
    ];

    nativeBuildInputs =
      [cmake]
      ++ lib.optionals useSycl [gcc]
      ++ lib.optionals cudaSupport [cudaPackages.cuda_nvcc];

    buildInputs = lib.optionals stdenv.hostPlatform.isDarwin [llvmPackages.openmp];

    propagatedBuildInputs =
      lib.optionals useSycl [
        ocl-icd
        onetbb
      ]
      ++ lib.optionals cudaSupport [
        cudatoolkit_joined
      ]
      ++ lib.optionals rocmSupport [
        rocmPackages.clr
        rocmPackages.miopen
        rocmPackages.rocblas
      ];

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

    # Patch SYCL.cmake to add --cuda-path so libdevice.10.bc can be found.
    # \${CUDA_TOOLKIT_ROOT_DIR} is a cmake variable ref (Nix ''$ + shell '\''
    # produce literal \${...} in the cmake file; cmake drops the \ and expands).
    # --cuda-path must also be in SHARED/EXE_LINKER_FLAGS: the SYCL device link
    # step (building libdnnl.so) uses CMAKE_SHARED_LINKER_FLAGS, not CXX_FLAGS,
    # and CudaInstallationDetector needs --cuda-path to populate LibDeviceMap so
    # addSYCLDeviceLibs finds libdevice.10.bc for the NVPTX llvm-link step.
    # (BoundArch defaults to sm_75 per LLVM driver, so --cuda-gpu-arch not needed
    # in linker flags.)
    postPatch = lib.optionalString cudaSupport ''
        substituteInPlace cmake/SYCL.cmake \
          --replace-fail \
            'suppress_warnings_for_nvidia_target()' \
            'suppress_warnings_for_nvidia_target()
      append(CMAKE_CXX_FLAGS "--cuda-path=\''${CUDA_TOOLKIT_ROOT_DIR}")
      append(CMAKE_CXX_FLAGS "-Xsycl-target-backend=nvptx64-nvidia-cuda --cuda-gpu-arch=${cudaGpuArch}")
      append(CMAKE_SHARED_LINKER_FLAGS "--cuda-path=\''${CUDA_TOOLKIT_ROOT_DIR}")
      append(CMAKE_EXE_LINKER_FLAGS "--cuda-path=\''${CUDA_TOOLKIT_ROOT_DIR}")'
    '';

    # Tests fail on some Hydra builders, because they do not support SSE4.2.
    doCheck = false;

    # Fixup bad cmake paths
    postInstall =
      ''
        substituteInPlace $out/lib/cmake/dnnl/dnnl-config.cmake \
          --replace "\''${PACKAGE_PREFIX_DIR}/" ""

        substituteInPlace $out/lib/cmake/dnnl/dnnl-targets.cmake \
          --replace "\''${_IMPORT_PREFIX}/" ""
      ''
      + lib.optionalString rocmSupport ''
        # oneDNN exports legacy cmake target names that don't exist in ROCm 7.1.1:
        #   HIP::HIP      → hip::host     (public HIP interface, hip-config-amd.cmake)
        #   rocBLAS::rocBLAS → roc::rocblas (rocblas-config.cmake)
        #   MIOpen::MIOpen   → MIOpen      (miopen-config.cmake, no namespace)
        # Rename them in the targets file and add find_package calls so downstream
        # consumers have the targets available when dnnl-targets.cmake is included.
        substituteInPlace $out/lib/cmake/dnnl/dnnl-targets.cmake \
          --replace-fail "HIP::HIP" "hip::host" \
          --replace-fail "rocBLAS::rocBLAS" "roc::rocblas" \
          --replace-fail "MIOpen::MIOpen" "MIOpen"

        substituteInPlace $out/lib/cmake/dnnl/dnnl-config.cmake \
          --replace-fail \
            'include("''${CMAKE_CURRENT_LIST_DIR}/dnnl-targets.cmake")' \
            'find_package(hip CONFIG QUIET)
        find_package(rocblas CONFIG QUIET)
        find_package(miopen CONFIG QUIET)
        include("''${CMAKE_CURRENT_LIST_DIR}/dnnl-targets.cmake")'
      '';

    meta = {
      changelog = "https://github.com/oneapi-src/oneDNN/releases/tag/v${finalAttrs.version}";
      description = "oneAPI Deep Neural Network Library (oneDNN)";
      homepage = "https://01.org/oneDNN";
      license = lib.licenses.asl20;
      platforms = lib.platforms.all;
    };
  })
