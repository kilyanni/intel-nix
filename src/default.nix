{
  callPackage,
  ccacheStdenv,
  stdenv,
  newScope,
  cudaPackages_13,
  fetchFromGitHub,
}: rec {
  # Main intel-llvm package using the new makeScope-based structure from nixpkgs
  # Pass useCcache = true (default) to use ccacheStdenv for faster local rebuilds
  llvm-monolithic = callPackage ./llvm/package.nix {
    inherit newScope ccacheStdenv stdenv;
    useCcache = true;
  };

  # Unified-runtime for standalone builds
  unified-runtime = callPackage ./llvm/unified-runtime.nix {
    buildStdenv = ccacheStdenv;
    intel-llvm-src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      rev = "ab3dc98de0fd1ada9df12b138de1e1f8b715cc27";
      hash = "sha256-oHk8kQVNsyC9vrOsDqVoFLYl2yMMaTgpQnAW9iHZLfE=";
    };
    levelZeroSupport = true;
    openclSupport = true;
    cudaSupport = false;
    rocmSupport = false;
    nativeCpuSupport = false;
  };

  # Alternative builds (experimental/legacy)
  llvm-standalone = callPackage ./llvm-alt/standalone.nix {
    inherit unified-runtime vc-intrinsics;
  };

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
  oneMath-rocm = oneMath.override {
    rocmSupport = true;
  };

  # CUDA-enabled intel-llvm (generates PTX 8.8, requires CUDA 13+)
  llvm-cuda = llvm-monolithic.overrideScope (final: prev: {
    unwrapped = prev.unwrapped.override { cudaSupport = true; };
  });

  oneMath-cuda = callPackage ./onemath.nix {
    intel-llvm = llvm-cuda;
    cudaSupport = true;
    cudaPackages = cudaPackages_13;
    inherit oneMath-sycl-blas ccacheIntelStdenv;
  };

  oneDNN = callPackage ./onednn.nix {
    intel-llvm = llvm;
    inherit ccacheIntelStdenv;
  };

  oneDNN-cuda = callPackage ./onednn.nix {
    intel-llvm = llvm-cuda;
    cudaSupport = true;
    cudaPackages = cudaPackages_13;
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
