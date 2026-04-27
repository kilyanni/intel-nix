{
  callPackage,
  lib,
  ccacheStdenv,
  stdenv,
  newScope,
  cudaPackages_13,
  rocmPackages ? {},
  fetchFromGitHub,
  useCcache ? true,
}: let
  # ── Base LLVM builds (level-zero, default backend) ────────────────────────
  llvm-monolithic = callPackage ./llvm/package.nix {
    inherit newScope ccacheStdenv stdenv useCcache;
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

  mkCcacheIntelStdenv = llvm:
    ccacheStdenv.override {
      stdenv = llvm.stdenv;
    };

  # Wrap an llvm package set with a ccache stdenv (when useCcache is enabled),
  # mirroring the nixpkgs pattern where stdenv vs ccacheStdenv is a callsite decision.
  mkIntelLlvm = llvm: useCcache:
    if useCcache
    then llvm // {stdenv = mkCcacheIntelStdenv llvm;}
    else llvm;

  # ── Package set combinatorics ──────────────────────────────────────────────
  # Functions from backend args -> LLVM build for each toolchain variant
  baseToolchains = {
    monolithic = args:
      llvm-monolithic.overrideScope (f: p: {
        unwrapped = p.unwrapped.override args;
      });
    standalone = args: llvm-standalone.override args;
  };

  # Backend args passed to both the LLVM build and downstream packages
  backends = {
    l0 = {};
    rocm = {
      rocmSupport = true;
      inherit rocmPackages;
    };
    cuda = {
      cudaSupport = true;
      cudaPackages = cudaPackages_13;
    };
  };

  makePackages = llvm: backendArgs: useCcache: let
    intel-llvm = mkIntelLlvm llvm useCcache;

    oneMath-sycl-blas = callPackage ./onemath-sycl-blas.nix {inherit intel-llvm;};
    oneMath-sycl-blas-tuned = {
      intel = oneMath-sycl-blas.override {gpuTarget = "INTEL_GPU";};
      nvidia = oneMath-sycl-blas.override {gpuTarget = "NVIDIA_GPU";};
      amd = oneMath-sycl-blas.override {gpuTarget = "AMD_GPU";};
    };

    oneMath = callPackage ./onemath.nix (
      {inherit intel-llvm oneMath-sycl-blas;}
      // backendArgs
    );

    oneDNN = callPackage ./onednn.nix (
      {inherit intel-llvm;}
      // backendArgs
    );
    syclcompat = callPackage ./syclcompat.nix {};
    ggml = callPackage ./ggml/ggml.nix {inherit intel-llvm oneDNN oneMath;};
    whisper-cpp = callPackage ./ggml/whisper-cpp.nix ({inherit intel-llvm oneDNN oneMath syclcompat;}
      // lib.intersectAttrs {
        rocmSupport = null;
        cudaSupport = null;
        rocmPackages = null;
      }
      backendArgs);
    llama-cpp = callPackage ./ggml/llama-cpp.nix ({inherit intel-llvm oneDNN oneMath syclcompat;}
      // lib.intersectAttrs {
        rocmSupport = null;
        cudaSupport = null;
        rocmPackages = null;
      }
      backendArgs);
    khronos-sycl-cts = callPackage ./khronos-sycl-cts.nix ({inherit intel-llvm;} // backendArgs);
  in {
    llvm = intel-llvm;
    inherit oneMath oneDNN ggml whisper-cpp llama-cpp khronos-sycl-cts oneMath-sycl-blas oneMath-sycl-blas-tuned syclcompat;
    tests = {
      whisper-e2e = callPackage ./ggml/whisper-e2e-test.nix {inherit whisper-cpp;};
      llama-e2e = callPackage ./ggml/llama-e2e-test.nix {inherit llama-cpp;};
    };
  };

  # packages.${toolchain}.${backend}.${pkg}
  makePackageSets = useCcache:
    lib.mapAttrs (
      _: mkLlvm:
        lib.mapAttrs (
          _: backendArgs:
            makePackages (mkLlvm backendArgs) backendArgs useCcache
        )
        backends
    )
    baseToolchains;

  packages = makePackageSets useCcache;
  packages-no-ccache = makePackageSets false;
in
  {
    # ── LLVM toolchains ────────────────────────────────────────────────────────
    inherit llvm-monolithic llvm-standalone;
    llvm = llvm-monolithic;

    # ── Shared / support components ────────────────────────────────────────────
    inherit unified-runtime vc-intrinsics;

    oneapi-ck = callPackage ./oneapi-ck.nix {};

    # ── Package sets ───────────────────────────────────────────────────────────
    # packages.${toolchain}.${backend}.${pkg}
    # toolchains: monolithic, standalone
    # backends:   l0, rocm, cuda
    # pkgs:       llvm, oneMath, oneDNN, ggml, whisper-cpp, llama-cpp, khronos-sycl-cts
    inherit packages packages-no-ccache;
  }
  // packages.monolithic.l0
