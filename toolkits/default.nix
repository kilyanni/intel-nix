{
  callPackage,
  intel-oneapi,
}: let
  installer = callPackage ./installer {};
  stdenv = installer.base;
  # stdenv = intel-oneapi.base.stdenv;
in {
  deps = {
    libffi_3_2_1 = callPackage ./deps/libffi_3_2_1.nix {};
    opencl-clang_14 = callPackage ./deps/opencl-clang_14.nix {};
    gdbm_1_13 = callPackage ./deps/gdbm_1_13.nix {};
  };

  inherit installer;

  tests = {
    pure-link-libstdcxx = callPackage ./tests/pure-link-libstdcxx.nix {inherit stdenv;};
    cxx-shared-lib-pure-link = callPackage ./tests/cxx-shared-lib-pure-link.nix {inherit stdenv;};
    cxx-single-step = callPackage ./tests/cxx-single-step.nix {inherit stdenv;};
    c-pure-link = callPackage ./tests/c-pure-link.nix {inherit stdenv;};
  };

  packages = let
    intel-llvm = {stdenv = installer.base;};
    oneMath-sycl-blas = callPackage ../src/onemath-sycl-blas.nix {inherit intel-llvm;};
    oneMath = callPackage ../src/onemath.nix {inherit intel-llvm oneMath-sycl-blas;};
    oneDNN = callPackage ../src/onednn.nix {inherit intel-llvm;};
  in {
    inherit oneMath-sycl-blas oneMath oneDNN;
    whisper-cpp = callPackage ../src/ggml/whisper-cpp.nix {
      inherit intel-llvm oneMath oneDNN;
      syclcompat = null;
    };
    llama-cpp = callPackage ../src/ggml/llama-cpp.nix {
      inherit intel-llvm oneMath oneDNN;
      syclcompat = null;
    };
  };
}
