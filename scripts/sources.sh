# Source files that more than one script compiles, one per line, relative to the project folder.
# Sourced by build-app.sh and ci.sh, which expect $project_dir to be set.

# The sandbox code the app shares with mac-exec, without mac-exec's server entry point.
app_sandbox_sources="Sources/MacExec/ProcessRunner.swift
Sources/Shared/Cancellation.swift
Sources/MacExec/ContainerRuntime.swift
Sources/MacExec/PathGuard.swift"

# The app's code that needs no window or Mac state, which tests/AppLogicTests.swift checks.
app_logic_sources="App/Sources/ClientConfig.swift
App/Sources/JSONEdit.swift
App/Sources/RuntimePlan.swift
App/Sources/SetupLogic.swift"

# Prints each file of a list with the project folder in front, one per line. Split the output only at line
# breaks, so a project folder with spaces stays one argument:  IFS=$line_break; cmd $(project_files "$list"); unset IFS
line_break='
'
project_files() {
  printf '%s\n' "$1" | while IFS= read -r file; do printf '%s\n' "$project_dir/$file"; done
}
