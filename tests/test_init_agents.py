import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

try:
    import tomllib  # Python 3.11+
except ModuleNotFoundError:  # macOS ships an older /usr/bin/python3
    tomllib = None

PROJECT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
PLACEHOLDER = "/path/to/mac-control-mcp"
OUTPUTS = [".mcp.json", "CLAUDE.md", ".codex/config.toml", "AGENTS.md"]


class InitAgentsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.mkdtemp(prefix="init agents ")
        # A space in the path checks that the script quotes paths correctly.
        self.clone = self.make_clone("my clone")

    def make_clone(self, name):
        clone = os.path.realpath(os.path.join(self.temp, name))
        os.makedirs(os.path.join(clone, "scripts"))
        shutil.copy(os.path.join(PROJECT, "scripts", "init-agents.sh"), os.path.join(clone, "scripts"))
        shutil.copytree(os.path.join(PROJECT, "examples"), os.path.join(clone, "examples"))
        return clone

    def tearDown(self):
        shutil.rmtree(self.temp)

    def run_init(self, *args, clone=None):
        return subprocess.run(
            ["sh", os.path.join(clone or self.clone, "scripts", "init-agents.sh"), *args],
            capture_output=True, text=True, timeout=30,
        )

    def assert_nothing_written(self, clone):
        for name in OUTPUTS:
            self.assertFalse(os.path.exists(os.path.join(clone, name)), name)

    def read(self, name):
        with open(os.path.join(self.clone, name), encoding="utf-8") as f:
            return f.read()

    def test_writes_every_file_with_the_clone_path(self):
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        server = os.path.join(self.clone, "scripts", "run-server.sh")
        for name in OUTPUTS:
            with self.subTest(name=name):
                self.assertNotIn(PLACEHOLDER, self.read(name))
        self.assertEqual(json.loads(self.read(".mcp.json"))["mcpServers"]["mac-control"]["args"], [server])
        exec_server = os.path.join(self.clone, "scripts", "run-exec-server.sh")
        self.assertEqual(json.loads(self.read(".mcp.json"))["mcpServers"]["mac-exec"]["args"], [exec_server])
        if tomllib:
            self.assertEqual(tomllib.loads(self.read(".codex/config.toml"))["mcp_servers"]["mac_exec"]["args"], [exec_server])

            self.assertEqual(tomllib.loads(self.read(".codex/config.toml"))["mcp_servers"]["mac_control"]["args"], [server])
        else:
            self.assertIn(f'args = ["{server}"]', self.read(".codex/config.toml"))
        # The Claude Desktop entry is printed as a complete JSON document after the instructions.
        start = result.stdout.index("\n{") + 1
        end = result.stdout.index("\n}", start) + 2
        desktop = json.loads(result.stdout[start:end])
        self.assertEqual(desktop["mcpServers"]["mac-control"]["args"], [server])

    def test_keeps_existing_files_unless_forced(self):
        path = os.path.join(self.clone, ".mcp.json")
        with open(path, "w", encoding="utf-8") as f:
            f.write("mine")
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read(".mcp.json"), "mine")
        self.assertIn("kept     .mcp.json", result.stdout)

        result = self.run_init("--force")
        self.assertEqual(result.returncode, 0, result.stderr)
        server = os.path.join(self.clone, "scripts", "run-server.sh")
        self.assertEqual(json.loads(self.read(".mcp.json"))["mcpServers"]["mac-control"]["args"], [server])
        self.assertFalse(os.path.exists(path + ".tmp"))

    def test_rejects_unknown_options(self):
        self.assertEqual(self.run_init("--bogus").returncode, 2)
        self.assert_nothing_written(self.clone)

    def test_help_writes_nothing(self):
        for flag in ("--help", "-h"):
            with self.subTest(flag=flag):
                result = self.run_init(flag)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("Usage", result.stdout)
                self.assert_nothing_written(self.clone)

    def test_rejects_paths_it_cannot_write_safely(self):
        for name in ("a&b", "a|b", 'a"b', "a\\b", "a\nb"):
            with self.subTest(name=repr(name)):
                clone = self.make_clone(name)
                result = self.run_init(clone=clone)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("cannot write safely", result.stderr)
                self.assert_nothing_written(clone)

    def test_examples_parse(self):
        for name in ("mcp.json", "claude_desktop_config.json"):
            with open(os.path.join(PROJECT, "examples", name), encoding="utf-8") as f:
                json.load(f)
        if tomllib:
            with open(os.path.join(PROJECT, "examples", "codex", "config.toml"), "rb") as f:
                tomllib.load(f)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
