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
              # ccacheWrapper replaces cc.cc (the real compiler) with ccache.links
              # but drops hardeningUnsupportedFlags* in the process, because
              # cc-wrapper reads those attrs from the cc arg (which becomes
              # ccache.links). Forward them from the original cc.cc so the
              # cc-wrapper still sees the correct hardening constraints.
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
                        // prev.lib.optionalAttrs (cc.cc ? hardeningUnsupportedFlagsByTargetPlatform) {
                          inherit (cc.cc) hardeningUnsupportedFlagsByTargetPlatform;
                        }
                        // prev.lib.optionalAttrs (cc.cc ? hardeningUnsupportedFlags) {
                          inherit (cc.cc) hardeningUnsupportedFlags;
                        };
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
