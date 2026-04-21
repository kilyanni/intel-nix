{
  stdenv,
  writeTextFile,
}:
# Reproduces the icpx pure-link-mode -lstdc++ omission.
# icpx omits -lstdc++ when called with only .o inputs (no source files),
# which is how cmake always invokes the linker. The libcxx-ldflags mechanism
# in the cc-wrapper must supply it instead.
stdenv.mkDerivation {
  name = "test-pure-link-libstdcxx";

  src = writeTextFile {
    name = "test.cpp";
    text = ''
      #include <iostream>
      #include <string>
      int main() {
        std::string s = "hello";
        std::cout << s << std::endl;
        return 0;
      }
    '';
  };

  dontUnpack = true;

  buildPhase = ''
    icpx -c $src -o test.o
    icpx test.o -o test
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp test $out/bin/test
  '';
}
