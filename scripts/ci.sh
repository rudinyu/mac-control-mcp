#!/bin/sh
set -eu

project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cache="$project_dir/.build/module-cache"
. "$project_dir/scripts/sources.sh"
"$project_dir/scripts/build.sh"

# Tests are built here, not in build.sh, so a broken test never blocks the server from starting.
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/TerminalText.swift" "$project_dir/tests/TerminalTextTests.swift" \
  -o "$project_dir/.build/terminal-text-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/SessionLock.swift" "$project_dir/tests/SessionLockTests.swift" \
  -o "$project_dir/.build/session-lock-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/Failure.swift" "$project_dir/Sources/Shared/JSON.swift" \
  "$project_dir/tests/FailureTests.swift" \
  -o "$project_dir/.build/failure-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/SharedLock.swift" "$project_dir/Sources/MacControl/Failure.swift" \
  "$project_dir/Sources/Shared/JSON.swift" "$project_dir/Sources/Shared/Cancellation.swift" "$project_dir/tests/SharedLockTests.swift" \
  -o "$project_dir/.build/shared-lock-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacControl/RefRegistry.swift" "$project_dir/tests/RefRegistryTests.swift" \
  -o "$project_dir/.build/ref-registry-tests"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir"/Sources/Shared/*.swift "$project_dir/.build/generated/Version.swift" "$project_dir/tests/FakeMCPServer.swift" \
  -o "$project_dir/.build/fake-mcp-server"
swiftc -module-cache-path "$cache" -parse-as-library \
  "$project_dir/Sources/MacExec/ContainerRuntime.swift" "$project_dir/Sources/MacExec/ProcessRunner.swift" \
  "$project_dir/Sources/Shared/Cancellation.swift" "$project_dir/tests/ContainerRuntimeTests.swift" \
  -o "$project_dir/.build/container-runtime-tests"
(
  set -f; IFS=$line_break
  swiftc -module-cache-path "$cache" -parse-as-library $(project_files "$app_logic_sources") \
    "$project_dir/tests/AppLogicTests.swift" \
    -o "$project_dir/.build/app-logic-tests"
)

"$project_dir/.build/terminal-text-tests"
"$project_dir/.build/session-lock-tests"
"$project_dir/.build/failure-tests"
"$project_dir/.build/ref-registry-tests"
"$project_dir/.build/shared-lock-tests"
sh "$project_dir/scripts/check-localization.sh"
"$project_dir/.build/container-runtime-tests"
"$project_dir/.build/app-logic-tests"
python3 "$project_dir/tests/test_mcp_server.py" "$project_dir/.build/fake-mcp-server"
python3 "$project_dir/tests/test_protocol.py" "$project_dir/.build/mac-control-mcp"
python3 "$project_dir/tests/test_init_agents.py"
# Sandbox tests are skipped when Docker or the sandbox image is not available.
# The host_exec tests run real, harmless commands such as echo and sleep on this Mac.
python3 "$project_dir/tests/test_mac_exec.py" "$project_dir/.build/mac-exec-mcp"
