#!/bin/bash
set -euo pipefail
launcher_dir="$(cd "$(dirname "$0")" && pwd)"
exec "$launcher_dir/Clipato.app/Contents/MacOS/Clipato" "$@"
