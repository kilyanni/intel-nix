{
  lib,
  gcc13Stdenv,
  fetchFromGitHub,
  cmake,
  ninja,
  git,
  python3,
  spirv-headers,
}:
gcc13Stdenv.mkDerivation (finalAttrs: {
  pname = "opencl-clang";
  version = "14.0.2";

  srcs = [
    (fetchFromGitHub {
      name = "llvm-project";
      owner = "llvm";
      repo = "llvm-project";
      tag = "llvmorg-14.0.6";
      hash = "sha256-vffu4HilvYwtzwgq+NlS26m65DGbp6OSSne2aje1yJE=";
    })
    (fetchFromGitHub {
      name = "SPIRV-LLVM-Translator";
      owner = "KhronosGroup";
      repo = "SPIRV-LLVM-Translator";
      tag = "v14.0.15";
      hash = "sha256-0MO95/sb02VunC60zcwrL8lb31a59KtuqUUow30OksE=";
    })
    (fetchFromGitHub {
      name = "opencl-clang";
      owner = "intel";
      repo = "opencl-clang";
      tag = "v${finalAttrs.version}";
      hash = "sha256-j2/NqfXV9PjJ5jyOfqrCeUUNzMniDU9rBAVhvbSwFBo=";
    })
  ];

  nativeBuildInputs = [
    cmake
    ninja
    git
    python3
  ];

  buildInputs = [
    spirv-headers
  ];

  preConfigure = ''
    # sourceRoot is llvm-project/llvm; chmod the whole llvm-project tree
    chmod -R u+w ..
  '';

  sourceRoot = "llvm-project/llvm";

  cmakeFlags = [
    "-DLLVM_TARGETS_TO_BUILD=X86"
    "-DLLVM_ENABLE_PROJECTS=clang"
    "-DLLVM_EXTERNAL_PROJECTS=llvm-spirv;opencl-clang"
    "-DLLVM_EXTERNAL_LLVM_SPIRV_SOURCE_DIR=/build/SPIRV-LLVM-Translator"
    "-DLLVM_EXTERNAL_OPENCL_CLANG_SOURCE_DIR=/build/opencl-clang"
    (lib.cmakeFeature "LLVM_EXTERNAL_SPIRV_HEADERS_SOURCE_DIR" "${spirv-headers.src}")
    "-DCMAKE_POLICY_VERSION_MINIMUM=3.5"
  ];

  meta = {
    homepage = "https://github.com/intel/opencl-clang/";
    description = "Clang wrapper library with an OpenCL-oriented API and the ability to compile OpenCL C kernels to SPIR-V modules";
    license = lib.licenses.ncsa;
    maintainers = [lib.maintainers.blenderfreaky];
    platforms = lib.platforms.linux;
  };
})
