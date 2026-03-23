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
      ln -s $out/bin/clang++ $out/bin/icpx
      ln -s $out/bin/clang   $out/bin/icx
      # Add the compiler lib dir so -lsycl-devicelib-host is found at link time
      # (e.g. cmake's check_cxx_compiler_flag("-fsycl") which links with -fsycl).
      echo " -L${kit}/compiler/latest/lib" >> $out/nix-support/cc-ldflags
      # icpx does not add -lstdc++ for pure link steps (only .o inputs, no source
      # files), and relies on /lib paths that don't exist in the nix sandbox.
      # Add it explicitly so C++ standard library symbols are always found.
      echo " -lstdc++" >> $out/nix-support/cc-ldflags
    '';
  };

  intelStdenv = overrideCC stdenv final;

  final = symlinkJoin {
    name = kit.name;
    paths = [kit wrappedCC];

    # Generate a setup hook mirroring what setvars.sh does: add each
    # component's `latest` directory to CMAKE_PREFIX_PATH, LIBRARY_PATH, and
    # PKG_CONFIG_PATH. We iterate over ${kit} (the real installer store path)
    # at postBuild time so paths are fully resolved — no version hardcoding,
    # and no reliance on ps or set -u-hostile vars.sh logic at build time.
    postBuild = ''
      # The nixpkgs kit creates $out/bin as a symlink → 2025.x/bin (a read-only
      # store path), so lndir can't add the cc-wrapper's clang++/clang/icpx/icx
      # into it. Convert it to a real directory with per-file symlinks first.
      if [ -L "$out/bin" ]; then
        _binTarget=$(readlink -f "$out/bin")
        rm "$out/bin"
        mkdir "$out/bin"
        for _f in "$_binTarget"/*; do
          ln -s "$_f" "$out/bin/$(basename "$_f")"
        done
      fi
      # Now add the cc-wrapper binaries (clang++, clang, cc, icpx, icx, …).
      for _f in ${wrappedCC}/bin/*; do
        _name=$(basename "$_f")
        [ -e "$out/bin/$_name" ] || ln -s "$_f" "$out/bin/$_name"
      done

      mkdir -p $out/nix-support
      _hook="$out/nix-support/setup-hook"
      # Dereference any symlink so we can append (store files are read-only).
      if [ -L "$_hook" ]; then
        _t=$(mktemp)
        cat "$_hook" > "$_t"
        rm "$_hook"
        mv "$_t" "$_hook"
      fi
      echo "export ONEAPI_ROOT=\"${kit}\"" >> "$_hook"
      # Override CXX/CC to use icpx/icx names. The cc-wrapper sets them to
      # clang++/clang, but oneDNN (and other Intel cmake packages) check
      # CMAKE_BASE_NAME and reject clang++ from an Intel LLVM compiler.
      echo "export CXX=\"${wrappedCC}/bin/icpx\"" >> "$_hook"
      echo "export CC=\"${wrappedCC}/bin/icx\"" >> "$_hook"
      for comproot in ${kit}/*/latest; do
        [ -d "$comproot/lib/cmake" ] && echo "addToSearchPath CMAKE_PREFIX_PATH \"$comproot\"" >> "$_hook" || true
        [ -d "$comproot/lib/pkgconfig" ] && echo "addToSearchPath PKG_CONFIG_PATH \"$comproot/lib/pkgconfig\"" >> "$_hook" || true
        [ -d "$comproot/lib" ] && echo "addToSearchPath LIBRARY_PATH \"$comproot/lib\"" >> "$_hook" || true
      done
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
