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
  };

  # extraPackages propagates the full Intel toolkit (runtime, headers, libs)
  # into any stdenv built on this compiler.
  wrappedCC = wrapCCWith {
    cc = unwrappedCC;
    extraPackages = [kit];
    extraBuildCommands = ''
      ln -s $out/bin/clang++ $out/bin/icpx
      ln -s $out/bin/clang   $out/bin/icx
    '';
  };

  intelStdenv = overrideCC stdenv final;

  final = symlinkJoin {
    name = kit.name;
    paths = [kit wrappedCC];

    # postBuild = ''
    #   mkdir -p $out/bin
    #   ln -s ${wrappedCC}/bin/clang++ $out/bin/icpx
    #   ln -s ${wrappedCC}/bin/clang   $out/bin/icx
    # '';

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
