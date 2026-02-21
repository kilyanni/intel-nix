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
  fetchpatch,
  libffi,
  libxml2,
  vc-intrinsics,
  emhash,
  libedit,
  wrapCCWith,
  overrideCC,
  intel-compute-runtime,
  intel-graphics-compiler,
  opencl-headers,
  ocl-icd,
  spirv-llvm-translator,
  pkg-config,
  python3,
  lit,
  # TODO: llvmPackages.libcxx? libcxxStdenv?
  libcxx,
  symlinkJoin,
  ccacheStdenv,
  rocmPackages ? {},
  level-zero,
  levelZeroSupport ? true,
  openclSupport ? true,
  # Not yet working
  cudaSupport ? false,
  rocmSupport ? false,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,
  nativeCpuSupport ? false,
  useLibcxx ? false,
  useCcache ? true,
  # This is a decent speedup over GNU ld
  useLld ? true,
}: let
  version = "unstable-2025-11-14";
  date = "20251114";
  deps = callPackage ./deps.nix {};
  unified-runtime' = unified-runtime.override {
    inherit
      levelZeroSupport
      openclSupport
      cudaSupport
      rocmSupport
      rocmGpuTargets
      nativeCpuSupport
      ;
  };
  srcOrig = applyPatches {
    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      # tag = "v${version}";
      rev = "ab3dc98de0fd1ada9df12b138de1e1f8b715cc27";
      hash = "sha256-oHk8kQVNsyC9vrOsDqVoFLYl2yMMaTgpQnAW9iHZLfE=";
    };

    patches = [
      # Fix hardcoded paths for llvm-foreach and llvm-link in SYCL toolchain
      ./patches/sycl-path-lookup.patch
      # Fix hardcoded install paths (CMAKE_INSTALL_LIBDIR, etc.)
      ./patches/gnu-install-dirs.patch
      # Prevent cyclic deps from bundled cmake files in sycl-jit
      ./patches/sycl-jit-exclude-cmake-files.patch
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
      stdenv.targetPlatform.parsed.cpu.name
    }
      or (throw "Unsupported CPU architecture: ${stdenv.targetPlatform.parsed.cpu.name}");

  # TODO: Don't build targets not pulled in by *Support = true
  targetsToBuild = "${hostTarget};SPIRV;AMDGPU;NVPTX";

  stdenv = let
    base =
      if useLibcxx
      then llvmPackages.libcxxStdenv
      else llvmPackages.stdenv;
  in
    if useCcache
    then ccacheStdenv.override {stdenv = base;}
    else base;
in
  (llvmPackages.override (_: {
    inherit stdenv;

    version = "22.0.0-${srcOrig.rev}";

    officialRelease = null;
    gitRelease = {
      rev = srcOrig.rev;
      rev-version = "22.0.0-unstable-2025-11-14";
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
      # TODO
      "-DLLVM_ENABLE_ZLIB=FORCE_ON"
      "-DLLVM_ENABLE_THREADS=ON"

      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
      # NOTE: Fails with buildbot/configure.py as well when these are set
      (lib.cmakeBool "LLVM_LINK_LLVM_DYLIB" false)
      (lib.cmakeBool "LLVM_BUILD_LLVM_DYLIB" false)

      (lib.cmakeBool "LLVM_ENABLE_LIBCXX" useLibcxx)
      (lib.cmakeFeature "CLANG_DEFAULT_CXX_STDLIB" (
        if useLibcxx
        then "libc++"
        else "libstdc++"
      ))

      (lib.cmakeFeature "SYCL_COMPILER_VERSION" date)

      (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
      (lib.cmakeBool "FETCHCONTENT_QUIET" false)

      (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_VC-INTRINSICS" "${deps.vc-intrinsics}")

      (lib.cmakeFeature "LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR" "${spirv-headers.src}")
    ];
  })).overrideScope
  (
    llvmFinal: llvmPrev:
    let
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

                # Disable benchmark to avoid C2y extension errors with __COUNTER__ in benchmark.h
                "-DLLVM_INCLUDE_BENCHMARKS=OFF"
              ]
              ++ lib.optional useLld (lib.cmakeFeature "LLVM_USE_LINKER" "lld");

            postInstall =
              ''
                # LLVMSPIRVLib headers still install to $out/include (not covered by gnu-install-dirs)
                if [ -d "$out/include/LLVMSPIRVLib" ]; then
                  mv $out/include/LLVMSPIRVLib $dev/include/
                  find $out/include -type d -empty -delete 2>/dev/null || true
                fi
              ''
              + (old.postInstall or "");

            postFixup =
              (old.postFixup or "")
              + ''
                # Patch *.cmake and *.pc files to reference $dev/include instead of $out/include
                find "$dev" -type f \( -name "*.cmake" -o -name "*.pc" \) \
                  -exec sed -i \
                    -e 's|'"$out"'/include|'"$dev"'/include|g' \
                    -e 's|''${_IMPORT_PREFIX}/include|'$dev'/include|g' \
                    {} +

                # Patch executables in dev bin directory
                if [ -d "$dev/bin" ]; then
                  find "$dev/bin" -type f -executable \
                    -exec sed -i \
                      -e 's|'"$out"'/include|'"$dev"'/include|g' \
                      {} + 2>/dev/null || true
                fi
              '';
          }
        );
      llvm-with-intree-spirv = llvm-base.overrideAttrs (oldAttrs: {
        cmakeFlags =
          oldAttrs.cmakeFlags
          ++ [
            "-DLLVM_EXTERNAL_PROJECTS=llvm-spirv"
            "-DLLVM_EXTERNAL_LLVM_SPIRV_SOURCE_DIR=/build/${oldAttrs.src.name}/llvm-spirv"

            # These require clang, which we don't have at this point.
            # TODO: Build these later, e.g. in passthru.tests
            "-DLLVM_SPIRV_INCLUDE_TESTS=OFF"

            "-DLLVM_SPIRV_ENABLE_LIBSPIRV_DIS=ON"
          ];

        buildInputs =
          oldAttrs.buildInputs
          ++ [
            # For libspirv_dis
            spirv-tools
          ];
      });
    in {
      # Override tblgen to not apply nixpkgs' clangPatches (gnu-install-dirs is pre-applied at monorepo level)
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

      # Override buildLlvmPackages so libllvm uses our tblgen (built from Intel's source)
      # instead of the one from otherSplices.selfBuildHost (nixpkgs' original)
      buildLlvmPackages = llvmFinal;

      # All components merged without the cc-wrapper, analogous to
      # the monolithic build's `self.unwrapped`.
      unwrapped = symlinkJoin {
        pname = "intel-llvm-unwrapped";
        inherit version;
        paths = with llvmFinal; [
          llvm
          # Use raw clang binary (clang.cc), NOT the Intel cc-wrapper (clang).
          # Our own wrapper handles all wrapping; including the wrapper
          # would cause double-wrapping where the inner wrapper re-adds
          # hardening flags (e.g. zerocallusedregs) that ours removed.
          clang.cc
          # lib output contains clang built-in headers (stddef.h, etc.)
          # used by the resource-dir symlink in the wrapper
          libclang.lib
          sycl
          sycl-jit
          opencl-aot
          xpti
          xptifw
          libdevice
        ];
        # isClang is needed so the cc-wrapper sets up gcc-toolchain
        # flags (--gcc-toolchain, -cxx-isystem for C++ stdlib headers).
        # hardeningUnsupportedFlagsByTargetPlatform mirrors the standard
        # nixpkgs clang so platform-inappropriate hardening flags (e.g.
        # pacret on x86_64) are properly excluded.
        passthru = {
          isClang = true;
          hardeningUnsupportedFlagsByTargetPlatform = tp:
            (llvmPackages.clang.cc.hardeningUnsupportedFlagsByTargetPlatform tp)
            # SYCL cross-compiles to SPIR-V which doesn't support this
            ++ ["zerocallusedregs"];
        };
      };

      # cc-wrapper that sets up proper compiler flags (gcc-toolchain,
      # resource-dir, SYCL headers). Without this, clang resolves
      # symlinks via /proc/self/exe and looks for headers relative to
      # the real clang derivation, missing headers from other components.
      clang = (wrapCCWith {
        cc = llvmFinal.unwrapped;
        extraBuildCommands = ''
          rsrc="$out/resource-root"
          mkdir "$rsrc"
          echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
          ln -s "${lib.getLib llvmFinal.unwrapped}/lib/clang/22/include" "$rsrc"
          # Unlike the monolithic build, standalone components are in
          # separate derivations. Clang's InstalledDir-relative header
          # search won't find SYCL headers, so we add them explicitly.
          echo " -isystem ${llvmFinal.unwrapped}/include" >> $out/nix-support/cc-cflags
        '';
      }).overrideAttrs (old: {
        # OpenCL headers need to be propagated so users of this stdenv
        # can compile SYCL code that includes <CL/cl.h>.
        propagatedBuildInputs = (old.propagatedBuildInputs or []) ++ [opencl-headers];
      });

      # Merged output with wrapper first so its nix-support/ takes precedence.
      merged = symlinkJoin {
        pname = "intel-llvm";
        inherit version;
        paths = [
          llvmFinal.clang
          llvmFinal.unwrapped
        ];
        passthru = {
          inherit (llvmFinal) stdenv;
          tests = callPackage ../llvm/tests.nix {inherit (llvmFinal) stdenv;};
        };
      };

      stdenv = overrideCC llvmPackages.stdenv llvmFinal.merged;

      libllvm = llvm-with-intree-spirv;

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
            builtins.filter (
              x: lib.getName x != "SPIRV-LLVM-Translator"
            )
            old.nativeBuildInputs;

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

            # Intel's fork doesn't set LIBCLC_INSTALL_DIR for standalone builds (upstream does)
            "-DLIBCLC_INSTALL_DIR=share/clc"
          ];

          # Drop all nixpkgs patches (gnu-install-dirs is pre-applied at monorepo level,
          # and the rest are replaced by our custom patches)
          patches = [
            ./patches/libclc-use-default-paths.patch
            ./patches/libclc-remangler.patch
            ./patches/libclc-find-clang.patch
            ./patches/libclc-utils.patch
          ];

          preInstall = ''
            # TODO: Figure out why this is needed
            cp utils/prepare_builtins prepare_builtins
          '';
        });

      spirv-llvm-translator = spirv-llvm-translator.overrideAttrs (
        oldAttrs: let
          src' = runCommand "spirv-llvm-translator-src-${version}" {inherit (src) passthru;} ''
            mkdir -p "$out"
            cp -r ${src}/llvm-spirv "$out"
          '';
        in {
          src = src';
          sourceRoot = "${src'.name}/llvm-spirv";
        }
      );

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
          ]
          ++ unified-runtime'.cmakeFlags;
      });

      libdevice = stdenv.mkDerivation (
        finalAttrs: let
          # Uses the cc-wrapper (llvmFinal.clang) intentionally: the rm/ln -s trick
          # replaces the `clang` wrapper script with `clang++`'s, so anything invoking
          # `clang` gets C++ mode. This wouldn't work with clang.cc (raw binary) since
          # argv[0] determines mode regardless of symlink target.
          tools = symlinkJoin {
            name = "libdevice-tools";
            paths = [
              llvmFinal.llvm
              llvmFinal.clang
              llvmFinal.clang-tools
            ];
            postBuild = ''
              rm $out/bin/clang
              ln -s $out/bin/clang++ $out/bin/clang
              ln -s ${llvmFinal.libclc}/bin/prepare_builtins $out/bin/prepare_builtins
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
            "-DCLANG_TOOLS_DIR=${llvmFinal.clang-tools}/bin"
            # Despite being in libdevice, this flag is called LIBCLC_
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

        # Stage resource files (sycl headers, OpenCL headers, clang resource
        # headers) into a directory that generate.py will embed into the
        # sycl-jit library via C23 #embed.
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
          (lib.cmakeFeature "LLVM_SPIRV_INCLUDE_DIRS" "${llvmFinal.llvm.dev}/include/LLVMSPIRVLib")
          # SYCL_JIT_RESOURCE_DIR is set via cmakeFlagsArray in preConfigure
          # Tell get_host_tool_path where to find clang for resource compilation
          (lib.cmakeFeature "CLANG" "${llvmFinal.clang.cc}/bin/clang++")
          (lib.cmakeFeature "LLVM_HOST_TRIPLE" stdenv.hostPlatform.config)
          (lib.cmakeFeature "LLVM_TARGETS_TO_BUILD" targetsToBuild)
        ];

        # Sycl headers include path (for sycl/detail/string.hpp)
        env.NIX_CFLAGS_COMPILE = "-isystem /build/${finalAttrs.src.name}/sycl/include";
      });

      # Override libclang to use Intel's source with gnu-install-dirs pre-applied at monorepo level
      libclang =
        llvmPrev.libclang.overrideAttrs
        (old: {
          # gnu-install-dirs is already applied at the monorepo level (srcOrig)
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
