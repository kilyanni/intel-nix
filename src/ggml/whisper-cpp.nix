{
  lib,
  fetchFromGitHub,
  intel-llvm,
  cmake,
  ninja,
  oneDNN,
  oneMath,
  syclcompat,
  tbb_2022,
  git,
  opencl-headers,
  ocl-icd,
  rocmSupport ? false,
  cudaSupport ? false,
  rocmPackages ? {},
}: let
  version = "1.8.3";
  syclTarget =
    if rocmSupport
    then "AMD"
    else if cudaSupport
    then "NVIDIA"
    else "INTEL";
  rocmGpuTargets =
    lib.optionalString (rocmPackages ? clr.gpuTargets)
    (builtins.concatStringsSep "," rocmPackages.clr.gpuTargets);
in
  intel-llvm.stdenv.mkDerivation {
    pname = "whisper-cpp";
    inherit version;

    src = fetchFromGitHub {
      owner = "ggml-org";
      repo = "whisper.cpp";
      tag = "v${version}";
      hash = "sha256-TeS1lGKEzkHOoBemy/tMGtIsy0iouj9DTYIgTjUNcQk=";
    };

    patches = [
      ./patches/sycl-amd-multi-arch.patch
    ];

    nativeBuildInputs = [
      cmake
      ninja
      git
    ];

    buildInputs = [
      # oneDNN
      oneMath
      syclcompat
      tbb_2022
      opencl-headers
      ocl-icd
    ];

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

      # Not necessary on all configs. TODO: Find which
      "shadowstack"
    ];

    cmakeFlags =
      [
        (lib.cmakeBool "GGML_SYCL" true)
        (lib.cmakeBool "GGML_NATIVE" false)
        (lib.cmakeFeature "GGML_SYCL_TARGET" syclTarget)
      ]
      ++ lib.optionals (syclTarget == "AMD" && rocmGpuTargets != "") [
        (lib.cmakeFeature "GGML_SYCL_DEVICE_ARCH" rocmGpuTargets)
      ];
  }
