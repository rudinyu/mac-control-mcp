#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$project_dir/.build/module-cache"
"$project_dir/scripts/build.sh"

# Tests are built here, not in build.sh, so a broken test never blocks the server from starting.
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/TerminalText.swift" "$project_dir/tests/TerminalTextTests.swift" \
  -o "$project_dir/.build/terminal-text-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/SessionLock.swift" "$project_dir/tests/SessionLockTests.swift" \
  -o "$project_dir/.build/session-lock-tests"

"$project_dir/.build/terminal-text-tests"
"$project_dir/.build/session-lock-tests"
python3 "$project_dir/tests/test_protocol.py" "$project_dir/.build/mac-control-mcp"
python3 "$project_dir/tests/test_init_agents.py"
# Sandbox tests are skipped when Docker or the sandbox image is not available, as on GitHub Actions.
# The host_exec tests run real, harmless commands such as echo and sleep on this Mac.
python3 "$project_dir/tests/test_mac_exec.py" "$project_dir/.build/mac-exec-mcp"
