{
  stdenv,
  writeTextFile,
}:
# Reproduces the pure-link -lstdc++ issue for shared libraries.
# cmake builds .so files in pure link mode before linking the final executable,
# so this hits the same icpx omission as the executable case.
# Breaks with false, passes with true.
stdenv.mkDerivation {
  name = "test-cxx-shared-lib-pure-link";

  src = writeTextFile {
    name = "lib.cpp";
    text = ''
      #include <string>
      std::string greet() {
        return std::string("hello");
      }
    '';
  };

  dontUnpack = true;

  buildPhase = ''
    icpx -fPIC -c $src -o lib.o
    icpx -shared lib.o -o libtest.so
  '';

  installPhase = ''
    mkdir -p $out/lib
    cp libtest.so $out/lib/libtest.so
  '';
}
