import json
import os
import plistlib
import subprocess
import sys
import unittest

from tool_descriptions import check_output_schemas, check_structured_result, check_tool_descriptions

SERVER = os.environ.get(
    "MAC_CONTROL_SERVER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "mac-control-mcp"),
)
# The version the server reports comes from here when it is built.
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "App", "Info.plist"), "rb") as info:
    APP_VERSION = plistlib.load(info)["CFBundleShortVersionString"]


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
        self.assertEqual(response["result"]["serverInfo"]["version"], APP_VERSION)

        self.process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
        self.process.stdin.flush()
        listed = self.request("tools/list")["result"]["tools"]
        self.assertEqual(
            {tool["name"] for tool in listed},
            {
                "mac_status", "mac_screenshot", "mac_request_screen_recording", "mac_ui_tree", "mac_ax_action", "mac_find", "mac_wait", "mac_window", "mac_record_start",
                "mac_record_status", "mac_record_stop", "mac_mouse", "mac_scroll", "mac_type_text", "mac_key",
            },
        )
        check_tool_descriptions(self, listed)
        check_output_schemas(self, listed)

    def test_02_status_reports_permissions_without_requesting_them(self):
        response = self.request("tools/call", {"name": "mac_status", "arguments": {}})
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        check_structured_result(self, listed["mac_status"], response["result"])
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

    def test_07_target_app_is_checked_before_anything_else(self):
        # These fail on the app alone, before the screenshot, permission, or coordinate checks.
        for name, arguments in [
            ("mac_mouse", {"action": "click", "x": 0, "y": 0}),
            ("mac_scroll", {"vertical": 1}),
            ("mac_screenshot", {}),
        ]:
            for app, expected in [("No Such App 7f3c", "No running app"), (42, "non-empty app name")]:
                with self.subTest(name=name, app=app):
                    response = self.request("tools/call", {"name": name, "arguments": {**arguments, "app": app}})
                    self.assertTrue(response["result"]["isError"])
                    self.assertIn(expected, response["result"]["content"][0]["text"])

    def test_04_input_tools_accept_target_app(self):
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        for name in ("mac_type_text", "mac_key", "mac_ui_tree", "mac_mouse", "mac_scroll", "mac_screenshot"):
            with self.subTest(name=name):
                self.assertEqual(listed[name]["inputSchema"]["properties"]["app"]["type"], "string")

    def test_14_keyboard_window_must_be_a_window_ref(self):
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        for name, arguments in [("mac_type_text", {"text": "x"}), ("mac_key", {"key": "a"})]:
            self.assertEqual(listed[name]["inputSchema"]["properties"]["window"]["type"], "string")
            for window, expected in [
                (7, "window must be"),
                ("3.12", "3.12 is not a ref; no input was sent"),
                ("zzzzzz.1", "Unknown or expired ref zzzzzz.1"),
            ]:
                with self.subTest(name=name, window=window):
                    response = self.request("tools/call", {"name": name, "arguments": {**arguments, "window": window}})
                    self.assertTrue(response["result"]["isError"])
                    self.assertIn(expected, response["result"]["content"][0]["text"])

    def test_06_unknown_parameter_names_the_accepted_ones(self):
        response = self.request("tools/call", {"name": "mac_scroll", "arguments": {"dy": -5}})
        self.assertTrue(response["result"]["isError"])
        text = response["result"]["content"][0]["text"]
        self.assertIn("dy", text)
        self.assertIn("vertical", text)

    def test_08_ax_action_refuses_bad_arguments_and_unknown_refs(self):
        # All of these fail before Accessibility permission is checked, so they hold on any machine.
        for arguments, expected in [
            ({"ref": "1.1", "action": "launch"}, "Invalid action"),
            ({"ref": "1.1", "action": "set_value"}, "needs value"),
            ({"ref": "1.1", "action": "set_value", "value": "x" * 2001}, "up to 2000 characters"),
            ({"ref": "1.1", "action": "press", "value": "x"}, "only used with set_value"),
            ({"ref": "", "action": "press"}, "ref must be"),
            ({"ref": 7, "action": "press"}, "ref must be"),
            ({"ref": "3.12", "action": "press"}, "3.12 is not a ref; no action was sent"),
            ({"ref": "k3f9q2.0", "action": "press"}, "is not a ref"),
            ({"ref": "K3F9Q2.1", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q2.012", "action": "press"}, "is not a ref"),
            ({"ref": "3k9f2q.1", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q.1", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q2.1.1", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q2.", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q2.99999999999999999999", "action": "press"}, "is not a ref"),
            ({"ref": "k3f9q2.１", "action": "press"}, "is not a ref"),
            ({"ref": "x" * 500, "action": "press"}, "x" * 40 + "… is not a ref"),
            # The server never makes this ID before a full mac_ui_tree, and no test reads one.
            ({"ref": "zzzzzz.1", "action": "press"}, "Unknown or expired ref zzzzzz.1: snapshot zzzzzz is unknown"),
            ({"ref": "zzzzzz.1", "action": "set_value", "value": "x", "app": "No Such App 7f3c"}, "Unknown or expired ref"),
        ]:
            with self.subTest(arguments=arguments):
                response = self.request("tools/call", {"name": "mac_ax_action", "arguments": arguments})
                self.assertTrue(response["result"]["isError"])
                self.assertIn(expected, response["result"]["content"][0]["text"])

    def error_details(self, name, arguments):
        response = self.request("tools/call", {"name": name, "arguments": arguments})
        self.assertTrue(response["result"]["isError"])
        content = response["result"]["content"]
        self.assertEqual(len(content), 2)
        return json.loads(content[1]["text"])["error"]

    def test_10_errors_carry_code_delivery_and_retry(self):
        # None of these reach Accessibility, so they behave the same with or without permission.
        for name, arguments, code, retry in [
            ("mac_scroll", {"dy": -5}, "INVALID_ARGS", "fix"),
            ("no_such_tool", {}, "INVALID_ARGS", "fix"),
            ("mac_key", {"key": "launchpad"}, "INVALID_ARGS", "fix"),
            ("mac_key", {"key": "a", "app": "No Such App 7f3c"}, "APP_NOT_FOUND", "fix"),
            ("mac_ax_action", {"ref": "zzzzzz.1", "action": "press"}, "STALE_REF", "refresh"),
            ("mac_ax_action", {"ref": "3.12", "action": "press"}, "INVALID_ARGS", "fix"),
            ("mac_record_status", {"recording_id": "missing"}, "INVALID_ARGS", "fix"),
        ]:
            with self.subTest(name=name, arguments=arguments):
                details = self.error_details(name, arguments)
                self.assertEqual(details, {"code": code, "delivered": False, "retry": retry})

    def test_11_find_and_wait_refuse_bad_queries_before_reading(self):
        # All of these fail before Accessibility permission is checked.
        for name, arguments, expected in [
            ("mac_find", {}, "Give role, text, or both"),
            ("mac_find", {"role": ""}, "role must be text"),
            ("mac_find", {"text": "x" * 201}, "text must be text"),
            ("mac_find", {"text": "Save", "exact": "yes"}, "exact must be"),
            ("mac_find", {"text": "Save", "limit": 51}, "limit must be"),
            ("mac_find", {"text": "Save", "root": "zzzzzz.1"}, "replaced long ago; nothing was searched"),
            ("mac_find", {"text": "Save", "app": "No Such App 7f3c"}, "No running app"),
            ("mac_wait", {"text": "Save", "state": "gone"}, "state must be"),
            ("mac_wait", {"text": "Save", "timeout_seconds": 31}, "timeout_seconds must be"),
            ("mac_wait", {"text": "Save", "timeout_seconds": 0.1}, "timeout_seconds must be"),
            ("mac_wait", {"role": "button", "root": "zzzzzz.1"}, "Unknown or expired ref"),
            ("mac_ui_tree", {"root": "zzzzzz.1"}, "replaced long ago; nothing was read"),
            ("mac_ui_tree", {"root": ""}, "root must be a ref"),
        ]:
            with self.subTest(name=name, arguments=arguments):
                response = self.request("tools/call", {"name": name, "arguments": arguments})
                self.assertTrue(response["result"]["isError"])
                self.assertIn(expected, response["result"]["content"][0]["text"])

    def test_12_window_refuses_bad_arguments_before_reading(self):
        for arguments, expected in [
            ({"action": "close"}, "Invalid action"),
            ({"action": "move", "app": "Finder"}, "Missing or invalid x"),
            ({"action": "move", "x": 1, "y": 2, "width": 3}, "width is not used with move"),
            ({"action": "resize", "width": 0, "height": 10, "app": "Finder"}, "width is out of range"),
            ({"action": "minimize"}, "Give window"),
            ({"action": "list", "window": "1.1"}, "window is not used with list"),
            ({"action": "focus", "window": "zzzzzz.1"}, "replaced long ago; nothing was sent"),
            ({"action": "list", "app": "No Such App 7f3c"}, "No running app"),
        ]:
            with self.subTest(arguments=arguments):
                response = self.request("tools/call", {"name": "mac_window", "arguments": arguments})
                self.assertTrue(response["result"]["isError"])
                self.assertIn(expected, response["result"]["content"][0]["text"])

    def test_13_ax_action_lists_every_action(self):
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        actions = listed["mac_ax_action"]["inputSchema"]["properties"]["action"]["enum"]
        for action in ("scroll_to_visible", "select", "deselect", "expand", "collapse", "check", "uncheck"):
            self.assertIn(action, actions)
        tree = listed["mac_ui_tree"]["description"]
        for word in ("complete", "stopped_by", "element_limit", "time_limit", "app_not_answering", "unanswered", "more_children"):
            self.assertIn(word, tree)
        self.assertIn("stopped_by", listed["mac_find"]["outputSchema"]["required"])
        self.assertIn("app_not_answering", listed["mac_find"]["description"])
        self.assertIn("APP_UNRESPONSIVE", listed["mac_wait"]["description"])
        description = listed["mac_ax_action"]["description"] + listed["mac_ax_action"]["inputSchema"]["properties"]["action"]["description"]
        for word in ("delivered", "verified", "checked", "OUTCOME_UNKNOWN", "opened", "closed"):
            self.assertIn(word, description)
        response = self.request("tools/call", {"name": "mac_ax_action", "arguments": {"ref": "zzzzzz.1", "action": "check"}})
        self.assertIn("Unknown or expired ref", response["result"]["content"][0]["text"])

    def test_09_ax_action_schema(self):
        listed = {tool["name"]: tool for tool in self.request("tools/list")["result"]["tools"]}
        schema = listed["mac_ax_action"]["inputSchema"]
        self.assertEqual(schema["required"], ["ref", "action"])
        self.assertEqual(schema["properties"]["app"]["type"], "string")
        self.assertIn("set_value", schema["properties"]["action"]["enum"])

    def test_05_unknown_method_is_json_rpc_error(self):
        response = self.request("unknown/method")
        self.assertEqual(response["error"]["code"], -32601)


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SERVER = sys.argv[1]
    unittest.main(argv=[sys.argv[0]], verbosity=2)
