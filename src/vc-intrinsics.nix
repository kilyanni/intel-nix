{
  stdenv,
  lib,
  fetchFromGitHub,
  cmake,
  ninja,
  python3,
  llvmPackages_22,
}:
stdenv.mkDerivation {
  pname = "vc-intrinsics";
  version = "unstable-2025-05-05";

  #https://github.com/intel/vc-intrinsics
  src = fetchFromGitHub {
    owner = "intel";
    repo = "vc-intrinsics";
    rev = "60cea7590bd022d95f5cf336ee765033bd114d69";
    hash = "sha256-1K16UEa6DHoP2ukSx58OXJdtDWyUyHkq5Gd2DUj1644=";
  };

  nativeBuildInputs = [
    cmake
    ninja
    python3
  ];
  # buildInputs = [ llvmPackages_22.libllvm.dev ];

  patches = [
    ./fix-vc-intrinsics-static-linking.patch
  ];

  cmakeFlags = [
    (lib.cmakeFeature "LLVM_DIR" "${lib.getDev llvmPackages_22.llvm}/lib/cmake/llvm")
    # (lib.cmakeBool "BUILD_EXTERNAL" true)
    (lib.cmakeBool "LLVM_LINK_LLVM_DYLIB" false)
  ];
}
