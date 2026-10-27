#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$project_dir/.build/module-cache"

swiftc -module-cache-path "$project_dir/.build/module-cache" \
  "$project_dir/Sources/MacControl.swift" \
  -o "$project_dir/.build/mac-control-mcp"
