{
  kit,
  stdenvNoCC,
  stdenv,
  overrideCC,
  wrapCCWith,
}: let
  intelBin = "${kit}/compiler/latest/bin";

  unwrappedCC = stdenvNoCC.mkDerivation {
    name = "intel-oneapi-cc-unwrapped";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      ln -s ${intelBin}/icpx $out/bin/clang++
      ln -s ${intelBin}/icx  $out/bin/clang
    '';
    passthru.isClang = true;
    # icpx rejects these flags for the SPIR-V device target (spir64-unknown-unknown).
    hardeningUnsupportedFlags = ["zerocallusedregs" "pacret" "shadowstack"];
  };

  # extraPackages propagates the full Intel toolkit (runtime, headers, libs)
  # into any stdenv built on this compiler.
  wrappedCC = wrapCCWith {
    cc = unwrappedCC;
    extraPackages = [kit];
    extraBuildCommands = ''
      # Consumers expect the icpx/icx names and might reject clang++/clang.
      ln -s $out/bin/clang++ $out/bin/icpx
      ln -s $out/bin/clang   $out/bin/icx

      echo "export CXX=\"$out/bin/icpx\"" >> $out/nix-support/setup-hook
      echo "export CC=\"$out/bin/icx\"" >> $out/nix-support/setup-hook

      echo "export ONEAPI_ROOT=\"${kit}\"" >> $out/nix-support/setup-hook

      # Add the compiler lib dir so -lsycl-devicelib-host is found at link time
      # (e.g. cmake's check_cxx_compiler_flag("-fsycl") which links with -fsycl).
      echo " -L${kit}/compiler/latest/lib" >> $out/nix-support/cc-ldflags

      # icpx omits -lstdc++ in link mode and for some reason looks up
      # /lib paths instead of wrapper-provided ones.
      # Inject via cc-wrapper-hook so it only fires for C++ link steps, not C.
      cat >> $out/nix-support/cc-wrapper-hook << 'EOF'
      if [[ "$isCxx" = 1 && "$dontLink" != 1 ]]; then extraAfter+=("-lstdc++"); fi
      EOF
    '';
  };

  intelStdenv = overrideCC stdenv wrappedCC;
  # final = symlinkJoin {
  #   name = "${kit.name}-wrapped";
  #   paths = [wrappedCC kit];
  #   postBuild = ''
  #     (
  #       mkdir -p $out/nix-support
  #       hook="$out/nix-support/setup-hook"
  #       # Materialize the symlinked setup hook so we can append
  #       cp --remove-destination "$(readlink -f "$hook")" "$hook"
  #       echo "export ONEAPI_ROOT=\"${kit}\"" >> "$hook"
  #       for componentRoot in ${kit}/*/latest; do
  #         [ -d "$componentRoot/lib/cmake" ] && echo "addToSearchPath CMAKE_PREFIX_PATH \"$componentRoot\"" >> "$hook" || true
  #         [ -d "$componentRoot/lib/pkgconfig" ] && echo "addToSearchPath PKG_CONFIG_PATH \"$componentRoot/lib/pkgconfig\"" >> "$hook" || true
  #         [ -d "$componentRoot/lib" ] && echo "addToSearchPath LIBRARY_PATH \"$componentRoot/lib\"" >> "$hook" || true
  #       done
  #     )
  #   '';
  #   passthru =
  #     kit.passthru
  #     // {
  #       cc = wrappedCC;
  #       unwrapped = kit;
  #       stdenv = intelStdenv;
  #       tests = callPackage ./tests.nix {stdenv = intelStdenv;};
  #     };
  # };
in
  intelStdenv
