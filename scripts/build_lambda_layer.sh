#!/usr/bin/env bash
set -euo pipefail

# Build a Lambda dependency layer in build/layer/python.
# This is designed to be used by Terraform (via local-exec) and manually.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/layer/python"
REQ_FILE="$ROOT_DIR/requirements-layer.txt"

PYTHON_BIN="${PYTHON_BIN:-python3}"

rm -rf "$ROOT_DIR/build/layer"
mkdir -p "$BUILD_DIR"

"$PYTHON_BIN" -m pip install -r "$REQ_FILE" -t "$BUILD_DIR"

echo "Layer build complete: $ROOT_DIR/build/layer"
