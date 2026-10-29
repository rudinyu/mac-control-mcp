import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest

SERVER = os.environ.get(
    "MAC_EXEC_SERVER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "mac-exec-mcp"),
)
IMAGE = os.environ.get("MAC_EXEC_IMAGE", "mac-exec-sandbox:latest")
PROJECT = os.path.realpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# Docker runtimes that run in a VM, such as Colima, share only some Mac folders with it; Colima shares
# the home folder but not the system temporary folder, so test folders live under the home folder.
# Set MAC_EXEC_TEST_TMPDIR to use another folder that the Docker VM can see.
TEST_ROOT = os.path.realpath(os.path.expanduser(os.environ.get("MAC_EXEC_TEST_TMPDIR", "~/.cache/mac-exec-tests")))


def make_temp(prefix):
    # Each test removes its own folder; the parent stays so concurrent runs can share it.
    os.makedirs(TEST_ROOT, mode=0o700, exist_ok=True)
    return tempfile.mkdtemp(prefix=prefix, dir=TEST_ROOT)


def alive(pid, wait=3):
    # A killed process can stay a zombie for a moment until it is reaped, so poll before deciding.
    deadline = time.monotonic() + wait
    while True:
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            pass  # it exists but belongs to someone else
        if time.monotonic() >= deadline:
            return True
        time.sleep(0.1)


def docker_ready():
    docker = shutil.which("docker") or "/usr/local/bin/docker"
    try:
        return subprocess.run([docker, "image", "inspect", IMAGE], capture_output=True, timeout=30).returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


class Server:
    def __init__(self, **env):
        self.temp = make_temp("mac-exec-test-")
        self.workspace = os.path.join(self.temp, "workspace")
        self.audit = os.path.join(self.temp, "audit", "audit.log")
        environment = dict(os.environ, MAC_EXEC_WORKSPACE=self.workspace, MAC_EXEC_AUDIT_LOG=self.audit)
        environment.pop("MAC_EXEC_ALLOW_HOST", None)
        environment.update(env)
        self.process = subprocess.Popen([SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1, env=environment)
        self.next_id = 0
        # The server creates the workspace while starting; wait until it answers.
        self.request("ping")

    def request(self, method, params=None):
        self.next_id += 1
        message = {"jsonrpc": "2.0", "id": self.next_id, "method": method}
        if params is not None:
            message["params"] = params
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()
        response = json.loads(self.process.stdout.readline())
        assert response["id"] == self.next_id
        return response

    def call(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})["result"]
        return result.get("isError", False), result["content"][0]["text"]

    def ok(self, name, **arguments):
        is_error, text = self.call(name, **arguments)
        assert not is_error, text
        return json.loads(text)

    def tool_names(self):
        return {tool["name"] for tool in self.request("tools/list")["result"]["tools"]}

    def audit_entries(self):
        with open(self.audit, encoding="utf-8") as f:
            return [json.loads(line) for line in f]

    def close(self):
        self.process.stdin.close()
        self.process.wait(timeout=10)
        self.process.stdout.close()
        self.process.stderr.close()
        shutil.rmtree(self.temp)


class ProtocolAndFileTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()

    def tearDown(self):
        self.server.close()

    def test_tools_and_host_exec_off_by_default(self):
        self.assertEqual(self.server.request("initialize", {"protocolVersion": "2025-11-25"})["result"]["serverInfo"]["name"], "mac-exec")
        self.assertEqual(self.server.tool_names(),
                         {"exec_status", "sandbox_exec", "sandbox_read_file", "sandbox_write_file", "sandbox_list"})
        is_error, text = self.server.call("host_exec", command="echo hi", reason="testing that it is off")
        self.assertTrue(is_error)
        self.assertIn("turned off", text)

    def test_workspace_is_created_and_reported(self):
        status = self.server.ok("exec_status")
        self.assertEqual(os.path.realpath(status["workspace"]), os.path.realpath(self.server.workspace))
        self.assertTrue(os.path.isdir(self.server.workspace))
        self.assertFalse(status["host_exec_enabled"])

    def test_file_round_trip(self):
        written = self.server.ok("sandbox_write_file", path="notes/a.txt", content="中文 line\n")
        self.assertEqual(written["path"], "/workspace/notes/a.txt")
        self.server.ok("sandbox_write_file", path="/workspace/notes/a.txt", content="more\n", append=True)
        self.assertEqual(self.server.ok("sandbox_read_file", path="notes/a.txt")["content"], "中文 line\nmore\n")
        entries = self.server.ok("sandbox_list", path="notes")["entries"]
        self.assertEqual([(e["name"], e["type"]) for e in entries], [("a.txt", "file")])

    def test_paths_cannot_leave_the_workspace(self):
        outside = os.path.join(self.server.temp, "outside.txt")
        with open(outside, "w", encoding="utf-8") as f:
            f.write("secret")
        os.symlink(self.server.temp, os.path.join(self.server.workspace, "escape"))
        attempts = ["../outside.txt", "/workspace/../outside.txt", outside, "~/outside.txt",
                    "escape/outside.txt", "notes/../../outside.txt", "/etc/passwd"]
        for path in attempts:
            for tool, extra in (("sandbox_read_file", {}), ("sandbox_write_file", {"content": "x"}), ("sandbox_list", {})):
                with self.subTest(path=path, tool=tool):
                    is_error, text = self.server.call(tool, path=path, **extra)
                    self.assertTrue(is_error, text)
        with open(outside, encoding="utf-8") as f:
            self.assertEqual(f.read(), "secret")

    def test_invalid_arguments(self):
        calls = [
            ("sandbox_exec", {"command": ""}),
            ("sandbox_exec", {"command": "true", "timeout_seconds": 0}),
            ("sandbox_exec", {"command": "true", "timeout_seconds": 601}),
            ("sandbox_exec", {"command": "true", "timeout_seconds": True}),
            ("sandbox_exec", {"command": "true", "cwd": "../"}),
            ("sandbox_exec", {"command": "x" * 20_001}),
            ("sandbox_read_file", {"path": "missing.txt"}),
            ("sandbox_write_file", {"path": "a.txt"}),
        ]
        for name, arguments in calls:
            with self.subTest(name=name, arguments=str(arguments)[:60]):
                self.assertTrue(self.server.call(name, **arguments)[0])

    def test_utf8_is_not_split_at_the_limit(self):
        self.server.ok("sandbox_write_file", path="zh.txt", content="中文字")  # 3 bytes per character
        for limit, expected in ((1, ""), (3, "中"), (4, "中"), (5, "中"), (6, "中文"), (9, "中文字")):
            with self.subTest(limit=limit):
                result = self.server.ok("sandbox_read_file", path="zh.txt", max_bytes=limit)
                self.assertEqual(result["content"], expected)
                self.assertEqual(result["truncated"], limit < 9)

    def test_symlinked_folders_are_not_followed_for_writes(self):
        outside = os.path.join(self.server.temp, "outside")
        os.makedirs(outside)
        os.symlink(outside, os.path.join(self.server.workspace, "link"))
        for path in ("link/new.txt", "link"):
            with self.subTest(path=path):
                self.assertTrue(self.server.call("sandbox_write_file", path=path, content="x")[0])
        self.assertEqual(os.listdir(outside), [])

    def test_listing_is_capped(self):
        folder = os.path.join(self.server.workspace, "many")
        os.makedirs(folder)
        for i in range(600):
            open(os.path.join(folder, f"f{i:04}"), "w").close()
        result = self.server.ok("sandbox_list", path="many")
        self.assertEqual(len(result["entries"]), 500)
        self.assertTrue(result["truncated"])

    def test_append_and_nested_folders(self):
        self.server.ok("sandbox_write_file", path="a/b/c/log.txt", content="one\n")
        self.server.ok("sandbox_write_file", path="a/b/c/log.txt", content="two\n", append=True)
        self.assertEqual(self.server.ok("sandbox_read_file", path="a/b/c/log.txt")["content"], "one\ntwo\n")

    def test_links_are_listed_as_links(self):
        os.symlink("/etc", os.path.join(self.server.workspace, "etc-link"))
        entries = self.server.ok("sandbox_list")["entries"]
        self.assertEqual([(e["name"], e["type"]) for e in entries], [("etc-link", "link")])
        self.assertTrue(self.server.call("sandbox_list", path="etc-link")[0])

    def test_fifos_are_refused_without_blocking(self):
        os.mkfifo(os.path.join(self.server.workspace, "pipe"))
        started = time.monotonic()
        for tool, extra in (("sandbox_read_file", {}), ("sandbox_write_file", {"content": "x", "append": True}),
                            ("sandbox_write_file", {"content": "x"})):
            with self.subTest(tool=tool, extra=extra):
                is_error, text = self.server.call(tool, path="pipe", **extra)
                self.assertTrue(is_error, text)
                self.assertIn("not a regular file", text)
        self.assertLess(time.monotonic() - started, 5)

    def test_sensitive_workspace_is_refused(self):
        server = Server(MAC_EXEC_WORKSPACE="~/.ssh")
        try:
            status = server.ok("exec_status")
            self.assertTrue(any(".ssh" in problem for problem in status["problems"]))
            is_error, text = server.call("sandbox_list")
            self.assertTrue(is_error)
            self.assertIn("cannot be used", text)
        finally:
            server.close()


class SettingsTests(unittest.TestCase):
    def check_refused(self, expected, **env):
        server = Server(**env)
        try:
            problems = server.ok("exec_status")["problems"]
            self.assertTrue(any(expected in problem for problem in problems), problems)
            self.assertTrue(server.call("sandbox_list")[0])
        finally:
            server.close()

    def test_workspace_with_a_comma_is_refused(self):
        self.check_refused("comma", MAC_EXEC_WORKSPACE=os.path.join(tempfile.gettempdir(), "a,readonly"))

    def test_workspace_inside_the_project_is_refused(self):
        self.check_refused("overlaps", MAC_EXEC_WORKSPACE=os.path.join(PROJECT, "tests"))

    def test_workspace_containing_the_project_is_refused(self):
        self.check_refused("overlaps", MAC_EXEC_WORKSPACE=os.path.dirname(PROJECT))

    def test_unknown_runtime_is_reported(self):
        server = Server(MAC_EXEC_RUNTIME="podman")
        try:
            status = server.ok("exec_status")
            self.assertTrue(any("MAC_EXEC_RUNTIME" in problem for problem in status["problems"]), status["problems"])
            self.assertIsNone(status["runtime"])
        finally:
            server.close()

    def test_sensitive_read_only_folders_are_refused(self):
        for folder in ("~", "~/.ssh", "~/Library", "~/.claude"):
            with self.subTest(folder=folder):
                self.check_refused("MAC_EXEC_READONLY_DIRS", MAC_EXEC_READONLY_DIRS=folder)


class HostExecTests(unittest.TestCase):
    def setUp(self):
        self.server = Server(MAC_EXEC_ALLOW_HOST="1")

    def tearDown(self):
        self.server.close()

    def test_host_exec_runs_and_is_audited(self):
        self.assertIn("host_exec", self.server.tool_names())
        result = self.server.ok("host_exec", command="echo host-ok", reason="testing host execution")
        self.assertEqual(result["exit_code"], 0)
        self.assertEqual(result["stdout"].strip(), "host-ok")
        events = [(e["tool"], e["event"]) for e in self.server.audit_entries()]
        self.assertEqual(events, [("host_exec", "start"), ("host_exec", "end")])
        self.assertEqual(self.server.audit_entries()[0]["reason"], "testing host execution")

    def test_audit_names_the_client(self):
        self.server.request("initialize", {"protocolVersion": "2025-11-25", "clientInfo": {"name": "test-client\n", "version": "1"}})
        self.server.ok("host_exec", command="echo hi", reason="testing the client name")
        self.assertEqual({e.get("client") for e in self.server.audit_entries()}, {"test-client"})

    def test_host_exec_refusals(self):
        for arguments in ({"command": "echo hi"}, {"command": "echo hi", "reason": "short"},
                          {"command": "sudo ls", "reason": "needs admin rights"},
                          {"command": "echo a; su root", "reason": "needs admin rights"}):
            with self.subTest(arguments=arguments):
                self.assertTrue(self.server.call("host_exec", **arguments)[0])
        self.assertFalse(os.path.exists(self.server.audit))

    def test_host_exec_timeout_kills_every_process(self):
        pid_file = os.path.join(self.server.temp, "child.pid")
        result = self.server.ok("host_exec", command=f"sleep 300 & echo $! > '{pid_file}'; sleep 30",
                                reason="testing the timeout", timeout_seconds=1)
        self.assertTrue(result["timed_out"])
        self.assertLess(result["duration_ms"], 10_000)
        with open(pid_file) as f:
            self.assertFalse(alive(int(f.read())), "a child of the timed-out command is still running")

    def test_host_exec_cwd_and_quoting(self):
        folder = os.path.join(self.server.temp, "dir with 'quote\" and space")
        os.makedirs(folder)
        result = self.server.ok("host_exec", command='pwd -P; printf "%s\\n" "a  b"', cwd=folder, reason="testing the working folder")
        self.assertEqual(result["stdout"].split("\n")[:2], [os.path.realpath(folder), "a  b"])

    def test_background_processes_do_not_outlive_the_command(self):
        result = self.server.ok("host_exec", command="sleep 300 & echo $!", reason="testing leftover processes")
        self.assertEqual(result["exit_code"], 0)
        self.assertFalse(alive(int(result["stdout"].strip())))

    def test_output_is_capped(self):
        result = self.server.ok("host_exec", command="head -c 300000 /dev/zero | tr '\\0' a", reason="testing the output limit")
        self.assertTrue(result["output_truncated"])
        self.assertEqual(len(result["stdout"]), 100_000)

    def test_nothing_runs_when_the_audit_log_cannot_be_written(self):
        marker = os.path.join(self.server.temp, "ran")
        server = Server(MAC_EXEC_ALLOW_HOST="1", MAC_EXEC_AUDIT_LOG="/dev/null/audit.log")
        try:
            is_error, text = server.call("host_exec", command=f"touch '{marker}'", reason="testing audit failures")
            self.assertTrue(is_error)
            self.assertIn("audit log", text)
            self.assertFalse(os.path.exists(marker))
        finally:
            server.close()


@unittest.skipUnless(docker_ready(), "Docker or the mac-exec-sandbox image is not available")
class SandboxTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()

    def tearDown(self):
        self.server.close()

    def test_runs_as_unprivileged_user_with_read_only_system(self):
        result = self.server.ok("sandbox_exec", command=(
            "id -u; "
            "touch /etc/probe 2>/dev/null && echo etc-writable || echo etc-readonly; "
            "touch /tmp/probe && echo tmp-writable; "
            "grep CapEff /proc/self/status | awk '{print $2}'"))
        self.assertEqual(result["exit_code"], 0, result["stderr"])
        self.assertEqual(result["stdout"].split(), ["1000", "etc-readonly", "tmp-writable", "0000000000000000"])

    def test_workspace_is_shared_and_cwd_applies(self):
        self.server.ok("sandbox_write_file", path="sub/in.txt", content="from host")
        result = self.server.ok("sandbox_exec", command="pwd; cat in.txt; echo from-sandbox > out.txt", cwd="sub")
        self.assertEqual(result["stdout"].split("\n")[:2], ["/workspace/sub", "from host"])
        self.assertEqual(self.server.ok("sandbox_read_file", path="sub/out.txt")["content"], "from-sandbox\n")

    def test_home_folder_is_not_visible(self):
        home = os.path.expanduser("~")
        result = self.server.ok("sandbox_exec", command=f"ls {home} 2>&1; ls /Users 2>&1; echo done")
        self.assertIn("No such file or directory", result["stdout"])
        self.assertTrue(result["stdout"].strip().endswith("done"))

    def test_timeout_stops_the_container(self):
        result = self.server.ok("sandbox_exec", command="sleep 60", timeout_seconds=2)
        self.assertTrue(result["timed_out"])
        docker = shutil.which("docker") or "/usr/local/bin/docker"
        running = subprocess.run([docker, "ps", "-q", "--filter", "label=mac-exec=1"], capture_output=True, text=True).stdout
        self.assertEqual(running.strip(), "")

    def test_read_only_folders_are_mounted_read_only(self):
        shared = make_temp("mac-exec-ro-")
        try:
            with open(os.path.join(shared, "data.txt"), "w", encoding="utf-8") as f:
                f.write("shared")
            server = Server(MAC_EXEC_READONLY_DIRS=shared)
            try:
                name = os.path.basename(shared)
                result = server.ok("sandbox_exec", command=(
                    f"cat /mnt/readonly/{name}/data.txt; echo; "
                    f"touch /mnt/readonly/{name}/new 2>/dev/null && echo writable || echo read-only"))
                self.assertEqual(result["stdout"].split(), ["shared", "read-only"])
                self.assertFalse(os.path.exists(os.path.join(shared, "new")))
            finally:
                server.close()
        finally:
            shutil.rmtree(shared)

    def test_commands_are_audited(self):
        self.server.ok("sandbox_exec", command="echo audited")
        entries = self.server.audit_entries()
        self.assertEqual([(e["tool"], e["event"]) for e in entries], [("sandbox_exec", "start"), ("sandbox_exec", "end")])
        self.assertEqual(entries[0]["command"], "echo audited")
        self.assertEqual(entries[1]["exit_code"], 0)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SERVER = sys.argv[1]
    unittest.main(argv=[sys.argv[0]], verbosity=2)
