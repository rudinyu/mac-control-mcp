#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$project_dir/scripts/build.sh"
python3 "$project_dir/tests/test_protocol.py" "$project_dir/.build/mac-control-mcp"
