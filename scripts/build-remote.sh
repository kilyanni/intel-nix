#!/usr/bin/env bash
# Build an attribute from the *local* (possibly dirty) checkout on the remote
# builder, with ccache enabled there.
#
# Why not just `nix build --builders ...`? Because ccache needs
# /var/cache/ccache bound into the build sandbox, and `--option
# extra-sandbox-paths` is applied by whichever daemon performs the build. With
# --builders that is the *remote* daemon, and nix does not forward client
# setting-overrides across the remote-build path — verified empirically: the
# flag has no effect there. Running `nix build` over ssh instead makes the
# remote daemon the one reading the flag, so it works.
#
# Only this repo's tree travels to the remote (small); flake inputs are fetched
# by the remote itself per flake.lock. Untracked files are invisible to flakes —
# `git add` them first or they are not part of the build.
#
# The remote needs nix with this user trusted, and passwordless sudo for the
# one-time mkdir of the cache dir.
#
# Modelled on ~/src/work/wasmer/repos/wasinix/cargo-registry/scripts/ci-build-remote.sh

set -euo pipefail

usage() {
  cat >&2 <<USAGE
usage: $0 [options] <attr>...
  <attr>               flake attribute(s), e.g. src.packages.monolithic.rocm.oneDNN
  -H, --host HOST      ssh host (default: read from /etc/nix/machines-work)
  -i, --ssh-key FILE   ssh identity file (default: from /etc/nix/machines-work)
      --no-ccache      build the ccache-free variant (packages-no-ccache);
                       needs no cache dir on the remote

NOTE: the cache size is CCACHE_MAXSIZE in flake.nix (10G at time of writing).
It is baked into the stdenv, so it cannot be overridden per run — edit
flake.nix if the builder is short on disk.
USAGE
  exit 64
}

host="" ssh_key="" no_ccache=0 attrs=()
while [ $# -gt 0 ]; do
  case "$1" in
  -H | --host) host="${2:?missing argument for $1}"; shift ;;
  -i | --ssh-key) ssh_key="${2:?missing argument for $1}"; shift ;;
  --no-ccache) no_ccache=1 ;;
  -h | --help) usage ;;
  -*) usage ;;
  *) attrs+=("$1") ;;
  esac
  shift
done
[ "${#attrs[@]}" -gt 0 ] || usage

# Default host/key from the nix remote-builder machine file, so there is one
# place to configure the builder.
machines=/etc/nix/machines-work
if [ -z "$host" ] || [ -z "$ssh_key" ]; then
  line=$(sudo sed -n '1p' "$machines" 2>/dev/null) || {
    echo "error: cannot read $machines; pass --host and --ssh-key" >&2
    exit 64
  }
  # Fields: uri system key maxJobs speedFactor features mandatory publicHostKey
  uri=$(awk '{print $1}' <<<"$line")
  [ -n "$host" ] || host=${uri#*://}
  [ -n "$ssh_key" ] || ssh_key=$(awk '{print $3}' <<<"$line")
fi

ssh_opts=(-o BatchMode=yes)
[ -n "$ssh_key" ] && ssh_opts+=(-i "$ssh_key")
# nix copy shells out to ssh itself.
[ -n "$ssh_key" ] && export NIX_SSHOPTS="-i $ssh_key"

# `nix flake prefetch` materializes only this flake's own tree, not the input
# closure — the remote fetches inputs itself, which beats pushing nixpkgs over
# a home uplink. Not `flake metadata`: with lazy trees its .path can name a
# store path that was never added, and the copy below then fails.
src=$(nix flake prefetch --json | jq -r .storePath)
echo "flake source: $src"
echo "copying to $host ..."
sudo -E nix copy --to "ssh://$host" "$src"

sandbox_opt=()
if [ "$no_ccache" -eq 0 ]; then
  # The cache dir must exist on the *remote*; extra-sandbox-paths binds an
  # existing host path, it cannot create one. Cheap to redo every run.
  echo "ensuring /var/cache/ccache on $host ..."
  sudo ssh "${ssh_opts[@]}" "$host" \
    'sudo install -d -m0770 -o root -g nixbld /var/cache/ccache && sudo du -sh /var/cache/ccache'
  sandbox_opt=(--option extra-sandbox-paths /var/cache/ccache)
fi

# `path:` so the remote evaluates the copied tree rather than looking for a
# checkout it does not have.
targets=()
for a in "${attrs[@]}"; do
  # With --no-ccache, redirect src.packages.* to the genuinely ccache-free
  # src.packages-no-ccache.* so the same attribute path works either way.
  [ "$no_ccache" -eq 1 ] && a="${a/#src.packages./src.packages-no-ccache.}"
  targets+=("path:$src#$a")
done

echo "building on $host: ${targets[*]}"
# --out-link, NOT --no-link: the result symlinks are the GC roots. Without them
# a later `nix store gc` on the builder throws the whole build away. A build in
# flight is safe either way (nix holds temp roots for it), but the finished
# outputs are not. Keep them under one directory so they are easy to drop.
# shellcheck disable=SC2029 # deliberate client-side expansion
sudo ssh "${ssh_opts[@]}" "$host" \
  "mkdir -p ~/intel-nix-results && \
   nix build --print-build-logs --out-link ~/intel-nix-results/result \
     ${sandbox_opt[*]} ${targets[*]}"
