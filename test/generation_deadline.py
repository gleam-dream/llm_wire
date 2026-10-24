"""Public consumer evidence for generation's borrowed HTTP deadline."""

import collections
import http.server
import os
import select
import subprocess
import threading
import time

counts = collections.Counter()
closed = {}
release = threading.Event()

START = b'event: response.output_item.added\ndata: {"output_index":0,"item":{"id":"m","type":"message"}}\n\n'
END = b'event: response.output_item.done\ndata: {"output_index":0,"item":{"id":"m","type":"message"}}\n\nevent: response.completed\ndata: {"response":{"id":"r","status":"completed"}}\n\n'
DELTA = b'event: response.output_text.delta\ndata: {"output_index":0,"delta":"x"}\n\n'


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        counts[self.path] += 1
        observed_close = closed[self.path] = threading.Event()
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Connection", "close")
        self.end_headers()
        delta = DELTA
        if self.path == "/usage/messages":
            initial = (
                b'event: message_start\ndata: {"message":{"id":"m","usage":{"input_tokens":4,"output_tokens":0}}}\n\n'
                b'event: content_block_start\ndata: {"index":0,"content_block":{"type":"text","text":""}}\n\n'
                b'event: content_block_delta\ndata: {"index":0,"delta":{"type":"text_delta","text":"x"}}\n\n'
                b'event: message_delta\ndata: {"delta":{},"usage":{"output_tokens":2}}\n\n'
            )
            delta = b'event: content_block_delta\ndata: {"index":0,"delta":{"type":"text_delta","text":"x"}}\n\n'
        else:
            initial = START + DELTA
        self.wfile.write(initial)
        self.wfile.flush()
        if self.path == "/release/responses":
            release.set()
        if self.path == "/default/responses":
            assert release.wait(5), (
                "consumer did not release the default-timeout response"
            )
        if self.path in {
            "/health/responses",
            "/release/responses",
            "/default/responses",
        }:
            self.wfile.write(END)
            self.wfile.flush()
            observed_close.set()
            return
        until = time.monotonic() + 3
        try:
            while time.monotonic() < until:
                ready, _, _ = select.select([self.connection], [], [], 0.04)
                if ready and self.connection.recv(1) == b"":
                    observed_close.set()
                    return
                self.wfile.write(delta)
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            observed_close.set()

    def log_message(self, *_args):
        pass


with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run(
            ["gleam", "run", "-m", "deadline_http_checks"],
            cwd="examples/consumer",
            env={
                **os.environ,
                "LLM_WIRE_RETRY_TEST_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
            },
            check=True,
            timeout=30,
        )
        assert counts == {
            "/outer/responses": 1,
            "/own/responses": 1,
            "/infinite/responses": 1,
            "/usage/messages": 1,
            "/default/responses": 1,
            "/release/responses": 1,
            "/health/responses": 1,
        }, counts
        assert all(event.wait(2) for event in closed.values()), (
            "HTTP stream was not closed"
        )
        print(
            "Generation respected both deadline orders and Infinity, lifted the relative default and released HTTP."
        )
    finally:
        server.shutdown()
        thread.join()
