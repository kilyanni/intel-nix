{
  llama-cpp,
  writeShellApplication,
}:
writeShellApplication {
  name = "llama-e2e-test";

  runtimeInputs = [llama-cpp];

  text = ''
    usage() {
      echo "Usage: llama-e2e-test [--model|-m <path>] [--prompt|-p <text>] [--n-predict|-n <n>]" >&2
      echo "  Model lookup order: --model flag > \$LLAMA_MODEL env var (no default)" >&2
      echo "  Defaults: prompt=\"Hello!\", n-predict=32" >&2
      exit 1
    }

    model="''${LLAMA_MODEL:-}"
    prompt="Hello!"
    n_predict=32

    while [[ $# -gt 0 ]]; do
      case "$1" in
        --model|-m)     model="$2";     shift 2 ;;
        --prompt|-p)    prompt="$2";    shift 2 ;;
        --n-predict|-n) n_predict="$2"; shift 2 ;;
        --help|-h)      usage ;;
        -*)             echo "Unknown flag: $1" >&2; usage ;;
        *)              echo "Unexpected argument: $1" >&2; usage ;;
      esac
    done

    [[ -n "$model" ]] || { echo "Error: no model given (use --model or \$LLAMA_MODEL)" >&2; usage; }
    [[ -f "$model" ]] || { echo "Error: model not found: $model" >&2; exit 1; }

    exec llama-cli -m "$model" -p "$prompt" -n "$n_predict"
  '';
}
