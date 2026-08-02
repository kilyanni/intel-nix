{
  pkgs,
  callPackage,
  lib,
  ccacheStdenv,
  stdenv,
  newScope,
  cudaPackages_13,
  rocmPackages ? {},
  fetchFromGitHub,
  useCcache ? true,
  # Per-package toggles to use the nixpkgs version of a package instead of
  # the in-tree derivation. Extend this attrset as more packages get merged
  # into nixpkgs (oneMath, oneDNN, etc.).
  #
  # Example: { intel-llvm = true; }
  fromNixpkgs ? {},
}: let
  fromNixpkgsDefaults = {
    intel-llvm = false;
    # Future additions (placeholders):
    # oneMath  = false;
    # oneDNN   = false;
  };
  useNixpkgs = fromNixpkgsDefaults // fromNixpkgs;

  # ── Base LLVM builds (level-zero, default backend) ────────────────────────
  # In-tree monolithic intel-llvm derivation. Structurally a sync of
  # nixpkgs' pkgs/by-name/in/intel-llvm with a small set of project-specific
  # extras baked in (newer Intel LLVM rev, addSYCLIncludeArgs cc-wrapper fix,
  # compiler-rt runtime setup for CUDA/ROCm, NIX_LDFLAGS=-lhwloc, the
  # lib/clang triple symlink, and PR #514089's CUDA/ROCm path setup-hook).
  llvm-monolithic-local = callPackage ./llvm/package.nix {
    inherit newScope;
  };

  # Pick the base intel-llvm scope (in-tree vs. nixpkgs).
  # When using the nixpkgs version, the consumer accepts that none of the
  # local extras above are present; override at the call site if needed.
  llvm-monolithic-base =
    if useNixpkgs.intel-llvm
    then pkgs.intel-llvm
    else llvm-monolithic-local;

  # Apply ccache via overrideScope: swap the unwrapped derivation's stdenv
  # for ccacheStdenv so the heavy LLVM compilation hits the cache, then wrap
  # downstream packages with ccacheIntelStdenv (= ccacheStdenv on top of the
  # produced compiler).
  mkCcacheIntelStdenv = llvm:
    ccacheStdenv.override {
      stdenv = llvm.stdenv;
    };

  applyCcacheToScope = llvm:
    llvm.overrideScope (final: prev: {
      unwrapped = prev.unwrapped.override {stdenv = ccacheStdenv;};
    });

  # Mirrors nixpkgs' stdenv vs ccacheStdenv as a callsite decision.
  # Adds passthru.stdenv = ccache-wrapped variant when ccache is on.
  #
  # Everything ccache-aware below takes `ccache` as a parameter rather than
  # closing over the top-level `useCcache`, so a single instantiation stays
  # internally consistent. Pass `useCcache = false` for builders without a
  # writable /var/cache/ccache (CI runners, remote builders) — they otherwise
  # abort at CMake's "check for working C compiler". The flake exposes that as
  # the `src-no-ccache` output.
  mkIntelLlvm = ccache: llvm:
    if ccache
    then (applyCcacheToScope llvm) // {stdenv = mkCcacheIntelStdenv llvm;}
    else llvm;

  llvm-monolithic-for = ccache: mkIntelLlvm ccache llvm-monolithic-base;

  # unified-runtime exposed standalone (used by the standalone LLVM build).
  # Uses the same Intel LLVM source as llvm-monolithic for consistency.
  unified-runtime-for = ccache:
    (callPackage ./llvm/unified-runtime.nix {
      intel-llvm-src = fetchFromGitHub {
        owner = "intel";
        repo = "llvm";
        tag = "v7.0.0";
        hash = "sha256-l4InHzR/W6Gihoxt9CjEREyB9LDIDQggskzFIPIS2bA=";
      };
      levelZeroSupport = true;
      openclSupport = true;
      cudaSupport = false;
      rocmSupport = false;
      nativeCpuSupport = false;
    })
    .override (lib.optionalAttrs ccache {stdenv = ccacheStdenv;});

  vc-intrinsics = callPackage ./vc-intrinsics.nix {};

  # standalone.nix carries its own `useCcache ? true`, so it has to be passed
  # explicitly — otherwise a ccache-free set still pulls ccache in here.
  llvm-standalone-for = ccache:
    callPackage ./llvm-alt/standalone.nix {
      unified-runtime = unified-runtime-for ccache;
      inherit vc-intrinsics;
      useCcache = ccache;
    };

  llvm-monolithic = llvm-monolithic-for useCcache;
  unified-runtime = unified-runtime-for useCcache;
  llvm-standalone = llvm-standalone-for useCcache;

  # ── Package set combinatorics ──────────────────────────────────────────────
  # Functions from backend args -> LLVM build for each toolchain variant
  baseToolchains = ccache: {
    monolithic = args:
      (llvm-monolithic-for ccache).overrideScope (f: p: {
        unwrapped = p.unwrapped.override (
          # cudaPackages is no longer a param on unwrapped.nix — we override
          # make-unified-runtime separately below to pass it through.
          builtins.removeAttrs args ["cudaPackages" "rocmPackages"]
        );
        make-unified-runtime = a:
          (p.make-unified-runtime a).override (
            lib.optionalAttrs (args ? cudaPackages) {inherit (args) cudaPackages;}
            // lib.optionalAttrs (args ? rocmPackages) {inherit (args) rocmPackages;}
          );
      });
    standalone = args: (llvm-standalone-for ccache).override args;
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

  makePackages = llvm: backendArgs: let
    intel-llvm = llvm;

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
  makePackageSets = ccache:
    lib.mapAttrs (
      _: mkLlvm:
        lib.mapAttrs (
          _: backendArgs:
            makePackages (mkLlvm backendArgs) backendArgs
        )
        backends
    )
    (baseToolchains ccache);

  packages = makePackageSets useCcache;
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
    inherit packages;
  }
  // packages.monolithic.l0
