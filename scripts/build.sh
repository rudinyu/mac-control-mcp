#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
mkdir -p "$project_dir/.build/module-cache"
export CLANG_MODULE_CACHE_PATH="$project_dir/.build/module-cache"
export SWIFT_MODULE_CACHE_PATH="$project_dir/.build/module-cache"

# Usage: build.sh [mac-control|mac-exec|all]. Each folder in Sources/ is one server, and each is built
# on its own, so a compile error in one does not stop the other from starting.
target="${1:-all}"
build() {
  swiftc -module-cache-path "$project_dir/.build/module-cache" -parse-as-library \
    "$project_dir"/Sources/"$1"/*.swift \
    -o "$project_dir/.build/$2"
}
case "$target" in
  mac-control) build MacControl mac-control-mcp ;;
  mac-exec) build MacExec mac-exec-mcp ;;
  all) build MacControl mac-control-mcp; build MacExec mac-exec-mcp ;;
  *) echo "Unknown target: $target (use mac-control, mac-exec, or all)" >&2; exit 2 ;;
esac
