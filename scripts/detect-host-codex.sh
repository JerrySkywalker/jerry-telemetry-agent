#!/usr/bin/env bash
set -euo pipefail

if command -v codex >/dev/null 2>&1; then
  command -v codex
  exit 0
fi

echo "codex binary not found on PATH" >&2
exit 1
