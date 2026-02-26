{
  description = "WIP Packaging of Intel LLVM, OneAPI and related tools for Nix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = {
    self,
    nixpkgs,
    flake-utils,
  }:
    flake-utils.lib.eachDefaultSystem (
      system: let
        pkgs = import nixpkgs {
          inherit system;

          overlays = [
            (final: prev: {
              unified-memory-framework = prev.unified-memory-framework.overrideAttrs {
                version = "1.1.0";
                src = prev.fetchFromGitHub {
                  owner = "oneapi-src";
                  repo = "unified-memory-framework";
                  tag = "v1.1.0";
                  hash = "sha256-1Z65rNsUNeaeSJmxwpEHPbiU4KEDvyrWL9LyAWFsR1c=";
                };
                patches = [];
              };
              ccacheStdenv = prev.ccacheStdenv.override {
                extraConfig = ''
                  export CCACHE_MAXSIZE=10G
                  export CCACHE_COMPRESS=1
                  #export CCACHE_DIR="$ {config.programs.ccache.cacheDir}"
                  export CCACHE_DIR="/var/cache/ccache"
                  export CCACHE_UMASK=007
                  export CCACHE_SLOPPINESS=random_seed
                  if [ ! -d "$CCACHE_DIR" ]; then
                    echo "====="
                    echo "Directory '$CCACHE_DIR' does not exist"
                    echo "Please create it with:"
                    echo "  sudo mkdir -m0770 '$CCACHE_DIR'"
                    echo "  sudo chown root:nixbld '$CCACHE_DIR'"
                    echo "====="
                    exit 1
                  fi
                  if [ ! -w "$CCACHE_DIR" ]; then
                    echo "====="
                    echo "Directory '$CCACHE_DIR' is not accessible for user $(whoami)"
                    echo "Please verify its access permissions"
                    echo "====="
                    exit 1
                  fi
                '';
              };
            })
          ];
        };
      in {
        packages = {
          src = pkgs.callPackage ./src {};

          toolkits = pkgs.callPackage ./toolkits {};

          # deb = pkgs.callPackage ./deb { };
        };
      }
    );
}
