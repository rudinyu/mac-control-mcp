#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$project_dir/.build/module-cache"

# Every file in Sources/ is part of the server, so a new source file cannot be left out.
swiftc -module-cache-path "$project_dir/.build/module-cache" -parse-as-library \
  "$project_dir"/Sources/*.swift \
  -o "$project_dir/.build/mac-control-mcp"
