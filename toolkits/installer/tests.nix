{
  stdenv,
  writeTextFile,
}: {
  # Basic SYCL compilation test
  sycl-compile = stdenv.mkDerivation {
    name = "intel-toolkit-test-sycl-compile";

    src = writeTextFile {
      name = "test.cpp";
      text = ''
        #include <sycl/sycl.hpp>
        #include <iostream>

        int main() {
          sycl::queue q;
          std::cout << "SYCL queue created successfully" << std::endl;
          std::cout << "Device: " << q.get_device().get_info<sycl::info::device::name>() << std::endl;
          return 0;
        }
      '';
    };

    dontUnpack = true;

    buildPhase = ''
      echo "Testing SYCL compilation with Intel toolkit..."
      # Use icpx explicitly to ensure we're using Intel compiler
      icpx -fsycl $src -o test
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp test $out/bin/sycl-test

      # Create a marker file indicating test passed
      echo "SYCL compilation test passed" > $out/test-passed
    '';

    meta = {
      description = "Test that Intel toolkit stdenv can compile SYCL programs";
    };
  };

  # Test that the compiler can find its own headers
  headers-available = stdenv.mkDerivation {
    name = "intel-toolkit-test-headers";

    dontUnpack = true;

    buildPhase = ''
      echo "Testing header availability..."
      echo '#include <sycl/sycl.hpp>' | icpx -fsycl -x c++ -E - > /dev/null
      echo '#include <CL/sycl.hpp>' | icpx -fsycl -x c++ -E - > /dev/null
      echo '#include <iostream>' | icpx -x c++ -E - > /dev/null
    '';

    installPhase = ''
      mkdir -p $out
      echo "Header availability test passed" > $out/test-passed
    '';

    meta = {
      description = "Test that Intel toolkit headers are accessible";
    };
  };

  # Test basic C compilation
  c-compile = stdenv.mkDerivation {
    name = "intel-toolkit-test-c-compile";

    src = writeTextFile {
      name = "test.c";
      text = ''
        #include <stdio.h>

        int main() {
          printf("Hello from Intel C compiler!\n");
          return 0;
        }
      '';
    };

    dontUnpack = true;

    buildPhase = ''
      echo "Testing C compilation with Intel toolkit..."
      icx $src -o test
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp test $out/bin/c-test

      echo "C compilation test passed" > $out/test-passed
    '';

    meta = {
      description = "Test that Intel toolkit can compile basic C programs";
    };
  };

  # Test OpenMP support
  openmp-compile = stdenv.mkDerivation {
    name = "intel-toolkit-test-openmp";

    src = writeTextFile {
      name = "test.c";
      text = ''
        #include <omp.h>
        #include <stdio.h>

        int main() {
          #pragma omp parallel
          {
            int tid = omp_get_thread_num();
            printf("Hello from thread %d\n", tid);
          }
          return 0;
        }
      '';
    };

    dontUnpack = true;

    buildPhase = ''
      echo "Testing OpenMP compilation with Intel toolkit..."
      icx -fiopenmp $src -o test
    '';

    installPhase = ''
      mkdir -p $out/bin
      cp test $out/bin/openmp-test

      echo "OpenMP compilation test passed" > $out/test-passed
    '';

    meta = {
      description = "Test that Intel toolkit can compile OpenMP programs";
    };
  };
}
