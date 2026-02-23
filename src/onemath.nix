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
  rocmPackages ? {},
  cudaPackages ? {},
  useMKL ? false,
  useGenericBlas ? true,
  rocmSupport ? false,
  cudaSupport ? false,
  rocmGpuTargets ?
    lib.optionalString (rocmPackages != {}) (
      builtins.concatStringsSep "," rocmPackages.clr.gpuTargets
    ),
  # CUDA 13 dropped sm_60 support; minimum is sm_75 (Turing)
  cudaGpuArch ? "sm_75",
}: let
  version = "0.9";
  stdenv = intel-llvm.stdenv;

  cudatoolkit_joined = symlinkJoin {
    name = "cuda-toolkit-joined";
    paths = with cudaPackages; [
      cuda_cudart
      cuda_nvcc
      libcublas
      libcublas.lib
      libcublas.include
      libcublas.stubs
      libcusolver
      libcusolver.lib
      libcusolver.include
      libcufft
      libcufft.lib
      libcufft.include
      libcurand
      libcurand.lib
      libcurand.include
      libcusparse
      libcusparse.lib
      libcusparse.include
    ];
    # Make stubs available at lib64 for FindCUDA
    postBuild = ''
      mkdir -p $out/lib64
      ln -s $out/lib/stubs/libcuda.so $out/lib64/libcuda.so
      ln -s $out/lib/stubs $out/lib64/stubs
    '';
  };
in
  stdenv.mkDerivation {
    pname = "oneMath";
    version = version;
    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "oneMath";
      rev = "v${version}";
      sha256 = "sha256-jVcrpne6OyOeUlQHg07zZXEyFXvEGCYW88sWnYgEeu8=";
    };

    nativeBuildInputs = [
      cmake
      ninja
    ]
    # cuda_nvcc provides ptxas which the SYCL compiler uses to locate
    # libdevice.10.bc for GPU math functions. Needs to be native since
    # the compiler runs on the build machine.
    ++ lib.optionals cudaSupport [cudaPackages.cuda_nvcc];

    buildInputs =
      [
        tbb_2022
        opencl-headers
      ]
      ++ lib.optionals useMKL [mkl]
      ++ lib.optionals (useGenericBlas && !rocmSupport && !cudaSupport) [oneMath-sycl-blas]
      ++ lib.optionals rocmSupport (with rocmPackages; [
        clr # Provides HIP
        rocblas
        rocfft
        rocsolver
        rocrand
        #rocsparse
      ])
      ++ lib.optionals cudaSupport [
        cudatoolkit_joined
      ];

    hardeningDisable = [
      # "zerocallusedregs"
      "pacret"
      "shadowstack"
    ];

    # Pass GPU architecture to SYCL CUDA backend (CUDA 13 dropped sm_60)
    env = lib.optionalAttrs cudaSupport {
      CXXFLAGS = "-Xsycl-target-backend=nvptx64-nvidia-cuda --cuda-gpu-arch=${cudaGpuArch}";
    };

    cmakeFlags =
      [
        # (lib.cmakeFeature "CMAKE_C_COMPILER" "${llvm}/bin/clang")
        # (lib.cmakeFeature "CMAKE_CXX_COMPILER" "${llvm}/bin/clang++")

        # Requires closed source icpx + mkl
        (lib.cmakeBool "ENABLE_MKLCPU_BACKEND" useMKL)
        (lib.cmakeBool "ENABLE_MKLGPU_BACKEND" useMKL)

        (lib.cmakeBool "ENABLE_CUBLAS_BACKEND" cudaSupport)
        (lib.cmakeBool "ENABLE_CUSOLVER_BACKEND" cudaSupport)
        (lib.cmakeBool "ENABLE_CUFFT_BACKEND" cudaSupport)
        (lib.cmakeBool "ENABLE_CURAND_BACKEND" cudaSupport)
        (lib.cmakeBool "ENABLE_CUSPARSE_BACKEND" cudaSupport)

        (lib.cmakeBool "ENABLE_NETLIB_BACKEND" false)

        (lib.cmakeBool "ENABLE_ARMPL_BACKEND" false)
        (lib.cmakeBool "ENABLE_ARMPL_OMP" true)
        (lib.cmakeBool "ENABLE_ARMPL_OPENRNG" false)

        (lib.cmakeBool "ENABLE_ROCBLAS_BACKEND" rocmSupport)
        (lib.cmakeBool "ENABLE_ROCFFT_BACKEND" rocmSupport)
        (lib.cmakeBool "ENABLE_ROCSOLVER_BACKEND" rocmSupport)
        (lib.cmakeBool "ENABLE_ROCRAND_BACKEND" rocmSupport)
        # Currently broken
        # (lib.cmakeBool "ENABLE_ROCSPARSE_BACKEND" rocmSupport)

        (lib.cmakeBool "ENABLE_MKLCPU_THREAD_TBB" true)

        # Required onemath-sycl-blas (cannot be used with other BLAS backends)
        (lib.cmakeBool "ENABLE_GENERIC_BLAS_BACKEND" (useGenericBlas && !rocmSupport && !cudaSupport))

        (lib.cmakeBool "ENABLE_PORTFFT_BACKEND" false)

        (lib.cmakeBool "BUILD_FUNCTIONAL_TESTS" false)
        (lib.cmakeBool "BUILD_EXAMPLES" false)
      ]
      ++ lib.optionals rocmSupport [
        (lib.cmakeFeature "HIP_TARGETS" rocmGpuTargets)
      ]
      ++ lib.optionals cudaSupport [
        (lib.cmakeFeature "CUDA_TOOLKIT_ROOT_DIR" "${cudatoolkit_joined}")
        (lib.cmakeFeature "CUDA_CUDA_LIBRARY" "${cudaPackages.cuda_cudart}/lib/stubs/libcuda.so")
      ];
  }
