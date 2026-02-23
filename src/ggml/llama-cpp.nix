{
  fetchFromGitHub,
  intel-llvm,
  cmake,
  ninja,
  oneDNN,
  oneMath,
  tbb_2022,
  mkl,
  git,
  opencl-headers,
  ocl-icd,
  curl,
}: let
  version = "b6524";
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
      tbb_2022
      mkl
      opencl-headers
      ocl-icd
      curl
    ];

    hardeningDisable = [
      "zerocallusedregs"
      "pacret"
      # "shadowstack"
    ];

    cmakeFlags = [
      "-DGGML_SYCL=ON"
    ];
  }
