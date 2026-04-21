{
  stdenv,
  writeTextFile,
}:
# Verifies that C++ link steps work in pure link mode (.o only, no source files),
# which is how cmake always invokes the linker.
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
