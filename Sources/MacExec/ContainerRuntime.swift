import Foundation

// The program that runs sandbox containers. Docker covers Docker Desktop, Colima, and OrbStack;
// Apple's `container` runs each container in its own lightweight VM on Apple silicon.
enum RuntimeKind: String {
    case docker
    case apple
}

// What a sandbox command needs, independent of the runtime.
struct SandboxRun {
    let name: String
    let image: String
    let workspace: String                         // host folder, symbolic links resolved
    let readOnly: [(source: String, target: String)]
    let workdir: String                            // path inside the container
    let command: String
}

struct RuntimeFailure: Error, CustomStringConvertible {
    let description: String
}

struct ContainerRuntime {
    let kind: RuntimeKind
    let program: String
    let environment: [String: String]

    // Arguments for `run`. Both runtimes get a non-root user, a read-only system, no capabilities,
    // memory and CPU limits, and only the workspace mounted read-write.
    func runArguments(_ run: SandboxRun) throws -> [String] {
        // --mount is a comma-separated list of key=value options, so a comma or line break in a path would
        // add options. mountRejection refuses such folders earlier; this check keeps that true here too.
        for path in [run.workspace, run.workdir] + run.readOnly.flatMap({ [$0.source, $0.target] }) {
            if path.contains(",") || path.contains("\n") || path.contains("\r") {
                throw RuntimeFailure(description: "\(path) contains a comma or line break, which cannot be passed to the container runtime safely.")
            }
        }
        var arguments = ["run", "--rm", "--init", "--name", run.name, "--label", "mac-exec=1",
                         "--user", "1000:1000", "--read-only"]
        switch kind {
        case .docker:
            arguments += [
                "--tmpfs", "/tmp:rw,nosuid,nodev,size=512m",
                "--tmpfs", "/home/agent:rw,nosuid,nodev,size=256m,uid=1000,gid=1000",
                "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                "--pids-limit", "256", "--memory", "2g", "--memory-swap", "2g", "--cpus", "2",
                "--network", "bridge",
            ]
        case .apple:
            // Apple's runtime has no no-new-privileges or process limit, and its --tmpfs takes only a
            // path, so the home folder lives under /tmp and is created before the command runs. The
            // VM around each container is the main boundary.
            arguments += [
                "--tmpfs", "/tmp",
                "--cap-drop", "ALL", "--memory", "2g", "--cpus", "2",
                "--env", "HOME=/tmp/home",
                "--env", "NPM_CONFIG_PREFIX=/tmp/home/.npm-global",
                "--env", "PATH=/tmp/home/.local/bin:/tmp/home/.npm-global/bin:/usr/local/bin:/usr/bin:/bin",
            ]
        }
        arguments += ["--mount", "type=bind,source=\(run.workspace),target=/workspace"]
        for mount in run.readOnly {
            arguments += ["--mount", "type=bind,source=\(mount.source),target=\(mount.target),readonly"]
        }
        arguments += ["--workdir", run.workdir, run.image]
        switch kind {
        case .docker:
            arguments += ["bash", "-c", run.command]
        case .apple:
            // The command is passed as an argument, never pasted into the script.
            arguments += ["bash", "-c", #"mkdir -p "$HOME" && eval "$1""#, "bash", run.command]
        }
        return arguments
    }

    func killArguments(_ name: String) -> [String] { ["kill", name] }

    func imageExistsArguments(_ image: String) -> [String] {
        switch kind {
        case .docker: return ["image", "inspect", "--format", "{{.Id}}", image]
        case .apple: return ["image", "inspect", image]
        }
    }

    // Sandbox containers run with --rm, so removing MacControl only needs to delete the image.
    func removeImageArguments(_ image: String) -> [String] {
        switch kind {
        case .docker: return ["image", "rm", "--force", image]
        case .apple: return ["image", "delete", image]
        }
    }

    func buildArguments(image: String, context: String) -> [String] {
        switch kind {
        case .docker: return ["build", "--pull", "-t", image, context]
        case .apple: return ["build", "-t", image, context]
        }
    }

    // A quick call that succeeds only when the runtime is ready to start containers.
    func readyArguments() -> [String] {
        switch kind {
        case .docker: return ["info", "--format", "{{.ServerVersion}}"]
        case .apple: return ["system", "status"]
        }
    }

    // Recognizes a run that failed because the image has not been built.
    func isMissingImage(_ result: RunResult, image: String) -> Bool {
        switch kind {
        case .docker:
            // docker run exits with 125 when it cannot start the container at all.
            return result.exitCode == 125
                && (result.stderr.contains("Unable to find image") || result.stderr.contains("No such image"))
        case .apple:
            return result.exitCode != 0 && result.stderr.lowercased().contains("not found") && result.stderr.contains(image)
        }
    }

    // The runtime named by MAC_EXEC_RUNTIME, or nil for a value that is not a known runtime, so a typo
    // is reported instead of silently using Docker.
    static func requestedKind(_ env: [String: String]) -> RuntimeKind? {
        RuntimeKind(rawValue: env["MAC_EXEC_RUNTIME"] ?? RuntimeKind.docker.rawValue)
    }

    // MCP clients such as Claude Desktop start servers with a short PATH, so look in the usual places too.
    static func find(_ env: [String: String]) -> ContainerRuntime? {
        guard let kind = requestedKind(env) else { return nil }
        let name = kind == .docker ? "docker" : "container"
        let explicit = env[kind == .docker ? "MAC_EXEC_DOCKER" : "MAC_EXEC_CONTAINER"]
        let candidates = (explicit.map { [$0] } ?? []) + (env["PATH"] ?? "").split(separator: ":").map { "\($0)/\(name)" } + (kind == .docker
            ? ["/usr/local/bin/docker", "/opt/homebrew/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker"]
            : ["/usr/local/bin/container"])
        guard let program = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return nil }
        if explicit != nil, program != explicit { return nil }

        var environment = env
        let folder = (program as NSString).deletingLastPathComponent
        environment["PATH"] = [folder, env["PATH"] ?? "", "/usr/local/bin", "/usr/bin", "/bin"]
            .filter { !$0.isEmpty }.joined(separator: ":")
        // MacControl.app runs its own Colima profile and points the server at it, so the user's
        // Docker context is left alone.
        if kind == .docker, let host = env["MAC_EXEC_DOCKER_HOST"], !host.isEmpty { environment["DOCKER_HOST"] = host }
        return ContainerRuntime(kind: kind, program: program, environment: environment)
    }
}
