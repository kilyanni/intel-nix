# syclcompat: header-only SYCL compatibility library.
# Removed from the Intel LLVM monorepo at commit 26e4c60f80b6; fetch it from
# the last commit before removal using sparse checkout (only that subdir).
{
  fetchFromGitHub,
  runCommand,
}: let
  src = fetchFromGitHub {
    owner = "intel";
    repo = "llvm";
    rev = "e1b888d9b5041ecfafa69921ea690380547f50f9";
    rootDir = "sycl/include/syclcompat";
    hash = "sha256-IGpRFvbsr5//iejB7buVwR0KJPubtEfSyWBg/U9pZ0U=";
  };
in
  runCommand "syclcompat" {} ''
    mkdir -p $out/include/syclcompat
    cp -r ${src}/. $out/include/syclcompat/
  ''
