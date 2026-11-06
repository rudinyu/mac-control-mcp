"""Tests of the shared JSON-RPC transport, through a server with only test tools: ping and cancellation are handled
while a tool runs, tools run one at a time on the main thread, and a cancelled request gets no answer."""

import json
import os
import queue
import signal
import subprocess
import sys
import threading
import time
import unittest

SERVER = os.environ.get(
    "FAKE_MCP_SERVER",
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".build", "fake-mcp-server"),
)


class Server:
    def __init__(self):
        self.process = subprocess.Popen([SERVER], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1)
        self.replies = queue.Queue()
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.process.stdout:
            self.replies.put(json.loads(line))

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def call(self, request_id, tool, **arguments):
        self.send({"jsonrpc": "2.0", "id": request_id, "method": "tools/call", "params": {"name": tool, "arguments": arguments}})

    def cancel(self, request_id):
        self.send({"jsonrpc": "2.0", "method": "notifications/cancelled", "params": {"requestId": request_id}})

    def reply(self, timeout=5):
        return self.replies.get(timeout=timeout)

    def no_reply(self, timeout):
        try:
            unexpected = self.replies.get(timeout=timeout)
        except queue.Empty:
            return True
        raise AssertionError(f"unexpected reply {unexpected}")

    def close(self):
        if self.process.stdin and not self.process.stdin.closed:
            self.process.stdin.close()
        self.process.wait(timeout=10)


def text(reply):
    return reply["result"]["content"][0]["text"]


class TransportTests(unittest.TestCase):
    def setUp(self):
        self.server = Server()

    def tearDown(self):
        self.server.close()

    def test_ping_is_answered_while_a_tool_runs(self):
        self.server.call(1, "sleep", seconds=3)
        time.sleep(0.2)
        self.server.send({"jsonrpc": "2.0", "id": 2, "method": "ping"})
        # Answered before the sleep ends, not after it.
        self.assertEqual(self.server.reply()["id"], 2)
        self.assertEqual(text(self.server.reply()), "slept")

    def test_invalid_json_is_answered_while_a_tool_runs(self):
        self.server.call(1, "sleep", seconds=3)
        time.sleep(0.2)
        self.server.process.stdin.write("{not json\n")
        self.server.process.stdin.flush()
        self.assertEqual(self.server.reply()["error"]["code"], -32700)
        self.assertEqual(text(self.server.reply()), "slept")

    def test_a_cancelled_call_stops_and_gets_no_answer(self):
        self.server.call(1, "sleep", seconds=30)
        time.sleep(0.2)
        started = time.monotonic()
        self.server.cancel(1)
        self.server.call(2, "echo", text="after")
        reply = self.server.reply()
        self.assertEqual(reply["id"], 2)
        # Far sooner than the 30 seconds the sleep would take, with room for a busy machine.
        self.assertLess(time.monotonic() - started, 5)
        self.server.no_reply(0.3)

    def test_a_queued_call_that_is_cancelled_never_runs(self):
        self.server.call(1, "sleep", seconds=0.5)
        self.server.call(2, "echo", text="cancelled")
        self.server.cancel(2)
        self.server.call(3, "echo", text="kept")
        self.assertEqual(self.server.reply()["id"], 1)
        reply = self.server.reply()
        self.assertEqual(reply["id"], 3)
        self.server.no_reply(0.3)

    def test_initialize_cannot_be_cancelled(self):
        # Requests run in order, so initialize waits behind the sleep and is still queued when the cancel arrives.
        self.server.call(1, "sleep", seconds=1)
        self.server.send({"jsonrpc": "2.0", "id": 2, "method": "initialize", "params": {"protocolVersion": "2025-11-25"}})
        self.server.cancel(2)
        self.assertEqual(self.server.reply()["id"], 1)
        self.assertEqual(self.server.reply()["result"]["serverInfo"]["name"], "fake")

    def test_a_result_that_is_not_json_gets_an_error(self):
        self.server.call(1, "unencodable")
        reply = self.server.reply()
        self.assertEqual(reply["id"], 1)
        self.assertEqual(reply["error"]["code"], -32603)
        self.assertIn("could not be encoded", reply["error"]["message"])
        self.server.call(2, "echo", text="still here")
        self.assertEqual(self.server.reply()["id"], 2)

    def test_cancelling_matches_the_id_type(self):
        # "1" and 1 are different requests, so cancelling 1 leaves "1" running.
        self.server.call("1", "sleep", seconds=0.3)
        self.server.cancel(1)
        reply = self.server.reply()
        self.assertEqual(reply["id"], "1")
        self.assertEqual(text(reply), "slept")

    def test_calls_run_in_order_one_at_a_time_on_the_main_thread(self):
        self.server.call(1, "sleep", seconds=0.3)
        self.server.call(2, "echo", text="second")
        self.assertEqual(self.server.reply()["id"], 1)
        reply = self.server.reply()
        self.assertEqual(reply["id"], 2)
        report = json.loads(text(reply))
        self.assertTrue(report["main_thread"])
        self.assertEqual(report["most_running"], 1)

    def test_requests_read_before_input_ends_are_answered(self):
        self.server.call(1, "sleep", seconds=0.3)
        self.server.call(2, "echo", text="last")
        self.server.process.stdin.close()
        self.assertEqual([self.server.reply()["id"], self.server.reply()["id"]], [1, 2])
        self.assertEqual(self.server.process.wait(timeout=5), 0)


    def test_sigterm_stops_the_running_call_and_ends_the_server(self):
        self.server.call(1, "sleep", seconds=30)
        self.server.call(2, "echo", text="queued")
        time.sleep(0.2)
        started = time.monotonic()
        self.server.process.send_signal(signal.SIGTERM)
        self.assertEqual(self.server.process.wait(timeout=5), 0)
        self.assertLess(time.monotonic() - started, 5)
        # Neither the stopped call nor the queued one is answered.
        self.server.no_reply(0.3)

if __name__ == "__main__":
    if len(sys.argv) > 1:
        SERVER = sys.argv[1]
    unittest.main(argv=[sys.argv[0]], verbosity=2)
