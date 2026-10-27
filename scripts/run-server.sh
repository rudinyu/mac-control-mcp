#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
binary="$project_dir/.build/mac-control-mcp"
source_file="$project_dir/Sources/MacControl.swift"

if [ ! -x "$binary" ] || [ "$source_file" -nt "$binary" ]; then
  "$project_dir/scripts/build.sh" >&2
fi

exec "$binary"
