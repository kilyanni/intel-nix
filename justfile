# intel-nix build and test recipes
#
# End-to-end GPU inference tests (2026-04-27, stripDebugFlags = ["--strip-unneeded"]):
#   whisper-cpp (monolithic.rocm): AMD RX 6800 via HIP/ROCm SYCL; transcribed 95s audio accurately
#   llama-cpp   (monolithic.rocm): AMD RX 6800 via HIP/ROCm SYCL; all 17 layers offloaded, generated response
#   Conclusion: --strip-unneeded does not break the SYCL GPU inference pipeline

# Build any package. variant: monolithic.l0, monolithic.rocm, monolithic.cuda, standalone.*
build pkg variant="monolithic.l0":
    nix build --builders '' --print-build-logs --print-out-paths '.#src.packages.{{variant}}.{{pkg}}'

# Run end-to-end whisper GPU inference test on a given audio/video file.
# Usage:       just test-whisper /path/to/audio.mkv
# Other GPU:   just test-whisper /path/to/audio.mkv monolithic.cuda
# Alt model:   just test-whisper /path/to/audio.mkv monolithic.rocm --model /path/to/model.bin
test-whisper file variant="monolithic.rocm" *args="":
    nix run --builders '' '.#src.packages.{{variant}}.tests.whisper-e2e' -- '{{file}}' {{args}}

# Run end-to-end llama GPU inference test.
# Usage:        just test-llama --model /path/to/model.gguf
# Custom prompt: just test-llama monolithic.rocm --model /path/to/model.gguf --prompt "Tell me a joke"
# Alt model env: LLAMA_MODEL=/path/to/model.gguf just test-llama
test-llama variant="monolithic.rocm" *args="":
    nix run --builders '' '.#src.packages.{{variant}}.tests.llama-e2e' -- {{args}}

# Build a SYCL compile test — sandboxed, no GPU required.
# One test exists per backend the toolchain was built with; list them with
#   nix eval '.#src.packages.monolithic.rocm.llvm.passthru.tests' --apply builtins.attrNames
# target: spir64, native_cpu, amdgcn-amd-amdhsa, nvptx64-nvidia-cuda
test-sycl-compile target="spir64" variant="monolithic.l0":
    nix build --builders '' --print-build-logs '.#src.packages.{{variant}}.llvm.passthru.tests.sycl-compile-{{target}}'

# Actually RUN a SYCL kernel on a real GPU. Needs root: the test executes inside
# the nix sandbox with GPU device nodes bound in via --extra-sandbox-paths.
# makeImpureTest's own runner uses `nix-build -A`, which does not resolve in a
# flake, so invoke the testDerivation directly instead.
#
# backend: level_zero, opencl (Intel) | hip (AMD) | cuda (NVIDIA)
# List what a toolchain offers:
#   nix eval '.#src.packages.monolithic.rocm.llvm.passthru.impureTests' --apply builtins.attrNames
#
# AOT backends (hip, cuda) are compiled for a fixed arch — override it if your
# GPU differs, e.g.
#   nix build '.#src.packages.monolithic.rocm.llvm.passthru.impureTests.override' ...
#
# /run/opengl-driver is a symlink into the store and nix does not follow
# symlinks when binding sandbox paths, so it is mapped explicitly below.
test-sycl-run backend="hip" variant="monolithic.rocm" paths="/sys /dev/dri /dev/kfd":
    sudo nix build --builders '' --print-build-logs --no-link \
      --option extra-sandbox-paths \
        "{{paths}} /run/opengl-driver=$(readlink -f /run/opengl-driver)" \
      '.#src.packages.{{variant}}.llvm.passthru.impureTests.sycl-run-{{backend}}.testDerivation'
