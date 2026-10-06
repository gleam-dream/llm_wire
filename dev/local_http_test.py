"""Counterexamples for isolated HTTP evidence and native compiler warnings."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("local_http", ROOT / "dev/local-http.py")
local_http = importlib.util.module_from_spec(spec)
spec.loader.exec_module(local_http)


class LocalEvidenceTests(unittest.TestCase):
    def test_output_is_fresh_and_outside_historical_receipts(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(local_http, "ROOT", root):
                output = local_http.output_directory()
                self.assertTrue(output.is_relative_to(root / "build"))
                with self.assertRaises(FileExistsError):
                    local_http.output_directory(output)
            selected = local_http.output_directory(root / "explicit")
            self.assertEqual(selected, root / "explicit")

    def fixture(self):
        return dict(
            results=[
                dict(
                    scenario="h2_cancel_sibling",
                    healthy_text_bytes=2097152,
                    cancelled=True,
                ),
                *(
                    dict(scenario="simultaneous", callers=n, failures=0, connections=1)
                    for n in (1, 10, 100, 1000)
                ),
            ],
            consumer_exit=0,
            request_connection_ids=["1"],
            h2_selected=1,
            rst_stream=2,
            request_headers=1116,
        )

    def test_missing_duplicate_failed_and_unhealthy_cases_are_rejected(self):
        receipt = self.fixture()
        local_http.validate_receipt(receipt)
        invalid = [
            dict(receipt, results=[]),
            dict(receipt, results=receipt["results"][:-1]),
            dict(receipt, results=receipt["results"] + receipt["results"][:1]),
            dict(receipt, consumer_exit=1),
            dict(receipt, request_headers=1115),
        ]
        unhealthy = self.fixture()
        unhealthy["results"][1]["failures"] = 1
        invalid.append(unhealthy)
        for value in invalid:
            with self.subTest(value=value), self.assertRaises(ValueError):
                local_http.validate_receipt(value)

    def test_server_start_failure_preserves_log_and_stops_server(self):
        server = Mock(stdout=[b"startup witness\n"])
        server.poll.return_value = 1
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            with (
                patch.object(local_http, "provenance"),
                patch.object(local_http.subprocess, "Popen", return_value=server),
            ):
                with self.assertRaisesRegex(RuntimeError, "before becoming ready"):
                    local_http.main(output)
            self.assertEqual(
                (output / "nghttpd-prefix.log").read_bytes(), b"startup witness\n"
            )
            server.terminate.assert_called_once()
            server.wait.assert_called_once()

    def test_native_warning_is_rejected_with_positive_control(self):
        with tempfile.TemporaryDirectory() as directory:
            source = Path(directory) / "warning_probe.erl"
            for argument, accepted in (("_Value", True), ("Unused", False)):
                source.write_text(
                    "-module(warning_probe).\n-export([value/1]).\n"
                    + f"value({argument}) -> ok.\n"
                )
                result = subprocess.run(
                    ["sh", str(ROOT / "dev/check-native"), str(source)],
                    capture_output=True,
                    text=True,
                )
                self.assertEqual(
                    result.returncode == 0, accepted, result.stdout + result.stderr
                )
                if not accepted:
                    self.assertIn("unused", result.stdout + result.stderr)

    def test_unversioned_consumer_copy_retains_provenance(self):
        with tempfile.TemporaryDirectory() as directory:
            workspace = Path(directory)
            root = workspace / "llm_wire"
            root.mkdir()
            for name in ("json_blueprint", "sinal", "http_gun"):
                (workspace / name).mkdir()
            for name in (
                "flake.lock",
                "manifest.toml",
                "examples/consumer/manifest.toml",
            ):
                lock = root / name
                lock.parent.mkdir(parents=True, exist_ok=True)
                lock.write_text("fixture lock")
            output = workspace / "evidence"
            output.mkdir()
            original = subprocess.check_output

            def version_command(*arguments, **keywords):
                if arguments[0][0] == "git":
                    return original(*arguments, **keywords)
                return "fixture version"

            with (
                patch.object(local_http, "ROOT", root),
                patch.object(
                    local_http.subprocess, "check_output", side_effect=version_command
                ),
            ):
                local_http.provenance(output)
            receipt = local_http.json.loads((output / "provenance.json").read_text())
            self.assertEqual(receipt["source"], {"commit": None, "dirty": None})
            self.assertTrue(
                all(
                    value == {"commit": None, "dirty": None}
                    for value in receipt["siblings"].values()
                )
            )
            self.assertEqual(len(receipt["lockfiles"]), 3)
