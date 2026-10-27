#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
"$project_dir/scripts/build.sh"
# Tests are built here, not in build.sh, so a broken test never blocks the server from starting.
swiftc -module-cache-path "$project_dir/.build/module-cache" -parse-as-library \
  "$project_dir/Sources/TerminalText.swift" "$project_dir/tests/TerminalTextTests.swift" \
  -o "$project_dir/.build/terminal-text-tests"
"$project_dir/.build/terminal-text-tests"
python3 "$project_dir/tests/test_protocol.py" "$project_dir/.build/mac-control-mcp"
python3 "$project_dir/tests/test_init_agents.py"
