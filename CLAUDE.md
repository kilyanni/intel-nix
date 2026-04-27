# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

**Always pass `--builders ''`** — remote builds break ccache and are never desired.

```sh
# Primary LLVM builds
nix build --builders '' --print-build-logs .#src.llvm-monolithic
nix build --builders '' --print-build-logs .#src.llvm-standalone.llvm

# Downstream packages (uses monolithic l0 backend by default)
nix build --builders '' --print-build-logs .#src.oneDNN
nix build --builders '' --print-build-logs .#src.oneMath
nix build --builders '' --print-build-logs .#src.whisper-cpp
nix build --builders '' --print-build-logs .#src.llama-cpp

# Full package set by toolchain + backend
nix build --builders '' --print-build-logs .#src.packages.monolithic.rocm.oneDNN
nix build --builders '' --print-build-logs .#src.packages.standalone.cuda.oneMath

# SYCL compile test
nix build --builders '' --print-build-logs .#src.llvm.passthru.tests.sycl-compile

# Toolkits (closed-source, needs --impure)
NIXPKGS_ALLOW_UNFREE=1 nix build --impure --print-build-logs .#toolkits.installer.base

# Evaluate without building (fast check)
nix eval .#src.llvm-monolithic
```

## Repository Structure

```
src/              Open-source Intel SYCL compiler + libraries, built from source
  default.nix     Top-level: exposes all package sets, combinatorics
  llvm/           Monolithic build (single derivation via makeScope)
  llvm-alt/       Standalone build (via llvmPackages.overrideScope)
  ggml/           GGML, whisper.cpp, llama.cpp with SYCL backends
  onednn.nix      oneDNN (deep learning primitives)
  onemath.nix     oneMath (math library)
toolkits/         Closed-source Intel oneAPI toolkits via installer
flake.nix         Uses nixpkgs-unstable; provides src.* and toolkits.* packages
```

## Two LLVM Build Strategies

**Monolithic** (`src/llvm/`): Single large CMake invocation using Intel's `buildbot/configure.py` script. Uses `lib.makeScope` for overriding. This is the primary/reference build.

**Standalone** (`src/llvm-alt/`): Overlays `llvmPackages_22.overrideScope` — builds each component (libllvm, clang, sycl, libdevice, libclc, etc.) as separate derivations. More granular but complex; uses two-stage clang wrappers (clang-stage-1 without libdevice to avoid cycle, clang = stage-1 + libdevice).

Both use the same Intel LLVM source rev and produce equivalent `stdenv`.

## Package Set Combinatorics (`src/default.nix`)

```
packages.${toolchain}.${backend}.${pkg}
  toolchains: monolithic, standalone
  backends:   l0 (level-zero), rocm, cuda
  pkgs:       llvm, oneMath, oneDNN, ggml, whisper-cpp, llama-cpp, khronos-sycl-cts
```

The top-level `src` attrset merges `packages.monolithic.l0` into itself for convenient access as `.#src.oneDNN` etc.

## Key Architectural Pattern: `intel-llvm`

Downstream packages (`onednn.nix`, `onemath.nix`, `ggml/*.nix`) receive `intel-llvm` as their sole toolchain argument and use `intel-llvm.stdenv` to build. The `intel-llvm` value is the merged derivation (`symlinkJoin` of wrapper + clang-tools-wrapper + unwrapped.{out,dev,lib}) with passthru `{ stdenv; unwrapped; cc; override; overrideScope; }`.

When `useCcache = true` (default), `intel-llvm.stdenv` is a ccache-wrapped stdenv — no separate `ccacheIntelStdenv` arg is needed downstream.

## Unified Runtime

`src/llvm/unified-runtime.nix` builds the backend plugin layer (level-zero, OpenCL, CUDA, HIP adapters). In the monolithic build it's built in-tree; in standalone it's a separate derivation. Its `passthru.setupVars` (e.g. `ROCM_PATH`, `CUDA_PATH`) are injected into the clang cc-wrapper's setup-hook so downstream SYCL compilation finds backends at runtime.

## Critical Build Constraints

- `BUILD_SHARED_LIBS=OFF`, `LLVM_LINK_LLVM_DYLIB=OFF`, `LLVM_BUILD_LLVM_DYLIB=OFF` — required; shared dylib builds are broken upstream (see [intel/llvm#19060](https://github.com/intel/llvm/issues/19060))
- `hardeningDisable = ["zerocallusedregs"]` — must be disabled for SYCL cross-compilation to SPIR-V / AMDGPU / NVPTX targets
- `requiredSystemFeatures = ["big-parallel"]` — the monolithic build is very large
- `NIX_LDFLAGS = "-lhwloc"` — needed in both LLVM and unified-runtime

## Patches

**`src/llvm/` patches** (applied in `unwrapped.nix`):
- `gnu-install-dirs.patch` — fixes `CMAKE_INSTALL_LIBDIR/INCLUDEDIR` for multi-output
- `sycl-jit-exclude-cmake-files.patch` — prevents output cycles from bundled cmake in sycl-jit
- `cuda-path-env-linux.patch` — teaches `CudaInstallationDetector` to check `CUDA_PATH` on Linux

**`src/llvm-alt/patches/`** (standalone build):
- `vc-intrinsics-install-dirs.patch` — fixes `$<INSTALL_INTERFACE:include>` → `$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>` in vc-intrinsics, preventing cmake generate-phase failure due to `$out/include` not existing
- Plus patches for `libclc`, `libdevice`, `sycl`, `sycl-jit`, `opencl`, `spirv-to-ir-wrapper`

**Important**: New patch files must be `git add`-ed before nix can include them from the flake source.

## Flake Inputs

- `nixpkgs` — nixos-unstable (primary)
- `nixpkgs-llvm` — PR #511852 (provides `intel-llvm` overlay)
- `nixpkgs-oneapi` — PR #512223 (provides `intel-oneapi` overlay)
- All use `allowUnfree = true` for CUDA & MKL

## Nix Gotchas

- Never use `2>&1` with nix commands — it breaks output
- The `ccacheWrapper` overlay in `flake.nix` patches `ccacheWrapper` to forward `hardeningUnsupportedFlags*` from the original compiler — without this, `zerocallusedregs` re-enters `defaultHardeningFlags` and breaks downstream SPIR-V compilations
- `LLVM_INSTALL_PACKAGE_DIR` is set to an absolute `$dev` path; this causes `FindPrefixFromConfig.cmake` to hardcode `_IMPORT_PREFIX=$out`, so all cmake exports must use absolute `$dev/include` paths (not `_IMPORT_PREFIX`-relative)
