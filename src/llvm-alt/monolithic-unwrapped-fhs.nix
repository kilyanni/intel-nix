{
  lib,
  stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  python3,
  pkg-config,
  zstd,
  hwloc,
  valgrind,
  buildFHSEnv,
  unified-runtime,
  emhash,
  sphinx,
  doxygen,
  level-zero,
  libxml2,
  libedit,
  llvmPackages_21,
  callPackage,
  parallel-hashmap,
  spirv-headers,
  spirv-tools,
  fetchpatch,
  perl,
  zlib,
  ccacheStdenv,
  tree,
  rocmPackages ? {},
  cudaPackages ? {},
  levelZeroSupport ? true,
  openclSupport ? true,
  cudaSupport ? false,
  rocmSupport ? true,
  rocmGpuTargets ? builtins.concatStringsSep ";" rocmPackages.clr.gpuTargets,
  nativeCpuSupport ? false,
  vulkanSupport ? true,
  useLibcxx ? false,
  useLld ? true,
  buildTests ? true,
  buildDocs ? false,
  buildMan ? false,
}: let
  version = "unstable-2025-10-09";
  date = "20251009";

  llvmPackages = llvmPackages_21;
  stdenv = ccacheStdenv;
  deps = callPackage ./deps.nix {};

  unified-runtime' = unified-runtime.override {
    inherit
      levelZeroSupport
      openclSupport
      cudaSupport
      rocmSupport
      rocmGpuTargets
      nativeCpuSupport
      vulkanSupport
      buildTests
      ;
  };

  # FHS environment provides /usr/lib, /usr/include etc so the build can find system libs
  fhsEnv = buildFHSEnv {
    name = "intel-llvm-build-env";
    targetPkgs = pkgs: (
      with pkgs;
        [
          cmake
          ninja
          python3
          pkg-config
          perl
          tree
          stdenv.cc
          stdenv.cc.cc
          stdenv.cc.cc.lib
          zlib
          zstd
          hwloc
          valgrind.dev
          libxml2
          libedit
          level-zero
          spirv-tools
          sphinx
          doxygen
          emhash
          parallel-hashmap
        ]
        ++ lib.optionals useLld [llvmPackages.bintools]
        ++ unified-runtime'.buildInputs
    );
  };
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "intel-llvm";
    inherit version;

    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      rev = "a963e89b61345c8db16aa4cc2dd339d09ccf0638";
      hash = "sha256-OhGnQ4uKd6q8smB0ue+k+dVzQpBwapWvfrzOFFfBOic=";
    };

    outputs = [
      "out"
      "lib"
      "dev"
      "python"
    ];

    nativeBuildInputs =
      [
        cmake
        ninja
        python3
        pkg-config
        zlib
        zstd
      ]
      ++ lib.optionals useLld [llvmPackages.bintools]
      ++ lib.optionals buildTests [perl];

    buildInputs =
      [
        sphinx
        doxygen
        spirv-tools
        libxml2
        valgrind.dev
        hwloc
        emhash
        parallel-hashmap
      ]
      ++ unified-runtime'.buildInputs;

    propagatedBuildInputs = [
      zstd
      zlib
      libedit
    ];

    cmakeBuildType = "Release";

    patches = [./gnu-install-dirs.patch];

    postPatch = ''
      # No longer need ccWrapperStub - just use the compiler directly
      substituteInPlace libdevice/cmake/modules/SYCLLibdevice.cmake \
        --replace-fail "\''${clang_exe}" "\''${CMAKE_BINARY_DIR}/bin/clang++"

      sed -i '/file(COPY / { /NO_SOURCE_PERMISSIONS/! s/)\s*$/ NO_SOURCE_PERMISSIONS)/ }' \
        unified-runtime/cmake/FetchLevelZero.cmake \
        sycl/CMakeLists.txt \
        sycl/cmake/modules/FetchEmhash.cmake

      substituteInPlace unified-runtime/cmake/FetchOpenCL.cmake \
        --replace-fail "NO_CMAKE_PACKAGE_REGISTRY" ""

      ${lib.optionalString buildTests ''patchShebangs clang/tools/scan-build/libexec/''}
    '';

    # Wrap the standard phases in FHS environment
    preConfigure = ''
      flags=$(python buildbot/configure.py \
          --print-cmake-flags -t Release --docs --cmake-gen Ninja \
          ${lib.optionalString cudaSupport "--cuda"} \
          ${lib.optionalString rocmSupport "--hip"} \
          ${lib.optionalString nativeCpuSupport "--native_cpu"} \
          ${lib.optionalString useLibcxx "--use-libcxx"} \
          ${lib.optionalString useLld "--use-lld"} \
          ${lib.optionalString levelZeroSupport "--level_zero_adapter_version V1"} \
          ${lib.optionalString levelZeroSupport "--l0-headers ${lib.getInclude level-zero}/include/level_zero"} \
          ${lib.optionalString levelZeroSupport "--l0-loader ${lib.getLib level-zero}/lib/libze_loader.so"} \
          --disable-jit)
      eval "prependToVar cmakeFlags $flags"
      cmakeFlags=(''${cmakeFlags[@]/-DCMAKE_INSTALL_PREFIX=\/build\/source\/build\/install})

      # Export for use in FHS environment
      export CMAKE_FLAGS="''${cmakeFlags[@]}"
    '';

    configurePhase = ''
      runHook preConfigure

      mkdir -p build
      cd build

      ${fhsEnv}/bin/intel-llvm-build-env cmake \
        /build/source/llvm \
        "''${cmakeFlags[@]}"

      runHook postConfigure
    '';

    buildPhase = ''
      runHook preBuild

      cd build
      ${fhsEnv}/bin/intel-llvm-build-env ninja -j''${NIX_BUILD_CORES:-1}

      runHook postBuild
    '';

    checkPhase = lib.optionalString buildTests ''
      runHook preCheck

      cd build
      ${fhsEnv}/bin/intel-llvm-build-env ninja check-all

      runHook postCheck
    '';

    installPhase = ''
      runHook preInstall

      cd build
      ${fhsEnv}/bin/intel-llvm-build-env ninja install

      runHook postInstall
    '';

    cmakeDir = "/build/source/llvm";

    cmakeFlags =
      [
        (lib.cmakeBool "LLVM_INSTALL_UTILS" true)
        (lib.cmakeBool "LLVM_INCLUDE_DOCS" (buildDocs || buildMan))
        (lib.cmakeBool "MLIR_INCLUDE_DOCS" (buildDocs || buildMan))
        (lib.cmakeBool "LLVM_BUILD_DOCS" (buildDocs || buildMan))
        (lib.cmakeBool "LLVM_ENABLE_SPHINX" (buildDocs || buildMan))
        (lib.cmakeBool "SPHINX_OUTPUT_HTML" buildDocs)
        (lib.cmakeBool "SPHINX_OUTPUT_MAN" buildMan)
        (lib.cmakeBool "LLVM_BUILD_TESTS" buildTests)
        (lib.cmakeBool "LLVM_INCLUDE_TESTS" buildTests)
        (lib.cmakeBool "MLIR_INCLUDE_TESTS" buildTests)
        (lib.cmakeBool "SYCL_INCLUDE_TESTS" buildTests)
        "-DLLVM_ENABLE_ZLIB=FORCE_ON"
        "-DLLVM_ENABLE_THREADS=ON"
        "-DLLVM_USE_STATIC_ZSTD=OFF"
        (lib.cmakeBool "BUILD_SHARED_LIBS" false)
        (lib.cmakeBool "LLVM_LINK_LLVM_DYLIB" false)
        (lib.cmakeBool "LLVM_BUILD_LLVM_DYLIB" false)
        (lib.cmakeFeature "SYCL_COMPILER_VERSION" date)
        (lib.cmakeBool "FETCHCONTENT_FULLY_DISCONNECTED" true)
        (lib.cmakeBool "FETCHCONTENT_QUIET" false)
        (lib.cmakeFeature "FETCHCONTENT_SOURCE_DIR_VC-INTRINSICS" "${deps.vc-intrinsics}")
        (lib.cmakeFeature "LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR" "${spirv-headers.src}")
        "-DCLANG_RESOURCE_DIR=lib/clang/21"
        (lib.cmakeFeature "LLVM_INSTALL_PACKAGE_DIR" "${placeholder "dev"}/lib/cmake/llvm")
      ]
      ++ unified-runtime'.cmakeFlags;

    hardeningDisable = ["zerocallusedregs"];
    NIX_LDFLAGS = "-lhwloc";
    requiredSystemFeatures = ["big-parallel"];
    enableParallelBuilding = true;

    postBuild = ''
      echo "=== Build directory structure ==="
      ${tree}/bin/tree -L 2 -d "$PWD" || find "$PWD" -maxdepth 2 -type d
    '';

    doCheck = buildTests;

    postInstall = ''
      mkdir -p $python/share
      mv $out/share/opt-viewer $python/share/opt-viewer
      moveToOutput "bin/llvm-config*" "$dev"
      substituteInPlace "$dev/lib/cmake/llvm/LLVMExports-${lib.toLower finalAttrs.finalPackage.cmakeBuildType}.cmake" \
        --replace-fail "$out/bin/llvm-config" "$dev/bin/llvm-config"
      substituteInPlace "$dev/lib/cmake/llvm/LLVMConfig.cmake" \
        --replace-fail 'set(LLVM_BINARY_DIR "''${LLVM_INSTALL_PREFIX}")' 'set(LLVM_BINARY_DIR "'"$lib"'")'
    '';

    meta = with lib; {
      description = "Intel LLVM-based compiler with SYCL support (FHS build)";
      homepage = "https://github.com/intel/llvm";
      license = with licenses; [
        ncsa
        asl20
        llvm-exception
      ];
      maintainers = with maintainers; [blenderfreaky];
      platforms = platforms.linux;
    };

    passthru = {
      isClang = true;
      baseLlvm = llvmPackages_21;
    };
  })
