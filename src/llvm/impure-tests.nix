# Impure tests: these need a real GPU, so they run in the nix sandbox with
# selected host paths bound in (see pkgs/build-support/make-impure-test.nix).
#
# Run one with:
#   $(nix-build -A intel-llvm.impureTests.sycl-run-hip)
# The attribute's main output is a *script* that re-invokes nix-build as root
# with the right --option extra-sandbox-paths; the derivation it builds is at
# .testDerivation. Re-run an already-cached pass with `--check`.
#
# In this flake the attribute path differs, so prefer the justfile recipe or:
#   sudo nix build --option extra-sandbox-paths '/sys /dev/dri /dev/kfd' \
#     '.#src.packages.monolithic.rocm.llvm.impureTests.sycl-run-hip.testDerivation'
{
  lib,
  stdenv,
  makeImpureTest,
  # Backends the toolchain was actually built with, from
  # unified-runtime.passthru.backends — we only emit tests for those.
  backends,
  # Attribute path prefix baked into makeImpureTest's generated run script.
  testedPackage ? "intel-llvm",
  # AOT-compiled backends must be built for the arch of the GPU that will run
  # the test; there is no JIT fallback the way there is for spir64. Override
  # these to match your hardware or the test will fail to load the binary.
  rocmOffloadArch ? "gfx1030",
  cudaGpuArch ? "sm_75",
}:
let
  # backend name (as used in SYCL_ENABLE_BACKENDS / ONEAPI_DEVICE_SELECTOR)
  # -> how to build for it and what host access running it needs.
  candidates = {
    opencl = {
      # SPIR-V is JIT-compiled by the runtime, so no target flags needed.
      flags = [ ];
      # The ICD loader finds vendor drivers through a registry that lives
      # outside the sandbox; without it no OpenCL platform is visible at all.
      # The .icd files there point into /nix/store, which the sandbox always has.
      #
      # /run/opengl-driver is a SYMLINK into the store and nix does not follow
      # symlinks when binding sandbox paths, so it must be mapped explicitly:
      #   --option extra-sandbox-paths "/run/opengl-driver=$(readlink -f /run/opengl-driver)"
      # (the `just test-sycl-run` recipe does this for you).
      #
      # Note this only finds a device on hardware whose OpenCL implementation
      # can ingest SPIR-V (cl_khr_il_program / a non-empty "IL version").
      # ROCm's OpenCL does not, so on an AMD-only host SYCL legitimately reports
      # no usable OpenCL GPU even though clinfo lists the card.
      sandboxPaths = [ "/sys" "/dev/dri" "/run/opengl-driver" ];
      env.OCL_ICD_VENDORS = "/run/opengl-driver/etc/OpenCL/vendors";
    };
    level_zero = {
      flags = [ ];
      # libze_intel_gpu comes from the host's graphics driver, not from us.
      # Untested here — this machine has no Intel GPU.
      sandboxPaths = [ "/sys" "/dev/dri" "/run/opengl-driver" ];
      env.LD_LIBRARY_PATH = "/run/opengl-driver/lib";
    };
    hip = {
      flags = [
        "-fsycl-targets=amdgcn-amd-amdhsa"
        "-Xsycl-target-backend=amdgcn-amd-amdhsa"
        "--offload-arch=${rocmOffloadArch}"
      ];
      # /dev/kfd is the ROCm compute node; /dev/dri alone is not enough.
      sandboxPaths = [ "/sys" "/dev/dri" "/dev/kfd" ];
    };
    cuda = {
      flags = [ "-fsycl-targets=nvptx64-nvidia-cuda" ];
      # NVIDIA also needs the driver libraries visible, not just device nodes;
      # this is untested — nixpkgs has no CUDA makeImpureTest precedent.
      sandboxPaths = [
        "/sys"
        "/dev/nvidiactl"
        "/dev/nvidia-uvm"
        "/dev/nvidia0"
        "/run/opengl-driver"
      ];
    };
  };

  # level_zero_v2 is selected by a loader env var rather than its own
  # ONEAPI_DEVICE_SELECTOR string, and native_cpu is not a GPU, so neither gets
  # a test here.
  enabled = lib.filterAttrs (name: _: lib.elem name backends) candidates;

  mkProbe =
    name: flags:
    stdenv.mkDerivation {
      name = "sycl-run-probe-${name}";
      dontUnpack = true;

      buildPhase = ''
        runHook preBuild
        clang++ -fsycl ${lib.escapeShellArgs flags} ${./sycl-run-test.cpp} -o sycl-run-probe
        runHook postBuild
      '';

      installPhase = ''
        runHook preInstall
        install -Dm755 sycl-run-probe $out/bin/sycl-run-probe
        runHook postInstall
      '';

      meta.description = "Helper binary for the sycl-run-${name} impure test";
    };

  mkTest =
    name:
    {
      flags,
      sandboxPaths,
      env ? { },
    }:
    makeImpureTest {
      name = "sycl-run-${name}";
      inherit testedPackage sandboxPaths;

      nativeBuildInputs = [ (mkProbe name flags) ];

      # Runtime-discovery knobs that point at host driver state. Impure by
      # construction, which is the point of this test class.
      inherit env;

      # Pin both the backend the runtime may pick and the one the binary will
      # accept, so a fallback to another backend or to the host fails loudly.
      testScript = ''
        export ONEAPI_DEVICE_SELECTOR=${name}:gpu
        export SYCL_EXPECT_BACKEND=${name}
        sycl-run-probe
      '';

      meta = {
        description = "Run a SYCL kernel on a real ${name} GPU";
        maintainers = with lib.maintainers; [ kilyanni ];
        platforms = lib.platforms.linux;
      };
    };
in
lib.mapAttrs' (name: cfg: lib.nameValuePair "sycl-run-${name}" (mkTest name cfg)) enabled
