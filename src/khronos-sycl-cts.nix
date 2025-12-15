{
  lib,
  fetchFromGitHub,
  intel-llvm,
  ccacheIntelStdenv,
  python3,
  cmake,
  opencl-headers,
  ocl-icd,
  ninja,
  procps,
  rocmPackages ? {},
  target ? "amd",
}: let
  stdenv = intel-llvm.stdenv;
  # stdenv = ccacheIntelStdenv;
in
  stdenv.mkDerivation (finalAttrs: {
    pname = "khronos-sycl-cts";
    version = "unstable-2025-09-19";

    src = fetchFromGitHub {
      owner = "KhronosGroup";
      repo = "SYCL-CTS";
      rev = "71ebbc15e07310d8ae4b0db7cfb871d9a7207c82";
      hash = "sha256-AqkFglhuOGhSY7jRb1ufOvQLIggKpj6j9LweEif5Rec=";
      fetchSubmodules = true;
    };

    nativeBuildInputs = [
      python3
      cmake
      ninja
    ];

    buildInputs = [
      opencl-headers
      ocl-icd
    ];

    # hardeningDisable = [
    #   "zerocallusedregs"
    #   "pacret"
    #   # "shadowstack"
    # ];

    hardeningDisable = ["all"];

    cmakeFlags =
      [
        # TODO: Make parameter
        (lib.cmakeFeature "SYCL_IMPLEMENTATION" "DPCPP")
        (lib.cmakeFeature "SYCL_CTS_EXCLUDE_TEST_CATEGORIES" "/build/disabled_categories")
      ]
      ++ lib.optional (target == "amd") (lib.cmakeFeature "DPCPP_TARGET_TRIPLES" "amdgcn-amd-amdhsa");

    # We need to set this via the shell because it contains spaces
    preConfigure =
      ''
        touch /build/disabled_categories
      ''
      + (lib.optionalString (target == "amd") ''
        cmakeFlagsArray+=(
          "-DDPCPP_FLAGS=-Xsycl-target-backend=amdgcn-amd-amdhsa;--offload-arch=gfx1030;--rocm-path=${rocmPackages.clr};--rocm-device-lib-path=${rocmPackages.rocm-device-libs}/amdgcn/bitcode"
        )

        cat << EOF > /build/disabled_categories
        atomic_ref
        EOF
        # echo /build/disabled_categories
        # exit 1
      '');

    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin
      cp -r bin/* $out/bin

      runHook postInstall
    '';

    passthru = {
      generate_exclude_filter = finalAttrs.finalPackage.overrideAttrs (old: {
        nativeBuildInputs = old.nativeBuildInputs ++ [procps];
        buildPhase = ''
          runHook preBuild

          #cd /build/${finalAttrs.src.name}
          cd ..
          mkdir $out
          python ci/generate_exclude_filter.py --cmake-args "$cmakeFlags" --output $out/generated.filter --verbose DPCPP

          runHook postBuild
        '';

        #dontConfigure = true;
        dontInstall = true;
      });
    };
  })
