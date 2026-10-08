"""Local HTTP evidence for the separate consumer's retry deadline."""

import collections
import http.server
import os
import select
import subprocess
import threading
import time


counts = collections.Counter()
closed = threading.Event()


class Handler(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        self.rfile.read(int(self.headers["Content-Length"]))
        counts[self.path] += 1
        if self.path == "/slow/responses":
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(
                b'event: response.output_item.added\ndata: {"output_index":0,"item":{"id":"m","type":"message"}}\n\n'
            )
            self.wfile.flush()
            # Progress must not renew the application's absolute deadline.
            until = time.monotonic() + 3
            try:
                while time.monotonic() < until:
                    ready, _, _ = select.select([self.connection], [], [], 0.04)
                    if ready and self.connection.recv(1) == b"":
                        closed.set()
                        break
                    self.wfile.write(
                        b'event: response.output_text.delta\ndata: {"output_index":0,"delta":"x"}\n\n'
                    )
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                closed.set()
        elif self.path == "/delayed-failure/responses":
            time.sleep(0.25)
            self.send_response(503)
            self.send_header("Content-Length", "0")
            self.end_headers()
        else:
            self.send_error(404)

    def log_message(self, *_args):
        pass


with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        subprocess.run(
            ["gleam", "run", "-m", "retry_deadline_checks"],
            cwd="examples/consumer",
            env={
                **os.environ,
                "LLM_WIRE_RETRY_TEST_ENDPOINT": f"http://127.0.0.1:{server.server_port}",
            },
            check=True,
            timeout=20,
        )
        assert closed.wait(1), "deadline did not close the active HTTP stream"
        assert counts == {
            "/slow/responses": 1,
            "/delayed-failure/responses": 1,
        }, counts
        print("Retry deadline closed HTTP; elapsed attempt time prevented retry.")
    finally:
        server.shutdown()
        thread.join()
