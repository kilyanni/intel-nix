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

    # oneDNN has DNNL_AMD_SYCL_KERNELS_TARGET_ARCH for AMD but no equivalent
    # for NVIDIA, so --cuda-gpu-arch must be injected as a compiler flag.
    # cmakeFlagsArray (a bash array) preserves the space in the value;
    # plain cmakeFlags is word-split before cmake sees it.
    preConfigure = lib.optionalString cudaSupport ''
      cmakeFlagsArray+=("-DCMAKE_CXX_FLAGS_INIT=-Xsycl-target-backend=nvptx64-nvidia-cuda --cuda-gpu-arch=${cudaGpuArch}")
    '';

    # sycl_post_ops.hpp explicitly calls dnnl::impl::math::swish_fwd /
    # elu_fwd, bypassing the SYCL-safe overloads already in sycl_math_utils.hpp.
    # Those common implementations use ::expf() / ::expm1f(), which Intel LLVM's
    # __libclc_call__ attribute transforms into llvm.exp.f32 / llvm.expm1.f32
    # intrinsics; the NVPTX backend has no registered libcall for ISD::FEXP,
    # causing "no libcall available for fexp" at compile time.
    # Dropping the explicit dnnl::impl::math:: qualification lets the unqualified
    # names resolve (via "using namespace math") to the SYCL-safe versions in
    # sycl_math_utils.hpp that use ::sycl::exp() / ::sycl::expm1().
    postPatch = lib.optionalString cudaSupport ''
        substituteInPlace src/gpu/generic/sycl/sycl_post_ops.hpp \
          --replace-fail \
            'dnnl::impl::math::swish_fwd(s, alpha)' \
            'swish_fwd(s, alpha)' \
          --replace-fail \
            'dnnl::impl::math::elu_fwd(s, alpha)' \
            'elu_fwd(s, alpha)'
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
