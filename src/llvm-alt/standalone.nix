{
  lib,
  cmake,
  parallel-hashmap,
  ninja,
  llvmPackages_22,
  callPackage,
  fetchFromGitHub,
  runCommand,
  zlib,
  zstd,
  unified-runtime,
  hwloc,
  spirv-headers,
  spirv-tools,
  applyPatches,
  libffi,
  libxml2,
  vc-intrinsics,
  emhash,
  libedit,
  overrideCC,
  opencl-headers,
  ocl-icd,
  pkg-config,
  python3,
  lit,
  symlinkJoin,
  ccacheStdenv,
  rocmPackages ? {},
  cudaPackages ? {},
  levelZeroSupport ? !(cudaSupport || rocmSupport),
  openclSupport ? true,
  cudaSupport ? false,
  rocmSupport ? false,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,
  nativeCpuSupport ? false,
  useCcache ? true,
  # This is a decent speedup over GNU ld
  useLld ? true,
}: let
  version = "7.0.0";
  # Commit date of the v7.0.0 tag. Some consumers check this to decide what
  # features the compiler supports; keep it in sync with `version`.
  date = "20260713";
  # The mainline LLVM release this Intel version is based on, from
  # cmake/Modules/LLVMVersion.cmake. Single source of truth: it feeds both the
  # version string handed to nixpkgs' llvmPackages machinery and the
  # BASE_LLVM_VERSION that out-of-tree components find_package() against.
  llvmVersion = "22.1.0";
  deps = callPackage ./deps.nix {};
  vc-intrinsics-src = applyPatches {
    src = deps.vc-intrinsics;
    patches = [./patches/vc-intrinsics-install-dirs.patch];
  };
  unified-runtime' = unified-runtime.override {
    inherit
      levelZeroSupport
      openclSupport
      cudaSupport
      rocmSupport
      rocmGpuTargets
      nativeCpuSupport
      rocmPackages
      cudaPackages
      ;
  };
  srcOrig = applyPatches {
    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      tag = "v${version}";
      hash = "sha256-l4InHzR/W6Gihoxt9CjEREyB9LDIDQggskzFIPIS2bA=";
    };

    # Monorepo-level patches only — per-component patches are applied in their
    # own derivation so editing one doesn't invalidate the whole monorepo src.
    # Regenerate via ./update-patches.fish if the packaging branches advance.
    patches = [
      # Fix hardcoded install paths (CMAKE_INSTALL_LIBDIR, etc.) across the
      # whole monorepo. Touches many subdirs so it must apply at root level.
      ./patches/gnu-install-dirs.patch
      # Clang checks CUDA_PATH env var only on Windows; package managers like
      # NixOS set it on Linux too. Teach CudaInstallationDetector to look there.
      ../llvm/cuda-path-env-linux.patch
      # Linux 7.x dropped <linux/scc.h>, which v7.0.0's compiler-rt still
      # includes. Backport of the upstream removal; drop once the pin moves.
      ../llvm/compiler-rt-drop-linux-scc.patch
    ];
  };
  src = srcOrig;
  llvmPackages = llvmPackages_22;
  hostTarget =
    {
      "x86_64" = "X86";
      "aarch64" = "AArch64";
    }
    .${
      stdenv.hostPlatform.parsed.cpu.name
    }
      or (throw "Unsupported CPU architecture: ${stdenv.hostPlatform.parsed.cpu.name}");

  # These are rather cheap and don't require any additional dependencies.
  # As such, if be always build all three we save needing to build llvm thrice.
  targetsToBuild = "${hostTarget};SPIRV;AMDGPU;NVPTX";

  # libdevice emits a set of device libraries per enabled LLVM target, and those
  # compiles are backend-specific in a way llvm itself is not: the NVPTX ones
  # need a CUDA toolkit for clang to pick a PTX ISA. Without one it falls back
  # to +ptx42 and the backend rejects sm_75 ("Minimum required PTX version is
  # 6.3"), so an l0- or rocm-only build cannot build them at all. Scope
  # libdevice to the targets the backend actually uses; llvm keeps building all
  # of them so it is still compiled once. Mirrors what buildbot/configure.py
  # does for the monolithic build.
  libdeviceTargets =
    "${hostTarget};SPIRV"
    + lib.optionalString rocmSupport ";AMDGPU"
    + lib.optionalString cudaSupport ";NVPTX";

  stdenv =
    if useCcache
    then ccacheStdenv.override {stdenv = llvmPackages.stdenv;}
    else llvmPackages.stdenv;
in
  (llvmPackages.override (_: {
    inherit stdenv;

    # We overlay llvmPackages_22 because that is the mainline release this tree
    # is based on and its patches are written against it. nixpkgs' llvmPackages
    # machinery wants a mainline-looking version string, so qualify it with our
    # release tag.
    version = "${llvmVersion}-${version}";

    officialRelease = null;
    gitRelease = {
      rev = "v${version}";
      rev-version = "${llvmVersion}-${version}";
    };

    monorepoSrc = src;

    doCheck = false;

    # Not all projects need all these flags,
    # but I don't think it hurts to always include them.
    # libllvm needs all of them, so we're not losing
    # incremental builds or anything.
    devExtraCmakeFlags = [
      "-DCMAKE_BUILD_TYPE=Release"
      "-DLLVM_ENABLE_ZSTD=FORCE_ON"
      "-DLLVM_ENABLE_ZLIB=FORCE_ON"
      "-DLLVM_ENABLE_THREADS=ON"

      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
      # NOTE: Fails with buildbot/configure.py as well when these are set
      (lib.cmakeBool "LLVM_LINK_LLVM_DYLIB" false)
      (lib.cmakeBool "LLVM_BUILD_LLVM_DYLIB" false)

      (lib.cmakeFeature "CLANG_DEFAULT_CXX_STDLIB" "libstdc++")

      (lib.cmakeFeature "SYCL_COMPILER_VERSION" date)

      (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
      (lib.cmakeBool "FETCHCONTENT_QUIET" false)

      (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_VC-INTRINSICS" "${vc-intrinsics-src}")

      (lib.cmakeFeature "LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR" "${spirv-headers.src}")
    ];
  })).overrideScope
  (
    llvmFinal: llvmPrev: let
      llvm-base =
        llvmPrev.libllvm.overrideAttrs
        (
          old: let
            src' = runCommand "llvm-src-${version}" {inherit (src) passthru;} ''
              mkdir -p "$out"
              cp -r ${src}/llvm "$out"
              cp -r ${src}/cmake "$out"
              cp -r ${src}/third-party "$out"
              cp -r ${src}/libc "$out"

              cp -r ${src}/sycl "$out"
              cp -r ${src}/sycl-jit "$out"
              cp -r ${src}/llvm-spirv "$out"

              chmod u+w "$out/llvm/tools"
              cp -r ${src}/polly "$out/llvm/tools"
            '';
          in {
            src = src';

            # Keep nixpkgs patches — our gnu-install-dirs branch is scoped to
            # Intel-specific files only and doesn't cover AddLLVM.cmake etc.

            nativeBuildInputs =
              old.nativeBuildInputs
              ++ lib.optionals useLld [
                llvmPackages.bintools
              ];

            buildInputs =
              old.buildInputs
              ++ [
                stdenv.cc.cc.lib
                hwloc

                emhash

                zstd
                zlib
                libedit
              ];

            propagatedBuildInputs = [
              zstd
              zlib
              libedit
            ];

            doCheck = false;

            cmakeFlags =
              old.cmakeFlags
              ++ [
                "-DLLVM_BUILD_TOOLS=ON"

                # spirv-to-ir-wrapper is built as a separate derivation against the
                # out-of-tree spirv-llvm-translator (which itself needs llvm). Disabling
                # it here breaks the in-tree cycle: llvm -> spirv-to-ir-wrapper -> libLLVMSPIRVLib -> llvm.
                (lib.cmakeBool "LLVM_TOOL_SPIRV_TO_IR_WRAPPER_BUILD" false)

                # These caused build issues, bodge
                "-DLLVM_INCLUDE_BENCHMARKS=OFF"

                "-DBUG_REPORT_URL=https://github.com/NixOS/nixpkgs/issues"
              ]
              ++ lib.optional useLld (lib.cmakeFeature "LLVM_USE_LINKER" "lld");
          }
        );
      # Shared shell fragment that adds libclc to the clang resource-root.
      # Used in both the stage-2 clang definition and its override function.
      #
      # clang's SYCL driver looks up libspirv at
      #   ${ResourceDir}/lib/${DeviceTriple}/libspirv.l64.signed_char.bc
      # libclc installs at share/clc/${target}/ — symlink each into resource lib.
      libclcRsrcCmds = ''
        mkdir -p $rsrc/lib
        ln -s ${llvmFinal.libclc}/share/clc $rsrc/lib/libclc
        for d in ${llvmFinal.libclc}/share/clc/*/; do
          ln -s "$d" "$rsrc/lib/$(basename "$d")"
        done
      '';

      # Shared shell fragment that adds libdevice's lib dir to cc-ldflags.
      # Needed so -lsycl-devicelib-host is found at link time (e.g. cmake's
      # check_cxx_compiler_flag("-fsycl") which links with -fsycl).
      libdeviceLdflags = ''
        echo " -L${llvmFinal.libdevice}/lib" >> $out/nix-support/cc-ldflags
      '';
    in {
      # Keep nixpkgs lld gnu-install-dirs patch (covers AddLLD.cmake).
      # Our Intel-scoped gnu-install-dirs doesn't touch lld.

      # Keep nixpkgs tblgen patches.
      tblgen =
        (llvmPrev.tblgen.override {
          clangPatches = [];
        }).overrideAttrs (old: {
          buildInputs =
            (old.buildInputs or [])
            ++ [
              zstd
              zlib
            ];
        });

      buildLlvmPackages = llvmFinal;

      # SYCL cross-compiles to SPIR-V which doesn't support zerocallusedregs;
      # wrapCCWith reads hardeningUnsupportedFlagsByTargetPlatform from cc.passthru.
      clang-unwrapped = llvmPrev.clang-unwrapped.overrideAttrs (old: {
        # PRE_RELEASE / DPCPP_VERSION_* are normally set by Intel's
        # cmake/Modules/DPCPPVersion.cmake, which is only included from
        # llvm/CMakeLists.txt. Standalone clang doesn't pick it up, so
        # Version.inc ends up with empty @PRE_RELEASE@ and Version.cpp fails
        # to compile. Pass the defaults explicitly.
        cmakeFlags =
          (old.cmakeFlags or [])
          ++ [
            (lib.cmakeFeature "PRE_RELEASE" "1")
            (lib.cmakeFeature "DPCPP_VERSION_MAJOR" "7")
            (lib.cmakeFeature "DPCPP_VERSION_MINOR" "1")
            (lib.cmakeFeature "DPCPP_VERSION_PATCH" "0")
          ];

        passthru =
          old.passthru
          // {
            hardeningUnsupportedFlagsByTargetPlatform = tp:
              (old.passthru.hardeningUnsupportedFlagsByTargetPlatform tp)
              ++ ["zerocallusedregs"];
          };

        # clang's SYCL offload toolchain finds helper tools via GetProgramPath("name"),
        # which searches C.getDriver().Dir (= $out/bin) first, then PATH. nixpkgs
        # applies getDev to propagatedBuildInputs, so llvmFinal.llvm becomes
        # llvmFinal.llvm.dev (only llvm-config in bin) in downstream PATH thus the PATH
        # fallback fails. Symlinking here ensures reliable lookup regardless of PATH.
        postInstall =
          (old.postInstall or "")
          # TODO: We need to symlink more tools (maybe just for-loop over all tools?)
          #       Or patch the lookup logic in clang itself
          + ''
            ln -s ${llvmFinal.llvm}/bin/llvm-foreach $out/bin/llvm-foreach
            ln -s ${llvmFinal.llvm}/bin/llvm-link $out/bin/llvm-link
            ln -s ${llvmFinal.llvm}/bin/llvm-objcopy $out/bin/llvm-objcopy
            ln -s ${llvmFinal.llvm}/bin/sycl-post-link $out/bin/sycl-post-link
            ln -s ${llvmFinal.llvm}/bin/file-table-tform $out/bin/file-table-tform
            ln -s ${llvmFinal.lld}/bin/lld $out/bin/lld
            ln -s ${llvmFinal.spirv-llvm-translator}/bin/llvm-spirv $out/bin/llvm-spirv
            ln -s ${llvmFinal.spirv-to-ir-wrapper}/bin/spirv-to-ir-wrapper $out/bin/spirv-to-ir-wrapper
          '';
      });

      # Stage-1: cc-wrapper without libdevice. libdevice builds with this so it
      # can't be propagated here (cycle).
      #
      # We use llvmPrev.clang.override to inherit nixpkgs' wrapCCWith setup,
      # which includes compiler-rt in the resource-root automatically.
      # nixpkgs creates $rsrc/lib as a symlink to compiler-rt/lib (which has
      # old linux/ naming). Intel LLVM also needs x86_64-unknown-linux-gnu/
      # naming, so we reconstruct lib/ as a real dir with both naming schemes.
      clang-stage-1 = llvmPrev.clang.override (prev: {
        cc = llvmFinal.clang-unwrapped;
        extraBuildCommands =
          prev.extraBuildCommands
          + ''
            comprt_lib=$(readlink "$rsrc/lib")
            rm "$rsrc/lib"
            mkdir "$rsrc/lib"
            ln -s "$comprt_lib/linux" "$rsrc/lib/linux"
            mkdir "$rsrc/lib/x86_64-unknown-linux-gnu"
            ln -s "$comprt_lib/linux/libclang_rt.builtins-x86_64.a" \
              "$rsrc/lib/x86_64-unknown-linux-gnu/libclang_rt.builtins.a"
            echo " -isystem ${llvmFinal.sycl}/include" >> "$out/nix-support/cc-cflags"
            echo " -L${llvmFinal.sycl}/lib" >> "$out/nix-support/cc-ldflags"

            ${
              lib.concatStrings (lib.mapAttrsToList (k: v: ''
                  echo "export ${k}=${v}" >> $out/nix-support/setup-hook
                '')
                unified-runtime'.setupVars)
            }
            ${lib.optionalString (unified-runtime'.setupVars ? CUDA_PATH) ''
              # SYCL CUDA runtime libs carry DT_NEEDED: libcuda.so.1.
              # GNU ld resolves transitive DT_NEEDED via -rpath-link; point it at the stubs.
              echo "-rpath-link,${unified-runtime'.setupVars.CUDA_PATH}/lib/stubs" >> $out/nix-support/cc-ldflags
            ''}
          '';

        extraPackages =
          prev.extraPackages
          ++ [
            opencl-headers
            llvmFinal.llvm
            llvmFinal.sycl
            llvmFinal.opencl-aot
            llvmFinal.xpti
            llvmFinal.xptifw
            llvmFinal.spirv-llvm-translator
            llvmFinal.spirv-to-ir-wrapper
          ];
      });

      # Stage-2: stage-1 + libdevice propagated. This is the public clang.
      clang =
        (llvmFinal.clang-stage-1.override (prev: {
          extraBuildCommands = prev.extraBuildCommands + libclcRsrcCmds + libdeviceLdflags;
          extraPackages = prev.extraPackages ++ [llvmFinal.libdevice];
        })).overrideAttrs (old: {
          passthru =
            old.passthru
            // {
              inherit (llvmFinal) stdenv;
              tests = callPackage ../llvm/tests.nix {
                inherit (llvmFinal) stdenv;
                inherit (unified-runtime') backends;
              };
            };
        });

      # Stage-1: clang-tools without libdevice. libdevice builds with this.
      clang-tools-stage-1 =
        llvmPrev.clang-tools.override
        {
          clang = llvmFinal.clang-stage-1;
        };

      # Stage-2: clang-tools with libdevice propagated. SYCL tools like
      # clang-sycl-linker and clang-linker-wrapper need libdevice at runtime.
      clang-tools = llvmFinal.clang-tools-stage-1.overrideAttrs (old: {
        propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [llvmFinal.libdevice];
      });

      stdenv = overrideCC llvmPackages.stdenv llvmFinal.clang;

      libllvm = llvm-base;

      opencl-aot = stdenv.mkDerivation (finalAttrs: {
        pname = "opencl-aot";
        inherit version;
        src = runCommand "opencl-aot-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/opencl "$out"

          mkdir -p "$out/unified-runtime/cmake"
          cp -r ${src}/unified-runtime/cmake/FetchOpenCL.cmake "$out/unified-runtime/cmake"
        '';

        patches = [
          ./patches/standalone-opencl.patch
        ];

        sourceRoot = "${finalAttrs.src.name}/opencl";

        nativeBuildInputs = [
          cmake
          ninja
        ];
        buildInputs = [
          llvmFinal.llvm
          libffi
          zstd
          zlib
          libxml2
          opencl-headers
          ocl-icd
        ];

        cmakeFlags = [
          "-DLLVM_BUILD_TOOLS=ON"
        ];
      });

      libclc =
        llvmPrev.libclc.overrideAttrs
        (old: {
          nativeBuildInputs =
            (builtins.filter (
                x: lib.getName x != "SPIRV-LLVM-Translator"
              )
              old.nativeBuildInputs)
            # Replace nixpkgs' spirv-llvm-translator (built against LLVM 21) with
            # our Intel fork built against Intel's LLVM.
            ++ [llvmFinal.spirv-llvm-translator];

          buildInputs =
            old.buildInputs
            ++ [
              zstd
              zlib
              # Required by libclc-remangler
              llvmFinal.clang.cc.dev
            ];

          cmakeFlags = [
            # Use the wrapped clang so C/CXX language tests pass (clang-only on
            # PATH would be picked up but can't link a basic test program — no
            # glibc/crt). The wrapper injects -fzero-call-used-regs which spirv64
            # doesn't support; counteract that with hardeningDisable below.
            (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
            # CLC compilation needs Intel's clang because the libclc CMakeLists
            # passes Intel-specific flags like --amdgpu-oclc-reflect-enable=false.
            # The outer stdenv.cc wraps nixpkgs LLVM (different rev). Intel's
            # unwrapped clang is fine here — CLC compiles to bitcode, no sysroot
            # needed.
            (lib.cmakeFeature "CMAKE_CLC_COMPILER" "${llvmFinal.clang.cc}/bin/clang")
            (lib.cmakeFeature "LLVM_EXTERNAL_LIT" "${lit}/bin/lit")

            "-DLLVM_BUILD_UTILS=ON"
            "-DLLVM_INSTALL_UTILS=ON"

            "-DLIBCLC_GENERATE_REMANGLED_VARIANTS=ON"
            # libclc now builds ONE target per cmake invocation (upstream commit
            # e7164d42243b overhauled the build). Pick the device triple based
            # on the active backend.
            (lib.cmakeFeature "LIBCLC_TARGET"
              (if rocmSupport then "amdgcn--amdhsa" # not -amd-, see postPatch
               else if cudaSupport then "nvptx64-nvidia-cuda"
               else if nativeCpuSupport then "native_cpu"
               else "spirv64-unknown-unknown"))
          ];

          # Drop all nixpkgs patches in favor of our standalone build support.
          patches = [
            ./patches/standalone-libclc.patch
          ];

          # v7.0.0 half-applied an upstream rename of libclc's AMD target: the
          # build spells it amdgcn--amdhsa, but the remangler names its output
          # after the canonical amdgcn-amd-amdhsa triple, which is what clang's
          # SYCL driver then looks for
          # (remangled-l64-signed_char.libspirv-amdgcn-amd-amdhsa.bc).
          # Building the amdgcn-amd-amdhsa spelling emits no remangled variants
          # at all, so register the other spelling and select it above.
          # src/llvm/unwrapped.nix carries the same workaround for the
          # monolithic build; drop both together on the next version bump.
          postPatch = lib.optionalString rocmSupport ''
            substituteInPlace CMakeLists.txt \
              --replace-fail $'  amdgcn-amd-amdhsa\n' $'  amdgcn-amd-amdhsa\n  amdgcn--amdhsa\n' \
              --replace-fail 'set( amdgcn-amd-amdhsa_devices none )' \
                $'set( amdgcn-amd-amdhsa_devices none )\nset( amdgcn--amdhsa_devices none )'
          '';

          # CLC compiles to spirv64 — same workaround as libdevice. The outer
          # ccache stdenv wraps nixpkgs' (not our) clang-unwrapped, so its
          # hardeningUnsupportedFlagsByTargetPlatform doesn't include
          # zerocallusedregs by default.
          hardeningDisable = ["zerocallusedregs"];

          # prepare_builtins was removed upstream; nixpkgs' postInstall still tries to install it
          postInstall = "";
          meta = removeAttrs old.meta ["mainProgram"];
        });

      spirv-llvm-translator = stdenv.mkDerivation (finalAttrs: {
        pname = "spirv-llvm-translator";
        inherit version;

        src = runCommand "spirv-llvm-translator-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/llvm-spirv "$out"
        '';

        sourceRoot = "${finalAttrs.src.name}/llvm-spirv";

        nativeBuildInputs = [
          cmake
          ninja
          llvmFinal.llvm.dev
        ];

        buildInputs = [
          llvmFinal.llvm
          spirv-headers
          spirv-tools
          zstd
          zlib
        ];

        cmakeFlags = [
          (lib.cmakeFeature "LLVM_DIR" "${llvmFinal.llvm.dev}/lib/cmake/llvm")
          (lib.cmakeBool "LLVM_SPIRV_INCLUDE_TESTS" false)
          (lib.cmakeBool "LLVM_SPIRV_ENABLE_LIBSPIRV_DIS" true)
          (lib.cmakeFeature "LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR" "${spirv-headers.src}")
          # llvm-spirv defaults BASE_LLVM_VERSION to 22.0.0 and find_package()s
          # LLVM with it, but Intel's tree is 22.1.0 — LLVM's config version file
          # requires an exact match, so the default never resolves. Only affects
          # out-of-tree builds; in-tree this find_package is not reached.
          (lib.cmakeFeature "BASE_LLVM_VERSION" llvmVersion)
        ];
      });

      spirv-to-ir-wrapper = stdenv.mkDerivation (finalAttrs: {
        pname = "spirv-to-ir-wrapper";
        inherit version;

        src = runCommand "spirv-to-ir-wrapper-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/llvm/tools/spirv-to-ir-wrapper "$out"
        '';

        sourceRoot = "${finalAttrs.src.name}/spirv-to-ir-wrapper";

        patches = [./patches/standalone-spirv-to-ir-wrapper.patch];

        nativeBuildInputs = [
          cmake
          ninja
          llvmFinal.llvm.dev
        ];

        buildInputs = [
          llvmFinal.llvm
          llvmFinal.spirv-llvm-translator
          zstd
          zlib
        ];

        cmakeFlags = [
          (lib.cmakeFeature "LLVM_DIR" "${llvmFinal.llvm.dev}/lib/cmake/llvm")
          (lib.cmakeFeature "LLVM_SPIRV_INCLUDE_DIRS" "${llvmFinal.spirv-llvm-translator}/include/LLVMSPIRVLib")
          (lib.cmakeFeature "LLVM_SPIRV_LIB" "${llvmFinal.spirv-llvm-translator}/lib/libLLVMSPIRVLib.a")
          "-DLLVM_BUILD_TOOLS=ON"
        ];
      });

      sycl = stdenv.mkDerivation (finalAttrs: {
        pname = "sycl";
        inherit version;
        inherit src;

        patches = [
          ./patches/standalone-sycl.patch
        ];

        sourceRoot = "${finalAttrs.src.name}/sycl";

        nativeBuildInputs =
          [
            cmake
            ninja
            pkg-config
          ]
          ++ unified-runtime'.nativeBuildInputs;

        buildInputs =
          [
            llvmFinal.xpti
            llvmFinal.xptifw
            llvmFinal.opencl-aot
            llvmFinal.llvm
            llvmFinal.clang.cc
            llvmFinal.clang.cc.dev
            (zstd.override {enableStatic = true;})
            zlib

            emhash
          ]
          ++ (lib.optional (rocmSupport || cudaSupport) llvmFinal.libclc)
          ++ (lib.optional rocmSupport llvmFinal.lld)
          ++ unified-runtime'.buildInputs;

        cmakeFlags =
          [
            # Used to find unified-runtime folder (`LLVM_SOURCE_DIR/../unified-runtime`)
            "-DLLVM_SOURCE_DIR=/build/${finalAttrs.src.name}/llvm"

            (lib.cmakeFeature "LLVM_EXTERNAL_LIT" "${lit}/bin/lit")

            "-DLLVM_EXTERNAL_XPTI_SOURCE_DIR=/build/${finalAttrs.src.name}/xpti"
            "-DLLVM_EXTERNAL_XPTIFW_SOURCE_DIR=/build/${finalAttrs.src.name}/xptifw"
            "-DLLVM_EXTERNAL_SYCL_JIT_SOURCE_DIR=/build/${finalAttrs.src.name}/sycl-jit"

            "-DSYCL_ENABLE_XPTI_TRACING=ON"
            "-DSYCL_ENABLE_BACKENDS=${lib.concatStringsSep ";" unified-runtime'.backends}"

            "-DLLVM_INCLUDE_TESTS=ON"
            "-DSYCL_INCLUDE_TESTS=ON"

            "-DSYCL_ENABLE_EXTENSION_JIT=ON"
            "-DSYCL_ENABLE_MAJOR_RELEASE_PREVIEW_LIB=ON"
            "-DSYCL_BUILD_PI_HIP_PLATFORM=AMD"

            (lib.cmakeFeature "SYCL_COMPILER_VERSION" date)

            (lib.cmakeBool "SYCL_UR_USE_FETCH_CONTENT" false)

            # LLVMConfig.cmake exports LLVM_TARGETS_TO_BUILD but not LLVM_HAS_*_TARGET.
            # sycl/CMakeLists.txt uses these to set SYCL_EXT_ONEAPI_BACKEND_{HIP,CUDA}
            # in feature_test.hpp, which gates inclusion of backend_traits_{hip,cuda}.hpp.
            (lib.cmakeBool "LLVM_HAS_AMDGPU_TARGET" rocmSupport)
            (lib.cmakeBool "LLVM_HAS_NVPTX_TARGET" cudaSupport)
          ]
          ++ unified-runtime'.cmakeFlags;

        # hwloc is in buildInputs (via unified-runtime'.buildInputs) but cmake doesn't
        # automatically link it; the same workaround is needed as in unified-runtime.nix.
        NIX_LDFLAGS = "-lhwloc";
      });

      libdevice = stdenv.mkDerivation (
        finalAttrs: let
          # cc-wrapper adds -mtls-dialect=gnu2 on x86 for any clang >= 19.1
          # (pkgs/build-support/cc-wrapper/default.nix). Intel's clang accepts
          # it for host compiles but rejects it under -fsycl-device-only with
          # "unsupported option '-mtls-dialect=' for target x86_64-...", and
          # every libdevice compile is device-only. Strip it from this wrapper
          # only, so host builds elsewhere keep TLSDESC.
          # The flag is emitted into add-local-cc-cflags-before.sh (machineFlags),
          # not cc-cflags; each wrapper sources its own copy, so stripping it
          # here does not affect any other compiler.
          libdeviceClang = llvmFinal.clang-stage-1.override (prev: {
            extraBuildCommands =
              prev.extraBuildCommands
              + ''
                sed -i 's/ *-mtls-dialect=[a-z0-9]*//g' \
                  $out/nix-support/add-local-cc-cflags-before.sh
              '';
          });
          tools = symlinkJoin {
            name = "libdevice-tools";
            paths = [
              llvmFinal.llvm
              libdeviceClang
              llvmFinal.clang-tools-stage-1
              # Provides llvm-spirv, which libdevice needs to emit the .spv
              # device libraries. It is not part of llvm/clang — in-tree it is
              # built from llvm-spirv/ into the same bin dir, which is why the
              # standalone build has to be told where it lives.
              llvmFinal.spirv-llvm-translator
            ];
            postBuild = ''
              rm $out/bin/clang
              ln -s $out/bin/clang++ $out/bin/clang
            '';
          };
        in {
          pname = "libdevice";
          inherit version;

          inherit src;
          sourceRoot = "${finalAttrs.src.name}/libdevice";

          nativeBuildInputs = [
            cmake
            ninja
            tools
          ];

          buildInputs = [
            llvmFinal.llvm
            llvmFinal.sycl
          ];

          patches = [
            ./patches/standalone-libdevice.patch
          ];

          hardeningDisable = ["zerocallusedregs"];

          cmakeFlags = [
            (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
            "-DLLVM_TOOLS_DIR=${llvmFinal.llvm}/bin"
            "-DCLANG_TOOLS_DIR=${llvmFinal.clang-tools-stage-1}/bin"
            # Despite being in libdevice, this flag is called LIBCLC_, this is not a typo.
            "-DLIBCLC_CUSTOM_LLVM_TOOLS_BINARY_DIR=${tools}/bin"
            "-DLIBDEVICE_TARGETS_TO_BUILD=${libdeviceTargets}"
          ];
        }
      );

      sycl-jit = stdenv.mkDerivation (finalAttrs: {
        pname = "sycl-jit";
        inherit version;

        inherit src;

        sourceRoot = "${finalAttrs.src.name}/sycl-jit";

        patches = [
          ./patches/standalone-sycl-jit.patch
          # Prevent sycl-jit from leaking cmake build-dir paths into the
          # generated ToolchainFiles table at runtime.
          ./patches/sycl-jit-exclude-cmake-files.patch
        ];

        nativeBuildInputs = [
          cmake
          ninja
          python3
          llvmFinal.llvm.dev
          llvmFinal.clang.cc.dev
        ];

        buildInputs = [
          llvmFinal.llvm
          llvmFinal.clang.cc
          opencl-headers
          zstd
          zlib
        ];

        preConfigure = ''
          resourceDir=$TMPDIR/jit-resources
          mkdir -p $resourceDir/include

          # SYCL headers from source tree
          cp -r /build/${finalAttrs.src.name}/sycl/include/* $resourceDir/include/

          # OpenCL headers (merge without clobbering sycl's CL/ files)
          cp -rn ${opencl-headers}/include/CL $resourceDir/include/ 2>/dev/null || true

          # Clang resource headers
          mkdir -p $resourceDir/lib/clang/23
          cp -r ${llvmFinal.libclang.lib}/lib/clang/23/include $resourceDir/lib/clang/23/
          chmod -R u+w $resourceDir

          # Pass to cmake via shell expansion (lib.cmakeFeature escapes $TMPDIR)
          cmakeFlagsArray+=("-DSYCL_JIT_RESOURCE_DIR=$resourceDir")
        '';

        cmakeFlags = [
          (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/cc")
          (lib.cmakeFeature "CMAKE_CXX_COMPILER" "${stdenv.cc}/bin/c++")
          (lib.cmakeFeature "LLVM_SPIRV_INCLUDE_DIRS" "${llvmFinal.spirv-llvm-translator}/include/LLVMSPIRVLib")
          (lib.cmakeFeature "CLANG" "${llvmFinal.clang.cc}/bin/clang++")
          (lib.cmakeFeature "LLVM_HOST_TRIPLE" stdenv.hostPlatform.config)
          (lib.cmakeFeature "LLVM_TARGETS_TO_BUILD" targetsToBuild)
        ];

        env.NIX_CFLAGS_COMPILE = "-isystem /build/${finalAttrs.src.name}/sycl/include";
      });

      libclang =
        llvmPrev.libclang.overrideAttrs
        (old: {
          # Keep nixpkgs libclang patches (AddClang.cmake etc.).

          buildInputs =
            (old.buildInputs or [])
            ++ [
              zstd
              zlib
              libedit
            ];

          postPatch = ''
            ${old.postPatch or ""}

            substituteInPlace lib/Driver/CMakeLists.txt \
                --replace-fail "DeviceConfigFile" ""
          '';
        });

      xpti = stdenv.mkDerivation (finalAttrs: {
        pname = "xpti";
        inherit version;

        src = runCommand "xpti-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/xpti "$out"
        '';

        sourceRoot = "${finalAttrs.src.name}/xpti";

        nativeBuildInputs = [
          cmake
          ninja
        ];

        cmakeFlags = [
          (lib.cmakeBool "XPTI_ENABLE_WERROR" true)
        ];
      });

      xptifw = stdenv.mkDerivation (finalAttrs: {
        pname = "xptifw";
        inherit version;

        src = runCommand "xptifw-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/xptifw "$out"

          mkdir -p "$out/sycl/cmake/modules"
          cp ${src}/sycl/cmake/modules/FetchEmhash.cmake "$out/sycl/cmake/modules"
        '';

        sourceRoot = "${finalAttrs.src.name}/xptifw";

        patches = [./patches/standalone-xptifw.patch];

        nativeBuildInputs = [
          cmake
          ninja
        ];

        buildInputs = [
          parallel-hashmap
          emhash
          llvmFinal.xpti
        ];

        cmakeFlags = [
          (lib.cmakeBool "XPTI_ENABLE_WERROR" true)
        ];
      });
    }
  )
