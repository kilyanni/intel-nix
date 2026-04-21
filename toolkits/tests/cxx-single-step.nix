{
  stdenv,
  writeTextFile,
}:
# Verifies that compile+link in one icpx invocation works without the
# libcxx-ldflags mechanism, since icpx handles -lstdc++ itself in this mode.
# Should pass regardless of the toggle.
stdenv.mkDerivation {
  name = "test-cxx-single-step";

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
    icpx $src -o test
  '';

  installPhase = ''
    mkdir -p $out/bin
    cp test $out/bin/test
  '';
}
