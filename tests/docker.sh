#!/usr/bin/env bash
# Build and run the silent suite in a Linux container.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
docker build -q -t agent-tunes-tests -f "$ROOT/tests/Dockerfile" "$ROOT" >/dev/null
exec docker run --rm agent-tunes-tests
