#!/usr/bin/env bash
# Build build/lambda: the handler code plus pinned dependencies for
# Lambda python3.13 on arm64. Terraform zips this folder.
source "$(dirname "$0")/lib.sh"

OUT="$BUILD/lambda"
log "building Lambda package in ${OUT#$ROOT/}"
rm -rf "$OUT"
mkdir -p "$OUT"

if command -v uv >/dev/null 2>&1; then
  uv pip install --quiet --target "$OUT" --python-platform aarch64-manylinux2014 \
    --python-version 3.13 --only-binary :all: -r "$ROOT/src/requirements.txt"
else
  "$PY" -m pip install --quiet --target "$OUT" --platform manylinux2014_aarch64 \
    --implementation cp --python-version 3.13 --only-binary=:all: --upgrade \
    -r "$ROOT/src/requirements.txt"
fi

cp -R "$ROOT/src/devops_agent_lambdas" "$OUT/"
# Smaller, reproducible package: no caches, fixed timestamps.
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} +
find "$OUT" -exec touch -t 202001010000 {} +
log "Lambda package ready ($(du -sh "$OUT" | cut -f1))"
