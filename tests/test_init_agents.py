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
        # A space in the path checks that the script quotes paths correctly.
        self.temp = tempfile.mkdtemp(prefix="init agents ")
        self.clone = os.path.realpath(os.path.join(self.temp, "my clone"))
        os.makedirs(os.path.join(self.clone, "scripts"))
        shutil.copy(os.path.join(PROJECT, "scripts", "init-agents.sh"), os.path.join(self.clone, "scripts"))
        shutil.copytree(os.path.join(PROJECT, "examples"), os.path.join(self.clone, "examples"))

    def tearDown(self):
        shutil.rmtree(self.temp)

    def run_init(self, *args):
        return subprocess.run(
            ["sh", os.path.join(self.clone, "scripts", "init-agents.sh"), *args],
            capture_output=True, text=True,
        )

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
        if tomllib:
            self.assertEqual(tomllib.loads(self.read(".codex/config.toml"))["mcp_servers"]["mac_control"]["args"], [server])
        else:
            self.assertIn(f'args = ["{server}"]', self.read(".codex/config.toml"))
        self.assertIn(server, result.stdout)

    def test_keeps_existing_files_unless_forced(self):
        path = os.path.join(self.clone, ".mcp.json")
        with open(path, "w") as f:
            f.write("mine")
        result = self.run_init()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read(".mcp.json"), "mine")
        self.assertIn("kept     .mcp.json", result.stdout)

        result = self.run_init("--force")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("mac-control", json.loads(self.read(".mcp.json"))["mcpServers"])

    def test_rejects_unknown_options(self):
        self.assertEqual(self.run_init("--bogus").returncode, 2)
        for name in OUTPUTS:
            self.assertFalse(os.path.exists(os.path.join(self.clone, name)))

    def test_examples_parse(self):
        for name in ("mcp.json", "claude_desktop_config.json"):
            with open(os.path.join(PROJECT, "examples", name)) as f:
                json.load(f)
        if tomllib:
            with open(os.path.join(PROJECT, "examples", "codex", "config.toml"), "rb") as f:
                tomllib.load(f)


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0]], verbosity=2)
