{
  kit,
  stdenvNoCC,
  stdenv,
  overrideCC,
  wrapCCWith,
  symlinkJoin,
  callPackage,
}: let
  intelBin = "${kit}/compiler/latest/bin";

  unwrappedCC = stdenvNoCC.mkDerivation {
    name = "intel-oneapi-cc-unwrapped";
    dontUnpack = true;
    installPhase = ''
      mkdir -p $out/bin
      ln -s ${intelBin}/icpx $out/bin/clang++
      ln -s ${intelBin}/icx  $out/bin/clang
      ln -s ${intelBin}/icx  $out/bin/cc
    '';
    passthru.isClang = true;
    # icpx rejects these flags for the SPIR-V device target (spir64-unknown-unknown).
    # Declaring them unsupported here suppresses them globally for all derivations
    # built with this stdenv, so per-derivation hardeningDisable is not needed.
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

  intelStdenv = overrideCC stdenv final;

  final = symlinkJoin {
    name = kit.name;
    paths = [kit wrappedCC];

    postBuild = ''
      (
        # The nixpkgs kit creates $out/bin as a symlink to 2025.x/bin,
        # which means we can't write into the directory.
        # To side step this, we convert it to a real directory with per-file symlinks.
        binTarget=$(readlink -f "$out/bin")
        rm "$out/bin"
        mkdir "$out/bin"
        for f in "$binTarget"/*; do
          ln -s "$f" "$out/bin/$(basename "$f")"
        done

        # Now add the cc-wrapper binaries (clang++, clang, cc, icpx, icx, …).
        for f in ${wrappedCC}/bin/*; do
          name=$(basename "$f")
          [ -e "$out/bin/$name" ] || ln -s "$f" "$out/bin/$name"
        done

        mkdir -p $out/nix-support
        hook="$out/nix-support/setup-hook"
        # Dereference any symlink so we can append (store files are read-only).
        if [ -L "$hook" ]; then
          t=$(mktemp)
          cat "$hook" > "$t"
          rm "$hook"
          mv "$t" "$hook"
        fi
        echo "export ONEAPI_ROOT=\"${kit}\"" >> "$hook"
        # Override CXX/CC to use icpx/icx names. The cc-wrapper sets them to
        # clang++/clang, but oneDNN (and other Intel cmake packages) check
        # CMAKE_BASE_NAME and reject clang++ from an Intel LLVM compiler.
        echo "export CXX=\"${wrappedCC}/bin/icpx\"" >> "$hook"
        echo "export CC=\"${wrappedCC}/bin/icx\"" >> "$hook"
        for comproot in ${kit}/*/latest; do
          [ -d "$comproot/lib/cmake" ] && echo "addToSearchPath CMAKE_PREFIX_PATH \"$comproot\"" >> "$hook" || true
          [ -d "$comproot/lib/pkgconfig" ] && echo "addToSearchPath PKG_CONFIG_PATH \"$comproot/lib/pkgconfig\"" >> "$hook" || true
          [ -d "$comproot/lib" ] && echo "addToSearchPath LIBRARY_PATH \"$comproot/lib\"" >> "$hook" || true
        done
      )
    '';

    passthru =
      kit.passthru
      // {
        cc = wrappedCC;
        unwrapped = kit;
        stdenv = intelStdenv;
        tests = callPackage ./tests.nix {stdenv = intelStdenv;};
      };
  };
in
  final
