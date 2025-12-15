{
  callPackage,
  ccacheStdenv,
}: rec {
  llvm-monolithic = callPackage ./llvm/monolithic.nix {};
  llvm-standalone = callPackage ./llvm/standalone.nix {};

  # llvm = llvm-standalone;
  llvm = llvm-monolithic;

  ccacheIntelStdenv = ccacheStdenv.override {
    stdenv = llvm.stdenv;
  };

  vc-intrinsics = callPackage ./vc-intrinsics.nix {};

  oneMath-sycl-blas = callPackage ./onemath-sycl-blas.nix {inherit llvm;};

  oneMath-sycl-blas-tuned = {
    intel = oneMath-sycl-blas.override {gpuTarget = "INTEL_GPU";};
    nvidia = oneMath-sycl-blas.override {gpuTarget = "NVIDIA_GPU";};
    amd = oneMath-sycl-blas.override {gpuTarget = "AMD_GPU";};
  };

  oneMath = callPackage ./onemath.nix {
    intel-llvm = llvm;
    inherit oneMath-sycl-blas ccacheIntelStdenv;
  };
  oneDNN = callPackage ./onednn.nix {
    intel-llvm = llvm;
    inherit ccacheIntelStdenv;
  };
  oneapi-ck = callPackage ./oneapi-ck.nix {};

  khronos-sycl-cts = callPackage ./khronos-sycl-cts.nix {
    intel-llvm = llvm;
    inherit ccacheIntelStdenv;
  };

  # Unrelated to Intel, just for testing as it should hit most common use cases
  ggml = callPackage ./ggml/ggml.nix {
    intel-llvm = llvm;
    inherit
      oneDNN
      oneMath
      ccacheIntelStdenv
      ;
  };
  whisper-cpp = callPackage ./ggml/whisper-cpp.nix {
    intel-llvm = llvm;
    inherit
      oneDNN
      oneMath
      ccacheIntelStdenv
      ;
  };
  llama-cpp = callPackage ./ggml/llama-cpp.nix {
    intel-llvm = llvm;
    inherit
      oneDNN
      oneMath
      ccacheIntelStdenv
      ;
  };
}
