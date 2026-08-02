{
  fetchFromGitHub,
  lib,
  intel-llvm,
  cmake,
  ninja,
  mkl,
  tbb_2022,
  opencl-headers,
  oneMath-sycl-blas,
  symlinkJoin,
  autoAddDriverRunpath,
  rocmPackages ? {},
  cudaPackages ? {},
  # MKL needs the closed-source icpx, so it is off by default here; the
  # toolkit-based package sets turn it on.
  useMKL ? false,
  rocmSupport ? false,
  cudaSupport ? false,
  # oneMath's DPC++ path can only build a single HIP target at a time, see
  # https://uxlfoundation.github.io/oneMath/building_the_project_with_dpcpp.html
  # so this deliberately is not derived from rocmPackages.clr.gpuTargets.
  # gfx1030 is an arbitrary default — override it to your GPU's arch.
  rocmGpuTarget ? "gfx1030",
  # CUDA 13 dropped sm_60 support; minimum is sm_75 (Turing)
  cudaGpuArch ? "sm_75",
}: let
  version = "0.9";

  useGenericBlas = !cudaSupport && !rocmSupport;

  generic-blas = oneMath-sycl-blas.override {
    # Since we only use this on Intel, only tune it for Intel
    gpuTarget = "INTEL_GPU";
  };

  cudatoolkit_joined = symlinkJoin {
    name = "cuda-toolkit-joined";
    paths = with cudaPackages;
      [
        cuda_cudart
        cuda_nvcc
        libcublas.stubs
      ]
      ++ lib.concatMap (x: [
        x
        x.lib
        x.include
      ]) [
        libcublas
        libcusolver
        libcufft
        libcurand
        libcusparse
      ];
    # Make stubs available at lib64 for FindCUDA
    postBuild = ''
      mkdir -p $out/lib64
      ln -s $out/lib/stubs/libcuda.so $out/lib64/libcuda.so
      ln -s $out/lib/stubs $out/lib64/stubs
    '';
  };
in
  intel-llvm.stdenv.mkDerivation (finalAttrs: {
    pname = "oneMath";
    inherit version;

    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "oneMath";
      tag = "v${version}";
      hash = "sha256-jVcrpne6OyOeUlQHg07zZXEyFXvEGCYW88sWnYgEeu8=";
    };

    strictDeps = true;
    __structuredAttrs = true;

    nativeBuildInputs =
      [
        cmake
        ninja
      ]
      # cuda_nvcc provides ptxas which the SYCL compiler uses to locate
      # libdevice.10.bc for GPU math functions. Needs to be native since
      # the compiler runs on the build machine.
      ++ lib.optionals cudaSupport [
        cudaPackages.cuda_nvcc
        autoAddDriverRunpath
      ];

    buildInputs =
      [
        tbb_2022
        opencl-headers
      ]
      ++ lib.optionals useMKL [mkl]
      ++ lib.optionals useGenericBlas [generic-blas]
      ++ lib.optionals rocmSupport (with rocmPackages; [
        clr
        rocblas
        rocfft
        rocsolver
        rocrand
        # The nixpkgs version is too new for oneMath
        # TODO: Try reenabling this when oneMath updates
        # rocsparse
      ])
      ++ lib.optionals cudaSupport [cudatoolkit_joined];

    # Pass GPU architecture to SYCL CUDA backend (CUDA 13 dropped sm_60)
    env = lib.optionalAttrs cudaSupport {
      CXXFLAGS = "-Xsycl-target-backend=nvptx64-nvidia-cuda --cuda-gpu-arch=${cudaGpuArch}";
    };

    hardeningDisable = [
      "pacret"
      "shadowstack"
    ];

    # Check the support matrix of CPU/GPU x Library x Compiler here:
    #   https://github.com/uxlfoundation/oneMath#linux
    cmakeFlags =
      [
        (lib.cmakeFeature "ONEMATH_SYCL_IMPLEMENTATION" "dpc++")

        # Requires closed-source icpx + mkl
        (lib.cmakeBool "ENABLE_MKLCPU_BACKEND" useMKL)
        (lib.cmakeBool "ENABLE_MKLGPU_BACKEND" useMKL)

        (lib.cmakeBool "ENABLE_NETLIB_BACKEND" false)

        (lib.cmakeBool "ENABLE_ARMPL_BACKEND" false)
        (lib.cmakeBool "ENABLE_ARMPL_OMP" true)
        (lib.cmakeBool "ENABLE_ARMPL_OPENRNG" false)

        (lib.cmakeBool "ENABLE_MKLCPU_THREAD_TBB" true)

        (lib.cmakeBool "ENABLE_GENERIC_BLAS_BACKEND" useGenericBlas)

        (lib.cmakeBool "ENABLE_PORTFFT_BACKEND" false)

        (lib.cmakeBool "BUILD_FUNCTIONAL_TESTS" false)
        (lib.cmakeBool "BUILD_EXAMPLES" false)
      ]
      ++ lib.optionals cudaSupport [
        (lib.cmakeBool "ENABLE_CUBLAS_BACKEND" true)
        (lib.cmakeBool "ENABLE_CUSOLVER_BACKEND" true)
        (lib.cmakeBool "ENABLE_CUFFT_BACKEND" true)
        (lib.cmakeBool "ENABLE_CURAND_BACKEND" true)
        (lib.cmakeBool "ENABLE_CUSPARSE_BACKEND" true)

        (lib.cmakeFeature "CUDA_TOOLKIT_ROOT_DIR" "${cudatoolkit_joined}")
        (lib.cmakeFeature "CUDA_CUDA_LIBRARY" "${cudaPackages.cuda_cudart}/lib/stubs/libcuda.so")
      ]
      ++ lib.optionals rocmSupport [
        (lib.cmakeBool "ENABLE_ROCBLAS_BACKEND" true)
        (lib.cmakeBool "ENABLE_ROCFFT_BACKEND" true)
        (lib.cmakeBool "ENABLE_ROCSOLVER_BACKEND" true)
        (lib.cmakeBool "ENABLE_ROCRAND_BACKEND" true)
        # The nixpkgs version is too new for oneMath
        # TODO: Try reenabling this when oneMath updates
        # (lib.cmakeBool "ENABLE_ROCSPARSE_BACKEND" true)

        (lib.cmakeFeature "HIP_TARGETS" rocmGpuTarget)
      ];

    passthru = lib.optionalAttrs rocmSupport {inherit rocmGpuTarget;};

    meta = {
      changelog = "https://github.com/uxlfoundation/oneMath/releases/tag/${finalAttrs.src.tag}";
      description = "Unified Math Library for accelerated computing using SYCL";
      longDescription = ''
        oneMath is an open-source implementation of the [oneMath specification](https://oneapi-spec.uxlfoundation.org/specifications/oneapi/latest/elements/onemath/source/) that can work with multiple devices using multiple libraries (backends) underneath.
      '';
      homepage = "https://github.com/uxlfoundation/oneMath";
      license = lib.licenses.asl20;
      maintainers = with lib.maintainers; [kilyanni];
      platforms = lib.platforms.linux;
    };
  })
