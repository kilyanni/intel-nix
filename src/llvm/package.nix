{
  callPackage,
  newScope,
  wrapCCWith,
  symlinkJoin,
  overrideCC,
  lib,
  fetchFromGitHub,
  # for faster local rebuilds
  ccacheStdenv,
  stdenv,
  useCcache ? true,
}: let
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
  scope = lib.makeScope newScope (self: {
    # == Parameters for overriding ==

    llvmMajorVersion = "22";

    version = "unstable-2026-02-24";

    src = fetchFromGitHub {
      owner = "intel";
      repo = "llvm";
      rev = "186cbd82259adde987b3e614708c7a91401d7652";
      hash = "sha256-0ySX7G2OE0WixbgO3/IlaQn6YYa8wCGjR1xq3ylbR/U=";
    };

    # If you override src, you'll probably also want to override this,
    # as some packages check for this date to decide what features the compiler supports
    commitDate = "20260224";

    vc-intrinsics-src = fetchFromGitHub {
      owner = "intel";
      repo = "vc-intrinsics";
      # See llvm/lib/SYCLLowerIR/CMakeLists.txt:17
      rev = "60cea7590bd022d95f5cf336ee765033bd114d69";
      sha256 = "sha256-1K16UEa6DHoP2ukSx58OXJdtDWyUyHkq5Gd2DUj1644=";
    };

    inherit useCcache;
    buildStdenv =
      if useCcache
      then ccacheStdenv
      else stdenv;

    # ===============================

    make-unified-runtime = {
      levelZeroSupport,
      cudaSupport,
      rocmSupport,
      rocmGpuTargets,
      nativeCpuSupport,
      rocmPackages ? {},
      cudaPackages ? {},
    }:
      callPackage ./unified-runtime.nix {
        intel-llvm-src = self.src;
        inherit (self) buildStdenv;
        inherit
          levelZeroSupport
          cudaSupport
          rocmSupport
          rocmGpuTargets
          nativeCpuSupport
          rocmPackages
          cudaPackages
          ;
        # This could theoretically be disabled if you for some reason
        # didn't want to build the backend, however OpenCL will get
        # pulled in as a dependency either way so there is little point.
        openclSupport = true;
      };

    unwrapped = callPackage ./unwrapped.nix {
      inherit
        (self)
        llvmMajorVersion
        src
        version
        commitDate
        vc-intrinsics-src
        make-unified-runtime
        buildStdenv
        ;
    };

    wrapper =
      (wrapCCWith {
        cc = self.unwrapped;
        # This is needed for tools like clang-scan-deps to find headers.
        # The build commands here are the same as the vanilla LLVM derivation.
        extraBuildCommands = ''
          rsrc="$out/resource-root"
          mkdir "$rsrc"
          echo "-resource-dir=$rsrc" >> $out/nix-support/cc-cflags
          ln -s "${lib.getLib self.unwrapped}/lib/clang/${self.llvmMajorVersion}/include" "$rsrc"
          ${lib.concatStrings (lib.mapAttrsToList (k: v: ''
              echo "export ${k}=${v}" >> $out/nix-support/setup-hook
            '')
            self.unwrapped.unified-runtime.setupVars)}
        '';
      }).overrideAttrs
      (old: {
        # OpenCL needs to be passed through
        propagatedBuildInputs = old.propagatedBuildInputs ++ self.unwrapped.propagatedBuildInputs;
      });

    clang-tools-wrapper = callPackage ./clang-tools.nix {
      inherit (self) unwrapped wrapper;
    };

    # We merge everything into one by default to avoid issues with path-lookup.
    # intel-llvm provides the SYCL library, so unlike regular LLVM libraries,
    # its libraries are equally important as the compiler itself.
    # Splitting is nonetheless important, as otherwise the binaries go over the Hydra limit.
    merged = symlinkJoin {
      inherit (self.unwrapped) pname version meta;

      paths = with self; [
        # Order is important, we want files from the wrappers to take precedence
        wrapper
        clang-tools-wrapper

        unwrapped.out
        unwrapped.dev
        unwrapped.lib
      ];

      passthru =
        self.unwrapped.passthru
        // {
          inherit (self) stdenv;
          unwrapped = self.unwrapped;
          tests = callPackage ./tests.nix {inherit (self) stdenv;};

          overrideScope = newF: (self.overrideScope newF).merged;

          # cc and override are required for stdenv adapters like ccacheStdenv.
          # nixpkgs' useCcache does cc.override { cc = ccache.links { cc = cc.cc; }; },
          # so merged must look like a cc-wrapper to it.
          cc = self.unwrapped;
          override = args:
            (self.overrideScope (f: p: {
              # When overriding cc (e.g. ccacheWrapper replaces cc with ccache.links),
              # ccache.links does not forward hardeningUnsupportedFlags from the unwrapped
              # compiler. Without this, zerocallusedregs would re-enter defaultHardeningFlags
              # in the rebuilt cc-wrapper and break downstream spir64 compilations.
              wrapper = p.wrapper.override (
                if args ? cc
                then args // {cc = args.cc // {hardeningUnsupportedFlags = self.unwrapped.hardeningUnsupportedFlags or [];};}
                else args
              );
            })).merged;
        };
    };
    stdenv = overrideCC self.unwrapped.baseLlvm.stdenv self.merged;
  });
in
  scope.merged
