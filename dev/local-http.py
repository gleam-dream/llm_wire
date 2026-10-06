#!/usr/bin/env python3
"""Verified local H2 and simultaneous LLM consumers. Never uses provider endpoints.

Local-server pattern inspired by Apache-2.0 HTTP Gun; provenance in
docs/evidence/http-gun/donor-source.json. Logs are bounded; counts cover all lines.
"""

import argparse
import hashlib
import os
import platform
import sys
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import time

ROOT = Path(__file__).resolve().parent.parent


def output_directory(selected=None):
    output = (
        Path(selected)
        if selected is not None
        else ROOT
        / "build/local-http"
        / (time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}")
    )
    output = output.resolve()
    output.mkdir(parents=True, exist_ok=False)
    return output


def provenance(output):
    def command(*args, cwd=ROOT):
        return subprocess.check_output(args, cwd=cwd, text=True, timeout=10).strip()

    def revision(directory):
        checkout = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            cwd=directory,
            capture_output=True,
            text=True,
            timeout=10,
        )
        # Downstream qualification also runs exported source copies. A parent
        # checkout must not be attributed to the copied package.
        if (
            checkout.returncode
            or Path(checkout.stdout.strip()).resolve() != directory.resolve()
        ):
            return {"commit": None, "dirty": None}
        return {
            "commit": command("git", "rev-parse", "HEAD", cwd=directory),
            "dirty": bool(command("git", "status", "--porcelain", cwd=directory)),
        }

    receipt = {
        "source": revision(ROOT),
        "siblings": {
            name: revision(ROOT.parent / name)
            for name in ("json_blueprint", "sinal", "http_gun")
        },
        "lockfiles": {
            name: hashlib.sha256((ROOT / name).read_bytes()).hexdigest()
            for name in (
                "flake.lock",
                "manifest.toml",
                "examples/consumer/manifest.toml",
            )
        },
        "runtime": {
            "gleam": command("gleam", "--version"),
            "otp": command(
                "erl",
                "+S",
                "1:1",
                "-noshell",
                "-eval",
                'io:format("~s", [erlang:system_info(otp_release)]), halt().',
            ),
            "python": sys.version.split()[0],
            "nghttpd": command("nghttpd", "--version"),
            "os": platform.system(),
            "architecture": platform.machine(),
        },
    }
    (output / "provenance.json").write_text(json.dumps(receipt, indent=2) + "\n")


def validate_receipt(receipt):
    rows = receipt["results"]
    expected = {
        ("h2_cancel_sibling", None),
        *(("simultaneous", callers) for callers in (1, 10, 100, 1000)),
    }
    actual = [(row["scenario"], row.get("callers")) for row in rows]
    if len(actual) != len(expected) or set(actual) != expected:
        raise ValueError("Missing, duplicate or unexpected local HTTP scenarios")
    for row in rows:
        if row["scenario"] == "simultaneous":
            if row["failures"] != 0 or row["connections"] != 1:
                raise ValueError(
                    "Local simultaneous calls failed or lost shared-connection evidence"
                )
        elif row["healthy_text_bytes"] != 2097152 or row["cancelled"] is not True:
            raise ValueError("Cancelled stream did not preserve its healthy sibling")
    if receipt["consumer_exit"] != 0:
        raise ValueError("Local consumer failed")
    if (
        len(receipt["request_connection_ids"]) != 1
        or receipt["h2_selected"] != 1
        or receipt["rst_stream"] < 2
        or receipt["request_headers"] != 1116
    ):
        raise ValueError("Local HTTP transport evidence is incomplete")


def main(output=None):
    evidence = output_directory(output)
    provenance(evidence)
    with tempfile.TemporaryDirectory(prefix="llm-wire-nghttpd-") as directory:
        root = Path(directory)
        (root / "small.sse").write_text(
            "event: text\ndata: hello\n\nevent: done\ndata: {}\n\n"
        )
        (root / "long.sse").write_text(
            ("event: text\ndata: " + "x" * 1024 + "\n\n") * 2048
            + "event: done\ndata: {}\n\n"
        )
        (root / "mime.types").write_text("text/event-stream sse\n")
        with socket.socket() as reserve:
            reserve.bind(("127.0.0.1", 0))
            port = reserve.getsockname()[1]
        command = [
            "nghttpd",
            "-a",
            "127.0.0.1",
            "-v",
            "-m",
            "8",
            "-d",
            str(root),
            "--mime-types-file=" + str(root / "mime.types"),
            str(port),
            str(ROOT / "test/fixtures/loopback-test.key"),
            str(ROOT / "test/fixtures/loopback-test.crt"),
        ]
        server = subprocess.Popen(
            command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT
        )
        captured = bytearray()
        digest = hashlib.sha256()
        connections = set()
        counts = {"rst_stream": 0, "request_headers": 0, "h2_selected": 0}

        def observe():
            for line in server.stdout:
                digest.update(line)
                if len(captured) < 262144:
                    captured.extend(line[: 262144 - len(captured)])
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
                    with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                        break
                except OSError:
                    if time.monotonic() > end:
                        raise
                    time.sleep(0.02)
            (ROOT / "build").mkdir(exist_ok=True)
            (ROOT / "build/http-gun-local-port").write_text(str(port))
            consumer = subprocess.run(
                ["gleam", "run", "-m", "llm_wire_local_gate"],
                cwd=ROOT,
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                timeout=240,
            )
            (evidence / "local-http.log").write_text(consumer.stdout)
            print(consumer.stdout, end="")
        finally:
            server.terminate()
            server.wait(timeout=5)
            observer.join(timeout=5)
            (evidence / "nghttpd-prefix.log").write_bytes(captured)
        rows = [
            json.loads(line)
            for line in consumer.stdout.splitlines()
            if line.startswith('{"scenario"')
        ]
        receipt = {
            "command": "python3 dev/local-http.py",
            "peer_max_streams": 8,
            "client_connections": 1,
            "client_active": 2048,
            "client_waiting": 2048,
            "pool_timeout_seconds": 30,
            "slow_stream_bytes": 2097152,
            "sampling_interval_ms": 10,
            "log_prefix_limit": 262144,
            "log_sha256": digest.hexdigest(),
            "request_connection_ids": sorted(connections),
            **counts,
            "results": rows,
            "consumer_exit": consumer.returncode,
        }
        (evidence / "local-http.json").write_text(json.dumps(receipt, indent=2) + "\n")
        validate_receipt(receipt)
        print(
            "Verified TLS H2: one connection, cancelled streams and healthy siblings, 1/10/100/1000 simultaneous callers."
        )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--output", type=Path, default=os.environ.get("LLM_WIRE_HTTP_OUTPUT")
    )
    main(parser.parse_args().output)
