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
  tree,
  wrapCCWith,
  overrideCC,
  intel-compute-runtime,
  intel-graphics-compiler,
  opencl-headers,
  ocl-icd,
  spirv-llvm-translator,
  pkg-config,
  emptyDirectory,
  lit,
  # TODO: llvmPackages.libcxx? libcxxStdenv?
  libcxx,
  strace,
  symlinkJoin,
  ccacheStdenv,
  rocmPackages ? {},
  level-zero,
  levelZeroSupport ? true,
  openclSupport ? true,
  # Broken
  cudaSupport ? false,
  rocmSupport ? false,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,
  nativeCpuSupport ? false,
  useLibcxx ? false,
  useCcache ? true,
  # This is a decent speedup over GNU ld
  useLld ? true,
  buildTests ? false,
  buildDocs ? false,
  buildMan ? false,
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
      buildTests
      ;
  };
  srcOrig = applyPatches {
    # src = fetchFromGitHub {
    #   owner = "intel";
    #   repo = "llvm";
    #   # tag = "v${version}";
    #   rev = "64928c5154d7a0d8b5f03e7771ce7411d14fea20";
    #   hash = "sha256-WTxZre8cpOQjR2K8TX3ygZxn5Math0ofs+l499RsgsI=";
    # };

    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      # tag = "v${version}";
      rev = "ab3dc98de0fd1ada9df12b138de1e1f8b715cc27";
      hash = "sha256-oHk8kQVNsyC9vrOsDqVoFLYl2yMMaTgpQnAW9iHZLfE=";
    };

    patches = [
      # https://github.com/intel/llvm/pull/19845
      (fetchpatch {
        name = "make-sycl-version-reproducible";
        url = "https://github.com/intel/llvm/commit/1c22570828e24a628c399aae09ce15ad82b924c6.patch";
        hash = "sha256-leBTUmanYaeoNbmA0m9VFX/5ViACuXidWUhohewshQQ=";
      })
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
  # TODO
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
  targetsToBuild' = "${hostTarget};SPIRV;AMDGPU;NVPTX";
  targetsToBuild = "host;SPIRV;AMDGPU;NVPTX";

  stdenv =
    let
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
    #inherit src;

    version = "22.0.0-${srcOrig.rev}";

    # officialRelease = {};
    officialRelease = null;
    gitRelease = {
      rev = srcOrig.rev;
      rev-version = "22.0.0-unstable-2025-11-14";
    };

    monorepoSrc = src;

    doCheck = false;

    # enableSharedLibraries = false;

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

      # Breaks tablegen build somehow
      # "-DLLVM_ENABLE_LTO=Thin"
      # "-DCMAKE_AR=${llvmPackages.bintools}/bin/ranlib"
      # "-DCMAKE_STRIP=${llvmPackages.bintools}/bin/ranlib"
      # "-DCMAKE_RANLIB=${llvmPackages.bintools}/bin/ranlib"

      (lib.cmakeBool "BUILD_SHARED_LIBS" false)
      # # TODO: configure fails when these are true, but I've no idea why
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

      (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_ONEAPI-CK" "${deps.oneapi-ck}")
    ];
  })).overrideScope
  (
    llvmFinal: llvmPrev: {
      # prev = throw llvmPrev.tblgen;
      tblgen = llvmPrev.tblgen.overrideAttrs (old: {
        # TODO: This is sketchy
        # buildInputs = (old.buildInputs or []) ++ [vc-intrinsics];
        buildInputs =
          (old.buildInputs or [])
          ++ [
            zstd
            zlib
          ];
      });

      buildLlvmTools = {
        inherit
          (llvmFinal)
          tblgen
          llvm
          libclc
          clang
          ;
      };

      merged = symlinkJoin {
        pname = "intel-llvm";
        inherit version;
        paths = with llvmFinal; [
          llvm
          clang
          sycl
          opencl-aot
          xpti
          xptifw
          libdevice
        ];
      };

      stdenv = llvmPrev.stdenv.override {
        cc = llvmFinal.merged;
      };
      #stdenv = llvmPrev.stdenv.overrideAttrs (old: {
      #  propagatedBuildInputs =
      #    old.propagatedBuildInputs
      #    ++ [
      #      llvmFinal.merged
      #    ];
      #});

      # Synthetic, not to be built directly
      llvm-base =
        (llvmPrev.libllvm.override {
          buildLlvmTools = llvmFinal.buildLlvmTools;
          # tblgen = llvmFinal.tblgen;
        }).overrideAttrs
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
              # cp -r ${src}/unified-runtime "$out"

              chmod u+w "$out/llvm/tools"
              cp -r ${src}/polly "$out/llvm/tools"

              # chmod u+w "$out/llvm/projects"
              # cp -r ${vc-intrinsics.src} "$out/llvm/projects"
            '';
          in {
            # inherit src;
            src = src';

            # prev = throw (builtins.map (x: builtins.toString x.out.name) old.nativeBuildInputs);
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
                # spirv-llvm-translator'

                # vc-intrinsics

                # For libspirv_dis
                # spirv-tools

                # overrides.xpti
              ];
            # ++ unified-runtime'.buildInputs;

            propagatedBuildInputs = [
              zstd
              zlib
              libedit
              #   hwloc
            ];

            doCheck = false;

            cmakeFlags =
              old.cmakeFlags
              ++ [
                # Off to save build time, TODO: Reenable
                # "-DLLVM_ENABLE_LTO=Thin"

                # TODO: Only enable conditionally
                # Maybe conditional will cause issues with libclc (looking at buildbot/configure.py)
                # ??

                # # This cuts build time a bit but I'm unsure if this should be kept
                # "-DLLVM_TARGETS_TO_BUILD=${targetsToBuild}"

                # "-DLLVM_EXTERNAL_VC_INTRINSICS_SOURCE_DIR=${vc-intrinsics.src}"
                #"-DLLVM_EXTERNAL_PROJECTS=sycl;llvm-spirv;opencl;xpti;xptifw;libdevice;sycl-jit"
                # "-DLLVM_EXTERNAL_PROJECTS=sycl;llvm-spirv"
                # "-DLLVM_EXTERNAL_PROJECTS=llvm-spirv"
                # "-DLLVM_EXTERNAL_SYCL_SOURCE_DIR=/build/${src'.name}/sycl"
                # "-DLLVM_EXTERNAL_LLVM_SPIRV_SOURCE_DIR=/build/${src'.name}/llvm-spirv"
                #"-DLLVM_EXTERNAL_XPTI_SOURCE_DIR=/build/${src'.name}/xpti"
                #"-DXPTI_SOURCE_DIR=/build/${src'.name}/xpti"
                #"-DLLVM_EXTERNAL_XPTIFW_SOURCE_DIR=/build/${src'.name}/xptifw"
                #"-DLLVM_EXTERNAL_LIBDEVICE_SOURCE_DIR=/build/${src'.name}/libdevice"
                # "-DLLVM_EXTERNAL_SYCL_JIT_SOURCE_DIR=/build/${src'.name}/sycl-jit"
                #"-DLLVM_ENABLE_PROJECTS=clang\;sycl\;llvm-spirv\;opencl\;xpti\;xptifw\;libdevice\;sycl-jit\;libclc\;lld"
                # "-DLLVM_ENABLE_PROJECTS=llvm-spirv"

                # These require clang, which we don't have at this point.
                # TODO: Build these later, e.g. in passthru.tests
                # "-DLLVM_SPIRV_INCLUDE_TESTS=OFF"

                # "-DLLVM_SPIRV_ENABLE_LIBSPIRV_DIS=ON"

                "-DLLVM_BUILD_TOOLS=ON"

                # "-DSYCL_ENABLE_XPTI_TRACING=ON"
                # "-DSYCL_ENABLE_BACKENDS=level_zero;level_zero_v2;cuda;hip"

                # "-DSYCL_INCLUDE_TESTS=ON"

                # "-DSYCL_ENABLE_WERROR=ON"

                # # # Currently broken. IDK if this is even useful though.
                # # "-DLLVM_USE_STATIC_ZSTD=ON"

                # "-DSYCL_ENABLE_EXTENSION_JIT=ON"
                # "-DSYCL_ENABLE_MAJOR_RELEASE_PREVIEW_LIB=ON"
                # "-DSYCL_ENABLE_WERROR=ON"
                # "-DSYCL_BUILD_PI_HIP_PLATFORM=AMD"

                # (if pkgs.stdenv.cc.isClang then throw "hiii" else "")
              ]
              # ++ lib.optionals pkgs.stdenv.cc.isClang [
              #   # (lib.cmakeFeature "CMAKE_C_FLAGS_RELEASE" "-flto=thin\\\\ -ffat-lto-objects")
              #   # (lib.cmakeFeature "CMAKE_CXX_FLAGS_RELEASE" "-flto=thin\\\\ -ffat-lto-objects")
              #   "-DCMAKE_C_FLAGS_RELEASE=-flto=thin -ffat-lto-objects"
              #   "-DCMAKE_CXX_FLAGS_RELEASE=-flto=thin -ffat-lto-objects"
              # ]
              ++ lib.optional useLld (lib.cmakeFeature "LLVM_USE_LINKER" "lld")
              # ++ unified-runtime'.cmakeFlags
              # ++ ["-DUR_ENABLE_TRACING=OFF"]
              ;

            preConfigure =
              old.preConfigure
              + ''
                # cmakeFlagsArray+=(
                #   "-DCMAKE_C_FLAGS_RELEASE=-O3 -DNDEBUG -march=skylake -mtune=znver3 -flto=thin -ffat-lto-objects"
                #   "-DCMAKE_CXX_FLAGS_RELEASE=-O3 -DNDEBUG -march=skylake -mtune=znver3 -flto=thin -ffat-lto-objects"
                # )
              '';

            postInstall =
              ''
                # Check if the rogue include directory was created in $out
                if [ -d $out/include ]; then
                  # Move its contents to the correct destination

                  echo "searchmarker 123123123"
                  echo ------------
                  ${tree}/bin/tree $out
                  echo ------------
                  ${tree}/bin/tree $dev
                  echo ------------

                  mv $out/include/LLVMSPIRVLib $dev/include/
                  mv $out/include/llvm/ExecutionEngine/Interpreter/* $dev/include/llvm/ExecutionEngine/Interpreter/
                  mv $out/include/llvm/SYCLLowerIR/* $dev/include/llvm/SYCLLowerIR/

                  # Remove the now-empty directory so fixupPhase doesn't see it
                  rmdir $out/include/llvm/ExecutionEngine/Interpreter
                  rmdir $out/include/llvm/ExecutionEngine
                  rmdir $out/include/llvm/SYCLLowerIR
                  rmdir $out/include/llvm
                  rmdir $out/include
                fi
              ''
              + (old.postInstall or "");
            #
            postFixup =
              (old.postFixup or "")
              + ''
                #####################################
                # Patch *.cmake and *.pc files
                #####################################
                find "$dev" -type f \( -name "*.cmake" -o -name "*.pc" \) | while read -r f; do
                  tmpf="$(mktemp)"
                  cp "$f" "$tmpf"

                  sed -i \
                    -e 's|'"$out"'/include|'"$dev"'/include|g' \
                    -e 's|''${_IMPORT_PREFIX}/include|'$dev'/include|g' \
                    "$f"

                  if ! diff -q "$tmpf" "$f" >/dev/null; then
                    echo "Changed: $f"
                    diff -u "$tmpf" "$f" || true
                  fi

                  rm -f "$tmpf"
                done || true

                #####################################
                # Patch executables in bin directory
                #####################################
                if [ -d "$dev/bin" ]; then
                  find "$dev/bin" -type f -executable | while read -r f; do
                    tmpf="$(mktemp)"
                    cp "$f" "$tmpf"

                    sed -i \
                      -e 's|'"$out"'/include|'"$dev"'/include|g' \
                      "$f" 2>/dev/null || true

                    if ! diff -q "$tmpf" "$f" >/dev/null; then
                      echo "Changed: $f"
                      diff -u "$tmpf" "$f" || true
                    fi

                    rm -f "$tmpf"
                  done || true
                fi          '';
          }
        );

      llvm-no-spirv = llvmFinal.llvm-base.overrideAttrs (oldAttrs: {
        postPatch =
          oldAttrs.postPatch
          + ''
            rm -rf tools/spirv-to-ir-wrapper
          '';
      });

      llvm-with-intree-spirv = llvmFinal.llvm-base.overrideAttrs (oldAttrs: {
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
          llvmFinal.llvm-no-spirv.dev
          llvmFinal.spriv-llvm-translator.dev
        ];
        buildInputs = [
          llvmFinal.llvm-no-spirv
          llvmFinal.spriv-llvm-translator
        ];
      });

      # llvm = symlinkJoin {
      #   name = "llvm";
      #   paths = [overrides.spirv-to-ir-wrapper overrides.llvm-no-spirv];
      # };
      # llvm = overrides.llvm-no-spirv;
      # llvm = overrides.llvm-base;
      libllvm = llvmFinal.llvm-with-intree-spirv;

      opencl-aot = stdenv.mkDerivation (finalAttrs: {
        pname = "opencl-aot";
        inherit version;
        src = runCommand "opencl-aot-src-${version}" {inherit (src) passthru;} ''
          mkdir -p "$out"
          cp -r ${src}/opencl "$out"
          # cp -r ${src}/cmake "$out"

          # mkdir -p "$out/cmake"
          mkdir -p "$out/unified-runtime/cmake"
          cp -r ${src}/unified-runtime/cmake/FetchOpenCL.cmake "$out/unified-runtime/cmake"
        '';
        # inherit src;
        #
        patches = [
          ./patches/opencl.patch
          # ./patches/opencl-aot.patch
        ];

        sourceRoot = "${finalAttrs.src.name}/opencl";
        # sourceRoot = "${finalAttrs.src.name}/sycl";

        # outputs = [
        #   "out"
        #   "dev"
        #   "lib"
        # ];

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

        # nativeBuildInputs = [cmake ninja] ++ unified-runtime'.nativeBuildInputs;

        # buildInputs = [overrides.xpti] ++ unified-runtime'.buildInputs;

        cmakeFlags = [
          # "-DLLVM_TARGETS_TO_BUILD=${targetsToBuild'}"
          # "-DCMAKE_MODULE_PATH=${finalAttrs.src}/cmake"
          "-DLLVM_BUILD_TOOLS=ON"
          # (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_OCL-HEADERS" "${deps.opencl-headers}")
          # (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_OCL-ICD" "${deps.opencl-icd-loader}")
        ];
      });

      libclc =
        (llvmPrev.libclc.override {
          buildLlvmTools = llvmFinal.buildLlvmTools;
        }).overrideAttrs
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

            # (lib.cmakeBool "LIBCLC_GENERATE_REMANGLED_VARIANTS" false)
          ];

          patches =
            [
              (builtins.head old.patches)
            ]
            ++ [
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

      vc-intrinsics = vc-intrinsics.override {
        # llvmPackages_22 = llvmPkgs // overrides;
      };

      # spirv-llvm-translator = stdenv.mkDerivation (finalAttrs: {
      spirv-llvm-translator = spirv-llvm-translator.overrideAttrs (
        oldAttrs: let
          src' = runCommand "sycl-src-${version}" {inherit (src) passthru;} ''
            mkdir -p "$out"
            cp -r ${src}/llvm-spirv "$out"
          '';
        in {
          # pname = "SPIRV-LLVM-Translator";
          # inherit version;
          src = src';
          sourceRoot = "${src'.name}/llvm-spirv";

          # nativeBuildInputs = [
          #   pkg-config
          #   cmake
          #   llvmPackages.llvm.dev
          # ];
        }
      );

      sycl = stdenv.mkDerivation (finalAttrs: {
        pname = "sycl";
        inherit version;
        # src = runCommand "sycl-src-${version}" {inherit (src) passthru;} ''
        #   mkdir -p "$out"
        #   cp -r ${src}/sycl "$out"
        #   cp -r ${src}/cmake "$out"

        #   chmod u+w "$out/sycl"
        #   cp -r ${src}/unified-runtime "$out/sycl"

        #   mkdir -p "$out/sycl/llvm/cmake"
        #   cp -r ${src}/llvm/cmake/modules "$out/sycl/llvm/cmake/modules"
        # '';
        inherit src;

        patches = [
          ./patches/sycl.patch
          ./patches/sycl-build-ur.patch
          # ./patches/sycl-incl.patch
          # ./patches/unified-runtime.patch
          # ./patches/unified-runtime-2.patch
        ];
        # prePatch = ''
        #   ls ../unified-runtime
        #   cat ../unified-runtime/source/adapters/level_zero/common.cpp
        # '';
        # postPatch = ''
        #   pushd ../unified-runtime
        #   chmod -R u+w .
        #   patch -p1 < ${./patches/unified-runtime.patch}
        #   patch -p1 < ${./patches/unified-runtime-2.patch}
        #   popd
        # '';

        # sourceRoot = "${finalAttrs.src.name}/llvm";
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
            # Might need to be propagated
            llvmFinal.opencl-aot
            llvmFinal.llvm
            llvmFinal.clang
            llvmFinal.clang.cc.dev
            # overrides.vc-intrinsics
            (zstd.override {enableStatic = true;})
            zlib

            emhash
          ]
          ++ (lib.optional (rocmSupport || cudaSupport) llvmFinal.libclc)
          ++ (lib.optional rocmSupport llvmFinal.lld)
          ++ unified-runtime'.buildInputs;

        # preBuild = ''
        #   ${tree}/bin/tree
        #   echo ----
        #   ${tree}/bin/tree tools
        # '';
        #
        # preConfigure = ''
        #   chmod u+w .
        #   mkdir -p build/include-build-dir
        # '';

        cmakeFlags =
          [
            # Used to find unified-runtime folder (`LLVM_SOURCE_DIR/../unified-runtime`)
            "-DLLVM_SOURCE_DIR=/build/${finalAttrs.src.name}/llvm"
            # "-DUR_INTREE_SOURCE_DIR=/build/${finalAttrs.src.name}/unified-runtime"
            # "-DSYCL_INCLUDE_BUILD_DIR=/build/${finalAttrs.src.name}/build/include-build-dir"

            (lib.cmakeFeature "LLVM_EXTERNAL_LIT" "${lit}/bin/lit")

            # "-DLLVM_ENABLE_PROJECTS=sycl;opencl;xpti;xptifw;sycl-jit;libclc"
            # "-DLLVM_ENABLE_PROJECTS=sycl;sycl-jit"

            # "-DLLVM_EXTERNAL_PROJECTS=sycl;xpti;xptifw;sycl-jit"
            "-DLLVM_EXTERNAL_XPTI_SOURCE_DIR=/build/${finalAttrs.src.name}/xpti"
            "-DLLVM_EXTERNAL_XPTIFW_SOURCE_DIR=/build/${finalAttrs.src.name}/xptifw"
            "-DLLVM_EXTERNAL_SYCL_JIT_SOURCE_DIR=/build/${finalAttrs.src.name}/sycl-jit"

            # "-DLLVM_USE_STATIC_ZSTD=OFF"

            # TODO: Reenable!
            "-DSYCL_ENABLE_XPTI_TRACING=OFF"
            # "-DSYCL_ENABLE_BACKENDS=level_zero;level_zero_v2;cuda;hip"
            "-DSYCL_ENABLE_BACKENDS=${lib.strings.concatStringsSep ";" unified-runtime'.backends}"

            "-DLLVM_INCLUDE_TESTS=ON"
            "-DSYCL_INCLUDE_TESTS=ON"

            # "-DSYCL_ENABLE_WERROR=ON"

            # TODO: REENABLE!
            "-DSYCL_ENABLE_EXTENSION_JIT=OFF"
            # "-DSYCL_ENABLE_EXTENSION_JIT=ON"
            "-DSYCL_ENABLE_MAJOR_RELEASE_PREVIEW_LIB=ON"
            "-DSYCL_BUILD_PI_HIP_PLATFORM=AMD"

            (lib.cmakeFeature "SYCL_COMPILER_VERSION" date)

            (lib.cmakeBool "SYCL_UR_USE_FETCH_CONTENT" false)

            # # Lookup broken
            # (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_EMHASH" "${deps.emhash}")
          ]
          ++ unified-runtime'.cmakeFlags;
      });

      libdevice = stdenv.mkDerivation (
        finalAttrs: let
          tools = symlinkJoin {
            name = "libdevice-tools";
            paths = [
              llvmFinal.llvm
              llvmFinal.clang
              llvmFinal.clang-tools
            ];
            # # I think it wants unwrapped clang and wrapped clang++
            # # but I'm not sure yet. TODO
            postBuild = ''
              rm $out/bin/clang
              # ln -s ${llvmFinal.clang-unwrapped}/bin/clang $out/bin/clang
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
            # llvmFinal.clang
            # llvmFinal.clang-tools
            llvmFinal.sycl
          ];

          patches = [
            ./patches/libdevice.patch
            ./patches/libdevice-sycllibdevice.patch
          ];

          hardeningDisable = ["zerocallusedregs"];

          # NIX_CFLAGS_COMPILE = "-v";

          ninjaFlags = ["-v"];

          # preBuild = ''
          #   type buildPhase
          # '';
          # preBuild = ''
          #   type buildPhase
          # '';

          cmakeFlags = [
            (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
            "-DLLVM_TOOLS_DIR=${llvmFinal.llvm}/bin"
            "-DCLANG_TOOLS_DIR=${llvmFinal.clang-tools}/bin"
            # (lib.cmakeFeature "CMAKE_C_COMPILER" "${stdenv.cc}/bin/clang")
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

        nativeBuildInputs = [
          cmake
          ninja
        ];

        # buildInputs = [ llvm ];

        # cmakeFlags = [
        #   "-DSYCL_ENABLE_WERROR=ON"
        #   "-DSYCL_ENABLE_EXTENSION_JIT=ON"
        #   "-DSYCL_ENABLE_MAJOR_RELEASE_PREVIEW_LIB=ON"
        #   "-DSYCL_ENABLE_WERROR=ON"
        #   "-DSYCL_BUILD_PI_HIP_PLATFORM=AMD"
        # ];
      });

      libclang =
        (llvmPrev.libclang.override {
          buildLlvmTools = llvmFinal.buildLlvmTools;
          # tblgen = llvmFinal.tblgen;
        }).overrideAttrs
        (old: {
          buildInputs =
            (old.buildInputs or [])
            ++ [
              zstd
              zlib
              libedit
              # overrides.llvm.dev
            ];

          postPatch =
            ''
              ${old.postPatch or ""}

              substituteInPlace lib/Driver/CMakeLists.txt \
                  --replace-fail "DeviceConfigFile" ""

            ''
            + (lib.optionalString false ''
              # The findProgram calls in this file are often split across multiple lines.
              # Use sed to join them into a single line so that substituteInPlace can match them.
              # This handles cases where the line break is after '=' or after '('.
              sed -i \
                  -e '/Expected<std::string>.*=$/{N;s/\n\s*//}' \
                  -e '/findProgram($/{N;s/\n\s*//}' \
                  tools/clang-linker-wrapper/ClangLinkerWrapper.cpp

              # We want to use a shell-expansion here, as the name contains a version number (e.g., ocloc-25.31.1).
              OCLOC="${intel-compute-runtime}/bin/ocloc-*"
              # TODO: clang-offload-bundler will not be wrapper properly

              substituteInPlace tools/clang-linker-wrapper/ClangLinkerWrapper.cpp \
                  --replace-fail 'findProgram("llvm-objcopy", {getMainExecutable("llvm-objcopy")})' '"${llvmFinal.llvm}/bin/llvm-objcopy"' \
                  --replace-fail 'findProgram("clang-offload-bundler", {getMainExecutable("clang-offload-bundler")})' '"$out/bin/clang-offload-bundler"' \
                  --replace-fail 'findProgram("spirv-to-ir-wrapper", {getMainExecutable("spirv-to-ir-wrapper")})' '"${llvmFinal.llvm}/bin/spirv-to-ir-wrapper"' \
                  --replace-fail 'findProgram("sycl-post-link", {getMainExecutable("sycl-post-link")})' '"${llvmFinal.llvm}/bin/sycl-post-link"' \
                  --replace-fail 'findProgram("llvm-spirv", {getMainExecutable("llvm-spirv")})' '"${llvmFinal.llvm}/bin/llvm-spirv"' \
                  --replace-fail 'findProgram("opencl-aot", {getMainExecutable("opencl-aot")})' '"${llvmFinal.opencl-aot}/bin/opencl-aot"' \
                  --replace-fail 'findProgram("ocloc", {getMainExecutable("ocloc")})' '"$OCLOC"' \
                  --replace-fail 'findProgram("clang", {getMainExecutable("clang")})' '"$out/bin/clang"' \
                  --replace-fail 'findProgram("llvm-link", {getMainExecutable("llvm-link")})' '"${llvmFinal.llvm}/bin/llvm-link"'

              # Apply the same pattern to the second file, which has a slightly different
              # function signature for findProgram.
              sed -i \
                  -e '/Expected<std::string>.*=$/{N;s/\n\s*//}' \
                  tools/clang-sycl-linker/ClangSYCLLinker.cpp

              substituteInPlace tools/clang-sycl-linker/ClangSYCLLinker.cpp \
                  --replace-fail 'findProgram(Args, "opencl-aot", {getMainExecutable("opencl-aot")})' '"${llvmFinal.opencl-aot}/bin/opencl-aot"' \
                  --replace-fail 'findProgram(Args, "ocloc", {getMainExecutable("ocloc")})' '"$OCLOC"'

              # # After replacing the calls that use it, the getMainExecutable function
              # # in this file is no longer needed. Remove it to prevent compiler warnings
              # # or errors about unused functions.
              # sed -i '/^std::string getMainExecutable(const char \*Name) {/,/}/d' \
              #   clang/tools/clang-sycl-linker/ClangSYCLLinker.cpp
            '');

          # cmakeFlags =
          #   (old.cmakeFlags or [])
          #   ++ [
          #     (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
          #     (lib.cmakeBool "FETCHCONTENT_QUIET" false)

          #     (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_VC-INTRINSICS" "${deps.vc-intrinsics}")
          #   ];
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

        # TODO
        cmakeFlags = [
          # # Lookup broken
          # (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_EMHASH" "${deps.emhash}")
          # # Lookup not implemented
          # (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_PARALLEL-HASHMAP" "${parallel-hashmap.src}")

          (lib.cmakeBool "XPTI_ENABLE_WERROR" true)
        ];
      });
    }
  )
