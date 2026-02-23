{
  callPackage,
  lib,
  ccacheStdenv,
  stdenv,
  newScope,
  cudaPackages_13,
  fetchFromGitHub,
}: let
  # ── Base LLVM builds (level-zero, default backend) ────────────────────────
  llvm-monolithic = callPackage ./llvm/package.nix {
    inherit newScope ccacheStdenv stdenv;
    useCcache = true;
  };

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

  vc-intrinsics = callPackage ./vc-intrinsics.nix {};

  llvm-standalone = callPackage ./llvm-alt/standalone.nix {
    inherit unified-runtime vc-intrinsics;
  };

  llvm = llvm-monolithic;

  mkCcacheIntelStdenv = llvm: ccacheStdenv.override {
    stdenv = llvm.stdenv;
  };

  ccacheIntelStdenv = mkCcacheIntelStdenv llvm;

  # ── Shared components ──────────────────────────────────────────────────────
  oneMath-sycl-blas = callPackage ./onemath-sycl-blas.nix {inherit llvm;};

  oneMath-sycl-blas-tuned = {
    intel = oneMath-sycl-blas.override {gpuTarget = "INTEL_GPU";};
    nvidia = oneMath-sycl-blas.override {gpuTarget = "NVIDIA_GPU";};
    amd = oneMath-sycl-blas.override {gpuTarget = "AMD_GPU";};
  };

  # ── Package set combinatorics ──────────────────────────────────────────────
  # Functions from backend args -> LLVM build for each toolchain variant
  baseToolchains = {
    monolithic = args: llvm-monolithic.overrideScope (f: p: {
      unwrapped = p.unwrapped.override args;
    });
    standalone = args: llvm-standalone.override args;
  };

  # Backend args passed to both the LLVM build and downstream packages
  backends = {
    l0   = {};
    rocm = {rocmSupport = true;};
    cuda = {cudaSupport = true; cudaPackages = cudaPackages_13;};
  };

  makePackages = llvm: backendArgs: let
    ccacheIntelStdenv = mkCcacheIntelStdenv llvm;
    oneMath = callPackage ./onemath.nix (
      {intel-llvm = llvm; inherit oneMath-sycl-blas ccacheIntelStdenv;}
      // backendArgs
    );
    oneDNN = callPackage ./onednn.nix (
      {intel-llvm = llvm; inherit ccacheIntelStdenv;}
      // backendArgs
    );
    ggml = callPackage ./ggml/ggml.nix {
      intel-llvm = llvm;
      inherit ccacheIntelStdenv oneDNN oneMath;
    };
    whisper-cpp = callPackage ./ggml/whisper-cpp.nix {
      intel-llvm = llvm;
      inherit ccacheIntelStdenv oneDNN oneMath;
    };
    llama-cpp = callPackage ./ggml/llama-cpp.nix {
      intel-llvm = llvm;
      inherit ccacheIntelStdenv oneDNN oneMath;
    };
  in {inherit llvm oneMath oneDNN ggml whisper-cpp llama-cpp;};

  # packages.${toolchain}.${backend}.${pkg}
  packages = lib.mapAttrs (_: mkLlvm:
    lib.mapAttrs (_: backendArgs:
      makePackages (mkLlvm backendArgs) backendArgs
    ) backends
  ) baseToolchains;
in {
  # ── LLVM toolchains ────────────────────────────────────────────────────────
  inherit llvm-monolithic llvm-standalone;
  llvm = llvm-monolithic;

  # ── Shared / support components ────────────────────────────────────────────
  inherit unified-runtime vc-intrinsics ccacheIntelStdenv;
  inherit oneMath-sycl-blas oneMath-sycl-blas-tuned;

  oneapi-ck = callPackage ./oneapi-ck.nix {};

  khronos-sycl-cts = callPackage ./khronos-sycl-cts.nix {
    intel-llvm = llvm;
    inherit ccacheIntelStdenv;
  };

  # ── Package sets ───────────────────────────────────────────────────────────
  # packages.${toolchain}.${backend}.${pkg}
  # toolchains: monolithic, standalone
  # backends:   l0, rocm, cuda
  # pkgs:       oneMath, oneDNN, ggml, whisper-cpp, llama-cpp
  inherit packages;

  # ── Top-level aliases (monolithic + level-zero) ───────────────────────────
  inherit (packages.monolithic.l0) oneMath oneDNN ggml whisper-cpp llama-cpp;
}
