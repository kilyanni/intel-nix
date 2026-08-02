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

          # For CUDA & MKL
          config.allowUnfree = true;

          overlays = [
            (final: prev: {
              # ccacheWrapper replaces cc.cc (the real compiler) with ccache.links,
              # and cc-wrapper reads a number of attrs off that cc arg. Upstream's
              # ccache.links forwards isClang/isGNU and hardeningUnsupportedFlags*,
              # but not langC/langCC, so forward what it misses from the original
              # cc.cc.
              #
              # langCC matters for clang specifically: cc-wrapper only emits the
              # `-cxx-isystem` libstdc++ paths when
              #   libcxx == null && isClang && useGccForLibs && cc.langCC
              # (pkgs/build-support/cc-wrapper/default.nix). Without it,
              # nix-support/libcxx-cxxflags comes out empty while `-nostdlibinc`
              # is still applied, so every C++ compile fails to find <atomic> and
              # friends. Only bites clang stdenvs, which is why the gcc-based
              # default stdenv never showed it.
              ccacheWrapper =
                prev.lib.makeOverridable (
                  {
                    extraConfig,
                    cc,
                  }:
                    cc.override {
                      cc =
                        (prev.ccache.links {
                          inherit extraConfig;
                          unwrappedCC = cc.cc;
                        })
                        // builtins.intersectAttrs {
                          hardeningUnsupportedFlagsByTargetPlatform = null;
                          hardeningUnsupportedFlags = null;
                          langC = null;
                          langCC = null;
                        }
                        cc.cc;
                    }
                ) {
                  extraConfig = "";
                  inherit (prev.stdenv) cc;
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
