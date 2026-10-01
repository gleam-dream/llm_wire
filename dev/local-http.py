#!/usr/bin/env python3
"""Verified local H2 and simultaneous LLM consumers. Never uses provider endpoints.

Local-server pattern inspired by Apache-2.0 HTTP Gun; provenance in
docs/evidence/http-gun/donor-source.json. Logs are bounded; counts cover all lines.
"""
import hashlib
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent
EVIDENCE = ROOT / "docs/evidence/http-gun"


def main():
    with tempfile.TemporaryDirectory(prefix="llm-wire-nghttpd-") as directory:
        root = Path(directory)
        (root / "small.sse").write_text("event: text\ndata: hello\n\nevent: done\ndata: {}\n\n")
        (root / "long.sse").write_text(("event: text\ndata: " + "x" * 1024 + "\n\n") * 2048 + "event: done\ndata: {}\n\n")
        (root / "mime.types").write_text("text/event-stream sse\n")
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        command = ["nghttpd", "-a", "127.0.0.1", "-v", "-m", "8", "-d", str(root),
                   "--mime-types-file=" + str(root / "mime.types"), str(port),
                   str(ROOT / "test/fixtures/loopback-test.key"), str(ROOT / "test/fixtures/loopback-test.crt")]
        server = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        captured = bytearray()
        digest = hashlib.sha256()
        connections = set()
        counts = {"rst_stream": 0, "request_headers": 0, "h2_selected": 0}

        def observe():
            for line in server.stdout:
                digest.update(line)
                if len(captured) < 262144:
                    captured.extend(line[:262144 - len(captured)])
                decoded = line.decode(errors="replace")
                if "recv HEADERS frame" in decoded:
                    counts["request_headers"] += 1
                    match = re.search(r"\[id=(\d+)\]", decoded)
                    if match:
                        connections.add(match.group(1))
                if "recv RST_STREAM frame" in decoded:
                    counts["rst_stream"] += 1
                if "The negotiated protocol: h2" in decoded:
                    counts["h2_selected"] += 1

        observer = threading.Thread(target=observe, daemon=True)
        observer.start()
        try:
            end = time.monotonic() + 5
            while True:
                if server.poll() is not None:
                    raise RuntimeError("nghttpd exited before becoming ready")
                try:
                    with socket.create_connection(("127.0.0.1", port), timeout=.1):
                        break
                except OSError:
                    if time.monotonic() > end:
                        raise
                    time.sleep(.02)
            (ROOT / "build").mkdir(exist_ok=True)
            (ROOT / "build/http-gun-local-port").write_text(str(port))
            consumer = subprocess.run(["gleam", "run", "-m", "llm_wire_local_gate"], cwd=ROOT, text=True,
                                      stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=240)
            print(consumer.stdout, end="")
        finally:
            server.terminate()
            server.wait(timeout=5)
            observer.join(timeout=5)
            (EVIDENCE / "nghttpd-prefix.log").write_bytes(captured)
        rows = [json.loads(line) for line in consumer.stdout.splitlines() if line.startswith('{"scenario"')]
        receipt = {"command": "python3 dev/local-http.py", "peer_max_streams": 8,
                   "client_connections": 1, "client_active": 2048, "client_waiting": 2048,
                   "slow_stream_bytes": 2097152, "sampling_interval_ms": 10,
                   "log_prefix_limit": 262144, "log_sha256": digest.hexdigest(),
                   "request_connection_ids": sorted(connections), **counts, "results": rows,
                   "consumer_exit": consumer.returncode}
        (EVIDENCE / "local-http.json").write_text(json.dumps(receipt, indent=2) + "\n")
        assert consumer.returncode == 0, "local consumer failed"
        assert len(rows) == 5 and len(connections) == 1 and counts["h2_selected"] == 1, receipt
        assert counts["rst_stream"] >= 2 and counts["request_headers"] == 1116, receipt
        print("Verified TLS H2: one connection, cancelled streams and healthy siblings, 1/10/100/1000 simultaneous callers.")


if __name__ == "__main__":
    main()
