#!/bin/bash
# Install the scene engine separately from the app; model weights stay in Application Support.
set -euo pipefail
clip_support="$HOME/Library/Application Support/ClipName/Vision"
clip_root="$(cd "$(dirname "$0")/.." && pwd)"
clip_uv="${CLIPNAME_UV:-uv}"
if ! command -v "$clip_uv" >/dev/null 2>&1; then
    echo 'Install uv from https://docs.astral.sh/uv/getting-started/installation/ first.'
    exit 1
fi
if [ "$(uname -m)" != arm64 ]; then
    echo 'Local scene naming currently requires an Apple Silicon Mac.'
    exit 1
fi
mkdir -p "$clip_support"
export UV_PYTHON_INSTALL_DIR="$clip_support/python"
if [ ! -x "$clip_support/runtime/bin/python" ]; then
    "$clip_uv" venv --python 3.12 "$clip_support/runtime"
fi
"$clip_uv" pip install --python "$clip_support/runtime/bin/python" -r "$clip_root/scripts/vision-requirements.txt"
"$clip_support/runtime/bin/python" "$clip_root/Sources/EchoRename/Resources/scene_namer.py" --download --model "$clip_support/model"
echo 'Scene naming is ready. Open ClipName and choose Speech + scenes or Scenes only.'
