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
  levelZeroSupport ? true,
  openclSupport ? true,
  cudaSupport ? false,
  rocmSupport ? false,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,
  nativeCpuSupport ? false,
  useCcache ? true,
  # This is a decent speedup over GNU ld
  useLld ? true,
}: let
  version = "unstable-2026-02-24";
  date = "20260224";
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
      # tag = "v${version}";
      rev = "186cbd82259adde987b3e614708c7a91401d7652";
      hash = "sha256-0ySX7G2OE0WixbgO3/IlaQn6YYa8wCGjR1xq3ylbR/U=";
    };

    patches = [
      # Fix hardcoded install paths (CMAKE_INSTALL_LIBDIR, etc.)
      ./patches/gnu-install-dirs.patch
      # Prevent cyclic deps from bundled cmake files in sycl-jit
      ./patches/sycl-jit-exclude-cmake-files.patch
      # Clang checks CUDA_PATH env var only on Windows; package managers like
      # NixOS set it on Linux too. Teach CudaInstallationDetector to look there.
      ../llvm/cuda-path-env-linux.patch
    ];
  };
  src = runCommand "intel-llvm-src-fixed-${version}" {} ''
    cp -r ${srcOrig} $out
    chmod -R u+w $out

    # `NO_CMAKE_PACKAGE_REGISTRY` prevents it from finding OpenCL, so we unset it
    # Note that this cmake file is imported in various places, not just unified-runtime
    substituteInPlace $out/unified-runtime/cmake/FetchOpenCL.cmake \
      --replace-fail "NO_CMAKE_PACKAGE_REGISTRY" ""
  '';
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

  stdenv =
    if useCcache
    then ccacheStdenv.override {stdenv = llvmPackages.stdenv;}
    else llvmPackages.stdenv;
in
  (llvmPackages.override (_: {
    inherit stdenv;

    version = "22.0.0-${srcOrig.rev}";

    officialRelease = null;
    gitRelease = {
      rev = srcOrig.rev;
      rev-version = "22.0.0-unstable-2026-02-24";
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

            # gnu-install-dirs is already applied at the monorepo level (srcOrig)
            patches =
              builtins.filter
              (p: !(lib.hasInfix "gnu-install-dirs" (toString p)))
              old.patches;

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
      libclcRsrcCmds = ''
        mkdir -p $rsrc/lib
        ln -s ${llvmFinal.libclc}/share/clc $rsrc/lib/libclc
      '';

      # Shared shell fragment that adds libdevice's lib dir to cc-ldflags.
      # Needed so -lsycl-devicelib-host is found at link time (e.g. cmake's
      # check_cxx_compiler_flag("-fsycl") which links with -fsycl).
      libdeviceLdflags = ''
        echo " -L${llvmFinal.libdevice}/lib" >> $out/nix-support/cc-ldflags
      '';
    in {
      # gnu-install-dirs is pre-applied at monorepo level, so filter it out here
      lld = llvmPrev.lld.overrideAttrs (old: {
        patches =
          builtins.filter
          (p: !(lib.hasInfix "gnu-install-dirs" (toString p)))
          old.patches;
      });

      # gnu-install-dirs is pre-applied at monorepo level, so filter it out here
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
              tests = callPackage ../llvm/tests.nix {inherit (llvmFinal) stdenv;};
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
          ./patches/opencl.patch
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
            # Otherwise it'll misdetect the unwrapped just-built compiler as the compiler to use,
            # and configure will fail to compile a basic test program with it.
            (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
            (lib.cmakeFeature "LLVM_EXTERNAL_LIT" "${lit}/bin/lit")

            "-DLLVM_BUILD_UTILS=ON"
            "-DLLVM_INSTALL_UTILS=ON"

            "-DLIBCLC_GENERATE_REMANGLED_VARIANTS=ON"
            (lib.cmakeFeature "LIBCLC_TARGETS_TO_BUILD" (lib.strings.concatStringsSep ";" ((lib.optional cudaSupport "nvptx64-nvidia-cuda") ++ (lib.optional rocmSupport "amdgcn-amd-amdhsa"))))
            (lib.cmakeBool "LIBCLC_NATIVECPU_HOST_TARGET" nativeCpuSupport)
          ];

          # Drop all nixpkgs patches (gnu-install-dirs is pre-applied at monorepo level,
          # and the rest are replaced by our custom patches)
          patches = [
            ./patches/libclc-use-default-paths.patch
            ./patches/libclc-remangler.patch
            ./patches/libclc-find-clang.patch
            ./patches/libclc-standalone-output-dir.patch
          ];

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

        patches = [./patches/spirv-to-ir-wrapper.patch];

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
          ./patches/sycl.patch
          ./patches/sycl-build-ur.patch
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
      });

      libdevice = stdenv.mkDerivation (
        finalAttrs: let
          tools = symlinkJoin {
            name = "libdevice-tools";
            paths = [
              llvmFinal.llvm
              llvmFinal.clang-stage-1
              llvmFinal.clang-tools-stage-1
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
            ./patches/libdevice.patch
            ./patches/libdevice-sycllibdevice.patch
          ];

          hardeningDisable = ["zerocallusedregs"];

          cmakeFlags = [
            (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
            "-DLLVM_TOOLS_DIR=${llvmFinal.llvm}/bin"
            "-DCLANG_TOOLS_DIR=${llvmFinal.clang-tools-stage-1}/bin"
            # Despite being in libdevice, this flag is called LIBCLC_, this is not a typo.
            "-DLIBCLC_CUSTOM_LLVM_TOOLS_BINARY_DIR=${tools}/bin"
            "-DLLVM_TARGETS_TO_BUILD=${targetsToBuild}"
          ];
        }
      );

      sycl-jit = stdenv.mkDerivation (finalAttrs: {
        pname = "sycl-jit";
        inherit version;

        inherit src;

        sourceRoot = "${finalAttrs.src.name}/sycl-jit";

        patches = [
          ./patches/sycl-jit-standalone.patch
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
          mkdir -p $resourceDir/lib/clang/22
          cp -r ${llvmFinal.libclang.lib}/lib/clang/22/include $resourceDir/lib/clang/22/
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
          # gnu-install-dirs is already applied at the monorepo level
          patches =
            builtins.filter
            (p: !(lib.hasInfix "gnu-install-dirs" (toString p)))
            old.patches;

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
