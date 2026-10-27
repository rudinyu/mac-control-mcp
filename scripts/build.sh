#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$project_dir/.build/module-cache"

swiftc -module-cache-path "$project_dir/.build/module-cache" -parse-as-library \
  "$project_dir/Sources/MacControl.swift" "$project_dir/Sources/TerminalText.swift" "$project_dir/Sources/SessionLock.swift" \
  -o "$project_dir/.build/mac-control-mcp"
