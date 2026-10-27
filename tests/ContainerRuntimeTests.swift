// Unit tests for ContainerRuntime. Built with Sources/MacExec/ContainerRuntime.swift and
// ProcessRunner.swift by scripts/ci.sh. The Apple container arguments are checked here because no
// Apple silicon machine runs the sandbox tests yet.

import Foundation

private var failures = 0

private func check(_ name: String, _ condition: Bool, _ detail: @autoclosure () -> String = "") {
    if condition {
        print("ok   \(name)")
    } else {
        failures += 1
        print("FAIL \(name) \(detail())")
    }
}

private func value(after flag: String, in arguments: [String]) -> [String] {
    arguments.indices.filter { arguments[$0] == flag && $0 + 1 < arguments.count }.map { arguments[$0 + 1] }
}

@main
private enum ContainerRuntimeTests {
    static func main() {
        let run = SandboxRun(name: "mac-exec-test", image: "mac-exec-sandbox:latest", workspace: "/Users/me/AgentWorkspace",
                             readOnly: [("/Users/me/reports", "/mnt/readonly/reports")], workdir: "/workspace/sub",
                             command: "echo \"$HOME\"; ls")
        let docker = ContainerRuntime(kind: .docker, program: "/usr/local/bin/docker", environment: [:])
        let apple = ContainerRuntime(kind: .apple, program: "/usr/local/bin/container", environment: [:])

        for (label, runtime) in [("docker", docker), ("apple", apple)] {
            let arguments = (try? runtime.runArguments(run)) ?? []
            check("\(label): starts with run --rm --init", Array(arguments.prefix(3)) == ["run", "--rm", "--init"], "\(arguments)")
            check("\(label): non-root user", value(after: "--user", in: arguments) == ["1000:1000"])
            check("\(label): read-only system", arguments.contains("--read-only"))
            check("\(label): drops every capability", value(after: "--cap-drop", in: arguments) == ["ALL"])
            check("\(label): memory and CPU limits", value(after: "--memory", in: arguments) == ["2g"] && value(after: "--cpus", in: arguments) == ["2"])
            check("\(label): mounts", value(after: "--mount", in: arguments) == [
                "type=bind,source=/Users/me/AgentWorkspace,target=/workspace",
                "type=bind,source=/Users/me/reports,target=/mnt/readonly/reports,readonly",
            ], "\(value(after: "--mount", in: arguments))")
            check("\(label): working folder", value(after: "--workdir", in: arguments) == ["/workspace/sub"])
            check("\(label): labelled for cleanup", value(after: "--label", in: arguments) == ["mac-exec=1"])
            check("\(label): command is the last argument, unchanged", arguments.last == run.command)
            check("\(label): image comes right after the options", arguments.firstIndex(of: run.image).map { arguments[$0 + 1] } == "bash")
        }

        let dockerArgs = (try? docker.runArguments(run)) ?? []
        check("docker: no-new-privileges", value(after: "--security-opt", in: dockerArgs) == ["no-new-privileges"])
        check("docker: process limit", value(after: "--pids-limit", in: dockerArgs) == ["256"])
        check("docker: home folder tmpfs owned by the agent user", dockerArgs.contains("/home/agent:rw,nosuid,nodev,size=256m,uid=1000,gid=1000"))
        check("docker: bash -c command", Array(dockerArgs.suffix(3)) == ["bash", "-c", run.command])

        let appleArgs = (try? apple.runArguments(run)) ?? []
        check("apple: no Docker-only options", !appleArgs.contains("--security-opt") && !appleArgs.contains("--pids-limit") && !appleArgs.contains("--network"))
        check("apple: plain tmpfs path", value(after: "--tmpfs", in: appleArgs) == ["/tmp"])
        check("apple: home under /tmp", value(after: "--env", in: appleArgs).contains("HOME=/tmp/home"))
        check("apple: command passed as an argument to a fixed script",
              Array(appleArgs.suffix(5)) == ["bash", "-c", #"mkdir -p "$HOME" && eval "$1""#, "bash", run.command], "\(appleArgs.suffix(5))")

        for bad in ["/Users/me/a,readonly=false", "/Users/me/a\nb"] {
            let injected = SandboxRun(name: "n", image: "i", workspace: bad, readOnly: [], workdir: "/workspace", command: "true")
            check("refuses mount path \(bad.debugDescription)", (try? docker.runArguments(injected)) == nil && (try? apple.runArguments(injected)) == nil)
        }
        let injectedTarget = SandboxRun(name: "n", image: "i", workspace: "/ok", readOnly: [("/ok2", "/mnt/readonly/x,source=/etc")], workdir: "/workspace", command: "true")
        check("refuses mount target with a comma", (try? docker.runArguments(injectedTarget)) == nil)
        check("unknown MAC_EXEC_RUNTIME is not replaced by Docker", ContainerRuntime.find(["MAC_EXEC_RUNTIME": "podman", "MAC_EXEC_DOCKER": "/bin/sh"]) == nil)

        check("kill", docker.killArguments("n") == ["kill", "n"] && apple.killArguments("n") == ["kill", "n"])
        check("docker build", docker.buildArguments(image: "i", context: "/c") == ["build", "--pull", "-t", "i", "/c"])
        check("apple build", apple.buildArguments(image: "i", context: "/c") == ["build", "-t", "i", "/c"])
        check("docker ready", docker.readyArguments() == ["info", "--format", "{{.ServerVersion}}"])
        check("apple ready", apple.readyArguments() == ["system", "status"])

        let missing = RunResult(exitCode: 125, stdout: "", stderr: "Unable to find image 'mac-exec-sandbox:latest' locally", timedOut: false, truncated: false, durationMs: 1)
        check("docker: missing image recognized", docker.isMissingImage(missing, image: "mac-exec-sandbox:latest"))
        let failed = RunResult(exitCode: 1, stdout: "", stderr: "boom", timedOut: false, truncated: false, durationMs: 1)
        check("docker: ordinary failure is not a missing image", !docker.isMissingImage(failed, image: "mac-exec-sandbox:latest"))

        // Discovery: an explicit program that does not exist must not fall back to another one.
        check("explicit missing program is not replaced", ContainerRuntime.find(["MAC_EXEC_DOCKER": "/nonexistent/docker", "PATH": "/usr/bin"]) == nil)
        let host = ContainerRuntime.find(["MAC_EXEC_DOCKER": "/bin/sh", "MAC_EXEC_DOCKER_HOST": "unix:///tmp/colima.sock", "PATH": "/usr/bin"])
        check("DOCKER_HOST comes from MAC_EXEC_DOCKER_HOST", host?.environment["DOCKER_HOST"] == "unix:///tmp/colima.sock")
        check("runtime chosen by MAC_EXEC_RUNTIME", ContainerRuntime.find(["MAC_EXEC_RUNTIME": "apple", "MAC_EXEC_CONTAINER": "/bin/sh"])?.kind == .apple)

        if failures > 0 {
            print("\(failures) container runtime test(s) failed")
            exit(1)
        }
        print("All container runtime tests passed")
    }
}
