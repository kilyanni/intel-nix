#!/usr/bin/env fish
# Regenerate .patch files from the intel/llvm packaging branches.
#
# Each branch is a separate logical change (PR) against intel/llvm. We capture
# each as a single .patch file via `git diff <base>..<branch>` and commit it
# here.
#
# Two families of branches exist in $REPO:
#
#   fix/*  — the upstream-targeted branches, based on `upstream/sycl` and each
#            checked out in its own worktree under $WT for editing. These are
#            what gets submitted to intel/llvm (see PR-NOTES.md); do not rebase
#            them onto a release tag.
#   v7/*   — packaging-only ports of the same commits onto the $BASE release
#            tag, which is what we actually build. Regenerate these with
#            `git cherry-pick fix/<name>` onto $BASE after moving $BASE.
#            These may carry EXTRA commits with no counterpart in fix/*: the
#            release branch forked from main in Jan 2026 and still needs fixes
#            mainline has since obsoleted (e.g. libclc's remangler calling
#            add_clang_tool). Such commits are marked "Release-branch only" in
#            their message — do not try to upstream them.
#
# `git diff` does not need a branch checked out, so all of these are read
# straight out of the main clone rather than per-branch worktrees.
#
# Per-component patches are stripped to apply with -p1 at their component's
# sourceRoot — so editing one patch only rebuilds that one component, not the
# whole monorepo source. gnu-install-dirs alone stays at monorepo level (it
# touches many subdirs).

set -g SCRIPT_DIR (status dirname)
set -g OUT $SCRIPT_DIR/patches
set -g REPO /home/blenderfreaky/src/stuff/intel/intel-llvm
set -g WT /home/blenderfreaky/src/stuff/intel/intel-llvm-worktrees

# Base rev — must match the `rev`/`tag` in standalone.nix and src/llvm/package.nix.
set -g BASE v7.0.0

# gen_patch <branch> <out-name> [subdir-to-strip]
function gen_patch -a branch out_name relative
    if not git -C $REPO rev-parse --verify --quiet $branch >/dev/null
        echo "ERROR: missing branch $branch in $REPO" >&2
        return 1
    end
    set -l rel_flag
    test -n "$relative"; and set rel_flag --relative=$relative
    echo "  $out_name  <-  $branch"
    git -C $REPO diff $rel_flag $BASE..$branch >$OUT/$out_name
end

echo "Generating patches in $OUT (base: $BASE)"

# Monorepo-level: touches many subdirs, must apply at srcOrig root.
# v7/gnu-install-dirs-full = fix/install-dirs-destdir + fix/gnu-install-dirs;
# they are separate PRs upstream but a single patch file for us.
gen_patch v7/gnu-install-dirs-full          gnu-install-dirs.patch

# Component-level: each strips its sourceRoot prefix so -p1 applies in-place.
gen_patch v7/sycl-jit-cmake-leak            sycl-jit-exclude-cmake-files.patch     sycl-jit
gen_patch v7/standalone-libclc              standalone-libclc.patch                libclc
gen_patch v7/standalone-libdevice           standalone-libdevice.patch             libdevice
gen_patch v7/standalone-opencl              standalone-opencl.patch                opencl
gen_patch v7/standalone-spirv-to-ir-wrapper standalone-spirv-to-ir-wrapper.patch   llvm/tools/spirv-to-ir-wrapper
gen_patch v7/standalone-sycl                standalone-sycl.patch                  sycl
gen_patch v7/standalone-sycl-jit            standalone-sycl-jit.patch              sycl-jit
gen_patch v7/standalone-xptifw              standalone-xptifw.patch                xptifw

echo "Done."
