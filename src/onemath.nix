{
  fetchFromGitHub,
  lib,
  intel-llvm,
  ccacheIntelStdenv,
  cmake,
  ninja,
  mkl,
  tbb_2022,
  opencl-headers,
  oneMath-sycl-blas,
  useMKL ? false,
  useGenericBlas ? true,
}: let
  version = "0.8";
  stdenv = intel-llvm.stdenv;
  # stdenv = ccacheIntelStdenv;
in
  stdenv.mkDerivation {
    pname = "oneMath";
    version = version;
    src = fetchFromGitHub {
      owner = "uxlfoundation";
      repo = "oneMath";
      rev = "v${version}";
      sha256 = "sha256-xK8lKI3oqKlx3xtvdScpMq+HXAuoYCP0BZdkEqnJP5o=";
    };

    nativeBuildInputs = [
      cmake
      ninja
    ];

    buildInputs =
      [
        tbb_2022
        opencl-headers
      ]
      ++ lib.optionals useMKL [mkl]
      ++ lib.optionals useGenericBlas [oneMath-sycl-blas];

    hardeningDisable = [
      "zerocallusedregs"
      "pacret"
      # "shadowstack"
    ];

    cmakeFlags = [
      # (lib.cmakeFeature "CMAKE_C_COMPILER" "${llvm}/bin/clang")
      # (lib.cmakeFeature "CMAKE_CXX_COMPILER" "${llvm}/bin/clang++")

      # Requires closed source icpx + mkl
      (lib.cmakeBool "ENABLE_MKLCPU_BACKEND" useMKL)
      (lib.cmakeBool "ENABLE_MKLGPU_BACKEND" useMKL)

      (lib.cmakeBool "ENABLE_CUBLAS_BACKEND" false)
      (lib.cmakeBool "ENABLE_CUSOLVER_BACKEND" false)
      (lib.cmakeBool "ENABLE_CUFFT_BACKEND" false)
      (lib.cmakeBool "ENABLE_CURAND_BACKEND" false)
      (lib.cmakeBool "ENABLE_CUSPARSE_BACKEND" false)

      (lib.cmakeBool "ENABLE_NETLIB_BACKEND" false)

      (lib.cmakeBool "ENABLE_ARMPL_BACKEND" false)
      (lib.cmakeBool "ENABLE_ARMPL_OMP" true)
      (lib.cmakeBool "ENABLE_ARMPL_OPENRNG" false)

      (lib.cmakeBool "ENABLE_ROCBLAS_BACKEND" false)
      (lib.cmakeBool "ENABLE_ROCFFT_BACKEND" false)
      (lib.cmakeBool "ENABLE_ROCSOLVER_BACKEND" false)
      (lib.cmakeBool "ENABLE_ROCRAND_BACKEND" false)
      (lib.cmakeBool "ENABLE_ROCSPARSE_BACKEND" false)

      (lib.cmakeBool "ENABLE_MKLCPU_THREAD_TBB" true)

      # Required onemath-sycl-blas
      (lib.cmakeBool "ENABLE_GENERIC_BLAS_BACKEND" useGenericBlas)

      (lib.cmakeBool "ENABLE_PORTFFT_BACKEND" false)

      (lib.cmakeBool "BUILD_FUNCTIONAL_TESTS" false)
      (lib.cmakeBool "BUILD_EXAMPLES" false)
    ];
  }
