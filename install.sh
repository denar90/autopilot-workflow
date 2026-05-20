#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR="${HOME}/.local/bin"
TARGET="${TARGET_DIR}/autopilot"

mkdir -p "$TARGET_DIR"

if [[ -L "$TARGET" || -e "$TARGET" ]]; then
  echo "Already exists: $TARGET. Remove it first if you want to reinstall."
  exit 1
fi

ln -s "$ROOT/bin/autopilot" "$TARGET"
echo "Installed: $TARGET -> $ROOT/bin/autopilot"
echo "Ensure $TARGET_DIR is on your PATH."
