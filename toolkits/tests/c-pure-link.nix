{
  stdenv,
  writeTextFile,
}:
# Verifies that -lstdc++ is NOT injected for C builds.
# Should pass regardless of the libcxx-ldflags toggle.
stdenv.mkDerivation {
  name = "test-c-pure-link";

  src = writeTextFile {
    name = "test.c";
    text = ''
      #include <stdio.h>
      int main() {
        printf("hello\n");
        return 0;
      }
    '';
  };

  dontUnpack = true;

  buildPhase = ''
    icx -c $src -o test.o
    icx test.o -o test
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp test $out/bin/test
  '';
}
