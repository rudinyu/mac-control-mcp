import json
import os
import subprocess
import sys
import unittest

SERVER = os.environ.get(
    "MAC_CONTROL_SERVER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "mac-control-mcp"),
)


class MCPProtocolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.process = subprocess.Popen(
            [SERVER],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            bufsize=1,
        )
        cls.next_id = 0

    @classmethod
    def tearDownClass(cls):
        cls.process.stdin.close()
        cls.process.wait(timeout=5)
        cls.process.stdout.close()
        cls.process.stderr.close()

    @classmethod
    def request(cls, method, params=None):
        cls.next_id += 1
        message = {"jsonrpc": "2.0", "id": cls.next_id, "method": method}
        if params is not None:
            message["params"] = params
        cls.process.stdin.write(json.dumps(message) + "\n")
        cls.process.stdin.flush()
        result = json.loads(cls.process.stdout.readline())
        assert result["id"] == cls.next_id
        return result

    def test_01_initialize_and_tools(self):
        response = self.request("initialize", {"protocolVersion": "2025-11-25"})
        self.assertEqual(response["result"]["protocolVersion"], "2025-11-25")
        self.assertIn("tools", response["result"]["capabilities"])

        self.process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        listed = self.request("tools/list")["result"]["tools"]
        self.assertEqual(
            {tool["name"] for tool in listed},
            {
                "mac_status", "mac_screenshot", "mac_request_screen_recording", "mac_ui_tree", "mac_record_start", "mac_record_status",
                "mac_record_stop", "mac_mouse", "mac_scroll", "mac_type_text", "mac_key",
            },
        )

    def test_02_status_reports_permissions_without_requesting_them(self):
        response = self.request("tools/call", {"name": "mac_status", "arguments": {}})
        info = json.loads(response["result"]["content"][0]["text"])
        self.assertIsInstance(info["screen_recording"], bool)
        self.assertIsInstance(info["accessibility"], bool)
        self.assertIsInstance(info["display_available"], bool)
        self.assertIsInstance(info["screen_locked"], bool)
        self.assertEqual(info["screen_locked"], info["screen_locked_reason"] is not None)
        self.assertIsInstance(info["main_display"]["width"], (int, float))

    def test_03_invalid_actions_cannot_send_input(self):
        calls = [
            ("mac_mouse", {"action": "click", "x": 0, "y": 0}),
            ("mac_scroll", {"vertical": 21}),
            ("mac_type_text", {"text": ""}),
            ("mac_key", {"key": "launchpad"}),
            ("mac_record_start", {"duration_seconds": 121}),
            ("mac_record_status", {"recording_id": "missing"}),
            ("mac_ui_tree", {"max_depth": 9}),
            ("mac_type_text", {"text": "x", "app": ""}),
            ("mac_type_text", {"text": "x", "app": "   "}),
            ("mac_type_text", {"text": "x", "app": "No Such App 7f3c"}),
            ("mac_key", {"key": "a", "app": "No Such App 7f3c"}),
            ("mac_ui_tree", {"app": 42}),
            ("mac_ui_tree", {"app": "No Such App 7f3c"}),
        ]
        for name, arguments in calls:
            with self.subTest(name=name):
                response = self.request("tools/call", {"name": name, "arguments": arguments})
                self.assertTrue(response["result"]["isError"])

    def test_04_input_tools_accept_target_app(self):
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        for name in ("mac_type_text", "mac_key", "mac_ui_tree"):
            with self.subTest(name=name):
                self.assertEqual(listed[name]["inputSchema"]["properties"]["app"]["type"], "string")

    def test_05_unknown_method_is_json_rpc_error(self):
        response = self.request("unknown/method")
        self.assertEqual(response["error"]["code"], -32601)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SERVER = sys.argv[1]
    unittest.main(argv=[sys.argv[0]], verbosity=2)
