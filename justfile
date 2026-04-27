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

# Build the SYCL compile test — sandboxed, no GPU required.
test-sycl-compile:
    nix build --builders '' --print-build-logs '.#src.llvm.passthru.tests.sycl-compile'
