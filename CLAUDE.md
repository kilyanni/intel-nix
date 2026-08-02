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

# SYCL compile tests — one per enabled backend, so the attr names vary with
# the package set. List them first:
#   nix eval .#src.llvm.passthru.tests --apply builtins.attrNames
nix build --builders '' --print-build-logs .#src.llvm.passthru.tests.sycl-compile-spir64
nix build --builders '' --print-build-logs .#src.packages.monolithic.rocm.llvm.passthru.tests.sycl-compile-amdgcn-amd-amdhsa
nix build --builders '' --print-build-logs .#src.packages.monolithic.cuda.llvm.passthru.tests.sycl-compile-nvptx64-nvidia-cuda
# The standalone toolchain hangs its tests off `clang`, not the scope:
nix build --builders '' --print-build-logs .#src.packages.standalone.l0.llvm.clang.passthru.tests.sycl-compile-spir64

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

Both build the same Intel LLVM source (tag `v7.0.0`) and produce equivalent `stdenv`.

### Source revision

Both toolchains pin the **`v7.0.0` release tag** (commit date `20260713`). Note this
is a *release branch*, not a point on `sycl` main: it forked at 2026-01-29 and carries
its own stabilisation commits, so it is missing features that landed on main since.
The pins live in:

- `src/llvm/package.nix` — `version`, `src.tag`, `commitDate`
- `src/llvm-alt/standalone.nix` — `version`, `date`, `srcOrig.src.tag`
- `src/llvm-alt/update-patches.fish` — `BASE`
- `src/llvm-alt/deps.nix` + `src/vc-intrinsics.nix` — vc-intrinsics rev, which must
  match `LLVMGenXIntrinsics_GIT_TAG` in intel/llvm's `llvm/lib/SYCLLowerIR/CMakeLists.txt`

All five must move together.

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

**`src/llvm-alt/patches/`** (standalone build) — all except `vc-intrinsics-install-dirs.patch`
are **generated**, do not hand-edit them:

- `vc-intrinsics-install-dirs.patch` — hand-written. Fixes `$<INSTALL_INTERFACE:include>` → `$<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>` in vc-intrinsics, preventing cmake generate-phase failure due to `$out/include` not existing
- `gnu-install-dirs.patch` — monorepo-level; applied at `srcOrig` root
- `standalone-{libclc,libdevice,opencl,spirv-to-ir-wrapper,sycl,sycl-jit,xptifw}.patch` and
  `sycl-jit-exclude-cmake-files.patch` — component-level, stripped to apply with `-p1` at
  each component's `sourceRoot`

### Regenerating patches

`src/llvm-alt/update-patches.fish` regenerates them from branches in
`~/src/stuff/intel/intel-llvm`. Two branch families live there:

- **`fix/*`** — the upstream-targeted branches (one per intel/llvm PR, see
  `~/src/stuff/intel/PR-NOTES.md`), based on `upstream/sycl` and each checked out in its
  own worktree under `intel-llvm-worktrees/`. **Do not rebase these onto a release tag** —
  that is what makes them submittable.
- **`v7/*`** — packaging-only ports of those same commits onto `v7.0.0`, which is what we
  actually build. Regenerate with `git cherry-pick fix/<name>` onto the new base.

`v7/gnu-install-dirs-full` is `fix/install-dirs-destdir` + `fix/gnu-install-dirs` squashed
into one patch file, since we apply them together.

**Important**: New patch files must be `git add`-ed before nix can include them from the flake source.

## Flake Inputs

- `nixpkgs` — nixos-unstable, the only real input (`flake-utils` aside)
- `config.allowUnfree = true` for CUDA & MKL, set in `flake.nix`
- The `intel-llvm` / `intel-oneapi` packages are built **in-tree** here, not pulled from a
  nixpkgs PR branch. `src/default.nix` has a `fromNixpkgs` toggle to switch individual
  packages over to `pkgs.*` once the corresponding PR lands.

## Relationship to the nixpkgs PRs

`src/llvm/` is deliberately kept as a near-verbatim copy of nixpkgs'
`pkgs/by-name/in/intel-llvm/` (currently tracking
[#546860](https://github.com/NixOS/nixpkgs/pull/546860), `intel-llvm: -> 7.0.0`) plus a
small set of project-specific extras: the compiler-rt runtimes setup for CUDA/ROCm,
`NIX_LDFLAGS = "-lhwloc"`, the `lib/clang` triple symlink, and `cuda-path-env-linux.patch`.
Keep the diff against the PR branch small so changes flow both ways.

`src/onemath.nix` and `src/onemath-sycl-blas.nix` track
[#514640](https://github.com/NixOS/nixpkgs/pull/514640) (`oneMath` +
`generic-sycl-components`), with MKL support and the `cudaGpuArch` knob added on top.

## ggml / whisper.cpp / llama.cpp pins are capped

Do not bump these to current upstream, and do not trust nixpkgs' pins for them:
nixpkgs does not enable SYCL for ggml, so its versions never exercise the path
this repo depends on.

llama.cpp `bf38346d` (2026-02-02,
[#19246](https://github.com/ggml-org/llama.cpp/pull/19246)) removed the NVIDIA
and AMD SYCL targets outright — `ggml-sycl/CMakeLists.txt` now hard-fails with
`GGML_SYCL_TARGET: Invalid target, the supported options are [INTEL]`. The same
commit dropped oneMath, which was only used on those code paths, so the
surviving INTEL target requires `MKL::MKL_SYCL::BLAS`. ggml 0.18.0 and
llama.cpp b10133 both carry it.

The stated reason is that Codeplay's oneAPI plugins for NVIDIA/AMD cannot be
downloaded any more — a *distribution* problem. It does not apply here: we
build intel/llvm from source with the CUDA and HIP backends compiled in, and
both device targets are verified working (`sycl-compile-amdgcn-amd-amdhsa`,
`sycl-compile-nvptx64-nvidia-cuda`, plus the `sycl-run-hip` GPU test).

Ceiling: **llama.cpp `b7910`** (2026-02-02 15:05) is the last tag with
`MATCHES "^(INTEL|NVIDIA|AMD)$"`; `b7911`, six hours later, is the first
without. Going past it needs either a revert of `bf38346d` carried as a patch,
or an upstream build-from-source path.

Unrelated but adjacent: **`src.ggml` does not build today**, at the committed
pins, for the same `MKL::MKL_SYCL::BLAS` reason (nixpkgs' mkl 2023.1.0 does not
provide that target). It has no dependents — whisper.cpp and llama.cpp vendor
their own ggml and `default.nix` does not pass ours to them — so nothing
noticed. CI's `ggml` job will fail on it.

## CI (`.github/`)

`build.yml` drives the composite action in `.github/actions/nix-build/`.

- It builds **`src-no-ccache.*`**, not `src.*`. The default set has
  `useCcache = true`, which needs a writable `/var/cache/ccache` bound into the
  build sandbox; hosted runners have none and the wrapper aborts at cmake's
  "check for working C compiler".
- The action's `free` input selects the pure path; unfree components (the
  oneAPI toolkits) need `free: "false"`, which switches to `--impure` +
  `NIXPKGS_ALLOW_UNFREE`. It is compared as a *string* — comparing against a
  bare `true`/`false` silently misbehaves, since GitHub coerces operands to
  numbers and an undeclared input is `''`.
- `passthru.impureTests` must never be referenced from CI: those need root and
  a real GPU.
- Test attributes are per-backend (`sycl-compile-<target>`); there is no plain
  `sycl-compile`.

Known gaps, deliberately not addressed:

- A full intel-llvm build on a 4-core hosted runner is likely to exceed the
  6 hour job limit, and disk is tight even with the `free-disk-space` step.
- The standalone chain (`llvm` -> stage1 -> stage2) is built but never
  exercised: every downstream job resolves to the monolithic l0 default. The
  `packages.${toolchain}.${backend}` matrix is not covered at all.

## Nix Gotchas

- Never use `2>&1` with nix commands — it breaks output
- The `ccacheWrapper` overlay in `flake.nix` forwards attributes that `ccache.links` drops from `cc.cc`, because cc-wrapper reads them off the `cc` argument:
  - `hardeningUnsupportedFlags*` — without these, `zerocallusedregs` re-enters `defaultHardeningFlags` and breaks downstream SPIR-V compilations. (Upstream `ccache.links` now forwards these itself, but keeping them is harmless.)
  - `langC`/`langCC` — cc-wrapper only emits the `-cxx-isystem` libstdc++ paths when `cc.langCC` is set. Without it `nix-support/libcxx-cxxflags` comes out **empty** while `-nostdlibinc` is still applied, so every C++ compile fails to find `<atomic>`. Only bites *clang* stdenvs, which is why the gcc-based default never showed it. This is an upstream nixpkgs bug worth reporting: `ccache.links` forwards `isClang`/`isGNU` but not `langCC`.
- `LLVM_INSTALL_PACKAGE_DIR` is set to an absolute `$dev` path; this causes `FindPrefixFromConfig.cmake` to hardcode `_IMPORT_PREFIX=$out`, so all cmake exports must use absolute `$dev/include` paths (not `_IMPORT_PREFIX`-relative)
