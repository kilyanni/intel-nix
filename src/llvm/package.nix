{
  callPackage,
  newScope,
  wrapCCWith,
  symlinkJoin,
  overrideCC,
  lib,
  fetchFromGitHub,
  writeShellApplication,
  nix-update,
  nix-prefetch-github,
  curl,
  jq,
  onedpl,
}:
let
  # This derivation uses makeScope to help with overriding.
  #
  # To override the source and other basics:
  #  pkgs.intel-llvm.overrideScope (final: prev: {
  #    version = ..;
  #    src = ..;
  #    # If setting src, you'll probably also want to set this.
  #    commitDate = ..;
  #  })
  #
  # To override something inside unified-runtime:
  #  pkgs.intel-llvm.overrideScope (final: prev: {
  #    make-unified-runtime = args: (prev.make-unified-runtime args)
  #      .override { .. }
  #      .overrideAttrs { .. }
  #  })
  #
  # Note that this package does not support cross-compilation at the moment.
  #
  # TODO: Support cross
  #  The easiest path for this will likely be to use standalone packaging,
  #  and use the existing LLVM derivation with overrides. Though that won't
  #  be very workable until upstream support for standalone improves,
  #  see https://github.com/intel/llvm/issues/21877 for that.
  #
  #  Due to the multi-stage build, at several times during compilation
  #  the package runs binaries that were just compiled, and for cross these
  #  would need to be compiled for the host and not target platform,
  #  which is non-trivial to configure.
  scope = lib.makeScope newScope (self: {
    # == Parameters for overriding ==

    llvmMajorVersion = "22";

    version = "7.0.0";

    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      tag = "v${self.version}";
      hash = "sha256-l4InHzR/W6Gihoxt9CjEREyB9LDIDQggskzFIPIS2bA=";
    };

    # The commit date of the release tag above, kept in sync by `updateScript`.
    # If you override src, you'll probably also want to override this,
    # as some packages check for this date to decide what features the compiler supports.
    commitDate = "20260713";

    vc-intrinsics-src = fetchFromGitHub {
      owner = "intel";
      repo = "vc-intrinsics";
      # See LLVMGenXIntrinsics_GIT_TAG in llvm/lib/SYCLLowerIR/CMakeLists.txt
      rev = "60cea7590bd022d95f5cf336ee765033bd114d69";
      sha256 = "sha256-1K16UEa6DHoP2ukSx58OXJdtDWyUyHkq5Gd2DUj1644=";
    };

    # ===============================

    make-unified-runtime =
      {
        levelZeroSupport,
        cudaSupport,
        rocmSupport,
        rocmGpuTargets,
        nativeCpuSupport,
      }:
      callPackage ./unified-runtime.nix {
        intel-llvm-src = self.src;
        inherit
          levelZeroSupport
          cudaSupport
          rocmSupport
          rocmGpuTargets
          nativeCpuSupport
          ;
        # This could theoretically be disabled if you for some reason
        # didn't want to build the backend, however OpenCL will get
        # pulled in as a dependency either way so there is little point.
        openclSupport = true;
      };

    unwrapped = callPackage ./unwrapped.nix {
      inherit (self)
        llvmMajorVersion
        src
        version
        commitDate
        vc-intrinsics-src
        make-unified-runtime
        ;
    };

    wrapper = wrapCCWith {
      cc = self.unwrapped;
      # This is needed for tools like clang-scan-deps to find headers.
      # The build commands here are the same as the vanilla LLVM derivation.
      extraBuildCommands = ''
        rsrc="$out/resource-root"
        mkdir "$rsrc"
        echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
        ln -s "${lib.getLib self.unwrapped}/lib/clang/${self.llvmMajorVersion}/include" "$rsrc"
        ln -s "${lib.getLib self.unwrapped}/lib/clang/${self.llvmMajorVersion}/lib" "$rsrc"
      ''
      + (lib.concatStrings (
        lib.mapAttrsToList (k: v: ''
          echo "export ${k}=${v}" >> $out/nix-support/setup-hook
        '') self.unwrapped.unified-runtime.setupVars
      ))

      + (lib.optionalString (self.unwrapped.unified-runtime.setupVars ? CUDA_PATH) ''
        # SYCL CUDA runtime libs (e.g. libonemath_blas_cublas.so) carry DT_NEEDED: libcuda.so.1.
        # GNU ld resolves transitive DT_NEEDED via -rpath-link, not -L; point it at the stubs.
        echo "-rpath-link,${self.unwrapped.unified-runtime.setupVars.CUDA_PATH}/lib/stubs" >> $out/nix-support/cc-ldflags
        # The SYCL CUDA backend discovers libdevice by finding ptxas in PATH.
        echo "export PATH=${self.unwrapped.unified-runtime.setupVars.CUDA_PATH}/bin''${PATH:+:$PATH}" >> $out/nix-support/setup-hook
      '');

      extraPackages =
        # We need to explicitly link to the dev package to get headers like sycl.hpp
        [ self.unwrapped.dev ] # TODO: This needs to be from targetPackages once the package gets cross support
        # OpenCL and such need to be passed through
        ++ self.unwrapped.propagatedBuildInputs;
    };

    clang-tools-wrapper = callPackage ./clang-tools.nix {
      inherit (self) unwrapped wrapper;
    };

    # We merge everything into one by default to avoid issues with path-lookup.
    # intel-llvm provides the SYCL library, so unlike regular LLVM libraries,
    # its libraries are equally important as the compiler itself.
    # Splitting is nonetheless important, as otherwise the binaries go over the Hydra limit.
    merged = symlinkJoin {
      inherit (self.unwrapped) pname version meta;

      strictDeps = true;
      __structuredAttrs = true;

      paths = with self; [
        # Order is important, we want files from the wrappers to take precedence
        wrapper
        clang-tools-wrapper

        unwrapped.out
        unwrapped.dev
        unwrapped.lib
      ];

      passthru = self.unwrapped.passthru // {
        inherit (self) stdenv;
        unwrapped = self.unwrapped;

        updateScript = lib.getExe (writeShellApplication {
          name = "update-intel-llvm";
          runtimeInputs = [
            nix-update
            nix-prefetch-github
            curl
            jq
          ];
          text = ''
            nixFile=pkgs/by-name/in/intel-llvm/package.nix

            nix-update intel-llvm.unwrapped --override-filename "$nixFile"

            # `commitDate` has to move with the version, or the bump silently
            # keeps claiming the feature set of the previous release. It is not
            # derivable from the tarball, as fetchFromGitHub drops `.git`.
            version=$(sed -n 's/^ *version = "\(.*\)";$/\1/p' "$nixFile")
            [ -n "$version" ] || { echo "failed to read back version" >&2; exit 1; }

            commitDate=$(
              curl -sSf "https://api.github.com/repos/intel/llvm/commits/v$version" \
                | jq -r .commit.committer.date | cut -dT -f1 | tr -d -
            )

            sed -i "s/commitDate = \"[0-9]*\"/commitDate = \"$commitDate\"/" "$nixFile"
            grep -q "commitDate = \"$commitDate\";" "$nixFile" ||
              { echo "failed to update commitDate to $commitDate" >&2; exit 1; }

            vcRev=$(
              curl -sSf "https://raw.githubusercontent.com/intel/llvm/v$version/llvm/lib/SYCLLowerIR/CMakeLists.txt" \
                | sed -n 's/^ *set(LLVMGenXIntrinsics_GIT_TAG \([^ )]*\)).*/\1/p'
            )
            [ -n "$vcRev" ] || { echo "failed to extract LLVMGenXIntrinsics_GIT_TAG" >&2; exit 1; }

            if ! grep -q "rev = \"$vcRev\";" "$nixFile"; then
              vcHash=$(nix-prefetch-github intel vc-intrinsics --rev "$vcRev" | jq -r .hash)
              sed -i \
                -e "s|rev = \"[^\"]*\";|rev = \"$vcRev\";|" \
                -e "s|sha256 = \"[^\"]*\";|sha256 = \"$vcHash\";|" \
                "$nixFile"
              if ! grep -q "rev = \"$vcRev\";" "$nixFile" || ! grep -q "sha256 = \"$vcHash\";" "$nixFile"; then
                echo "failed to update vc-intrinsics-src" >&2
                exit 1
              fi
            fi
          '';
        });

        tests =
          callPackage ./tests.nix {
            inherit (self) stdenv;
            inherit (self.unwrapped.unified-runtime) backends;
          }
          // {
            inherit onedpl;
          };

        overrideScope = newF: (self.overrideScope newF).merged;
      };
    };
    stdenv = overrideCC self.unwrapped.baseLlvm.stdenv self.merged;
  });
in
scope.merged
