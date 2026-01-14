{
  kit,
  stdenvNoCC,
  wrapCC,
  symlinkJoin,
  makeWrapper,
}: let
  # Wrap the Intel compiler with nixpkgs cc-wrapper for proper nix integration
  wrappedCompiler = wrapCC (
    stdenvNoCC.mkDerivation {
      name = "intel-compiler";
      dontUnpack = true;
      installPhase = ''
        mkdir -p $out/bin
        cat > $out/bin/clang-22 <<'EOF'
        #!/bin/sh
        exec "$NIX_BUILD_TOP/source/build/bin/clang-22" "$@"
        EOF
        chmod +x $out/bin/clang-22
        cp $out/bin/clang-22 $out/bin/clang
        cp $out/bin/clang-22 $out/bin/clang++
      '';
      passthru.isClang = true;
    }
  );
in
  # Create a combined package with both the oneAPI toolkit and wrapped compilers
  symlinkJoin {
    name = "intel-oneapi-with-cc-wrapper";
    paths = [kit];

    nativeBuildInputs = [makeWrapper];

    postBuild = ''
      # Add the wrapped compiler to PATH while preserving Intel-specific compilers
      mkdir -p $out/nix-support

      # Expose the wrapped compiler for nixpkgs stdenv
      ln -sf ${wrappedCompiler}/nix-support/* $out/nix-support/ 2>/dev/null || true

      # Create wrapper scripts that preserve Intel compiler names but add nix integration
      INTEL_BIN_PATHS=(
        "$out/compiler/latest/bin"
        "$out/compiler/latest/linux/bin"
        "$out/compiler/latest/linux/bin/intel64"
        "$out/opt/intel/oneapi/compiler/latest/linux/bin"
        "$out/opt/intel/oneapi/compiler/latest/linux/bin/intel64"
      )

      for INTEL_BIN_DIR in "''${INTEL_BIN_PATHS[@]}"; do
        if [ -d "$INTEL_BIN_DIR" ]; then
          # Make directory writable for modifications
          chmod -R +w "$INTEL_BIN_DIR" 2>/dev/null || true

          # Wrap Intel compilers to use nix environment
          for compiler in icx icpx icc icpc; do
            if [ -f "$INTEL_BIN_DIR/$compiler" ] && [ ! -L "$INTEL_BIN_DIR/$compiler" ]; then
              echo "Wrapping Intel compiler: $compiler"
              mv "$INTEL_BIN_DIR/$compiler" "$INTEL_BIN_DIR/.$compiler-unwrapped"
              makeWrapper "$INTEL_BIN_DIR/.$compiler-unwrapped" "$INTEL_BIN_DIR/$compiler" \
                --prefix PATH : "${wrappedCompiler}/bin" \
                --set-default NIX_CC "${wrappedCompiler}"
            fi
          done
          break
        fi
      done
    '';

    passthru =
      kit.passthru
      // {
        cc = wrappedCompiler;
        isClang = true;
        isIntel = true;
      };
  }
