{callPackage}: rec {
  deps = {
    libffi_3_2_1 = callPackage ./deps/libffi_3_2_1.nix {};
    opencl-clang_14 = callPackage ./deps/opencl-clang_14.nix {};
    gdbm_1_13 = callPackage ./deps/gdbm_1_13.nix {};
  };

  installer = callPackage ./installer {};

  tests = let
    intel-llvm = {stdenv = installer.base.passthru.stdenv;};
    oneMath-sycl-blas = callPackage ../src/onemath-sycl-blas.nix {inherit intel-llvm;};
    oneMath = callPackage ../src/onemath.nix {inherit intel-llvm oneMath-sycl-blas;};
    oneDNN = callPackage ../src/onednn.nix {inherit intel-llvm;};
    syclcompat = callPackage ../src/syclcompat.nix {};
  in {
    inherit oneMath-sycl-blas oneMath oneDNN;
    whisper-cpp = callPackage ../src/ggml/whisper-cpp.nix {
      inherit intel-llvm oneMath oneDNN syclcompat;
    };
  };
}
