{fetchFromGitHub}: {
  vc-intrinsics = fetchFromGitHub {
    owner = "intel";
    repo = "vc-intrinsics";
    # See llvm/lib/SYCLLowerIR/CMakeLists.txt:17
    rev = "60cea7590bd022d95f5cf336ee765033bd114d69";
    sha256 = "sha256-1K16UEa6DHoP2ukSx58OXJdtDWyUyHkq5Gd2DUj1644=";
  };
}
