{
  whisper-cpp,
  ffmpeg,
  writeShellApplication,
}:
writeShellApplication {
  name = "whisper-e2e-test";

  runtimeInputs = [whisper-cpp ffmpeg];

  text = ''
    usage() {
      echo "Usage: whisper-e2e-test [--model|-m <path>] <audio-file>" >&2
      echo "  Model lookup order: --model flag > \$WHISPER_MODEL env var > ~/.cache/whisper/ggml-tiny.bin" >&2
      exit 1
    }

    model="''${WHISPER_MODEL:-$HOME/.cache/whisper/ggml-tiny.bin}"
    file=""

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model|-m) model="$2"; shift 2 ;;
        --help|-h)  usage ;;
        -*)         echo "Unknown flag: $1" >&2; usage ;;
        *)          file="$1"; shift ;;
      esac
    done

    [[ -n "$file"  ]] || { echo "Error: no audio file given" >&2; usage; }
    [[ -f "$model" ]] || { echo "Error: model not found: $model" >&2; exit 1; }
    [[ -f "$file"  ]] || { echo "Error: audio file not found: $file" >&2; exit 1; }

    audio="$file"
    if [[ "$file" != *.wav ]]; then
      tmp=$(mktemp --suffix=.wav)
      trap 'rm -f "$tmp"' EXIT
      ffmpeg -i "$file" -ar 16000 -ac 1 -c:a pcm_s16le "$tmp" -y
      audio="$tmp"
    fi

    exec whisper-cli -m "$model" -f "$audio"
  '';
}
