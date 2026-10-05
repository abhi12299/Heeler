#!/usr/bin/env python3
"""Check Simulator discovery and capture safety without opening or touching a device."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


SPEC = importlib.util.spec_from_file_location("simulator_ui", Path(__file__).with_name("simulator-ui.py"))
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)

UDID = "11111111-1111-4111-8111-111111111111"
OTHER_UDID = "22222222-2222-4222-8222-222222222222"
RUNTIME = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
TARGET = MODULE.Simulator(UDID, "Shared name", RUNTIME, "Booted", True)


class SimulatorUITests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="heeler-simulator-ui-test-")
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)

    def test_discovery_handles_both_gui_layouts_and_effective_toolchain(self) -> None:
        for relative in ("Contents/Developer/Applications/Simulator.app",
                         "Contents/Applications/DeviceHub.app"):
            with self.subTest(relative=relative):
                bundle = self.directory / relative.split("/")[-1] / "Renamed Xcode.app"
                application = bundle / relative
                application.mkdir(parents=True)
                simctl = bundle / "Contents/Developer/usr/bin/simctl"
                listing = {"devices": {RUNTIME: [
                    {"udid": UDID, "name": "Shared name", "state": "Booted", "isAvailable": True},
                    {"udid": OTHER_UDID, "name": "Shared name", "state": "Shutdown", "isAvailable": False},
                ]}}
                calls = []

                def run(arguments, **kwargs):
                    calls.append(arguments)
                    responses = {
                        ("xcode-select", "-p"): "/another/Xcode.app/Contents/Developer",
                        ("xcrun", "--find", "simctl"): str(simctl),
                        ("xcrun", "simctl", "list", "devices", "--json"): json.dumps(listing),
                    }
                    return subprocess.CompletedProcess(arguments, 0, responses[tuple(arguments)], "")

                with patch.object(MODULE.subprocess, "run", side_effect=run):
                    inventory = MODULE.discover()
                self.assertEqual(inventory.applications, (application.resolve(),))
                self.assertEqual(inventory.devices[0], TARGET)
                self.assertFalse(inventory.devices[1].available)
                self.assertFalse(inventory.errors)
                self.assertEqual(len(calls), 3)

    def test_doctor_lists_exact_uuid_without_opening_gui_or_capturing(self) -> None:
        inventory = MODULE.Inventory("developer", "simctl", (), (TARGET,), ())
        with patch.object(MODULE, "discover", return_value=inventory), \
                patch.object(MODULE, "open_gui") as open_gui, \
                patch.object(MODULE, "capture") as capture, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(MODULE.main([]), 0)
        self.assertIn(UDID + " | Shared name | " + RUNTIME + " | Booted", output.getvalue())
        open_gui.assert_not_called()
        capture.assert_not_called()

    def test_operations_require_a_complete_uuid_before_discovery(self) -> None:
        for arguments in (["--open"], ["--capture", "out.png"],
                          ["--udid", "booted", "--open"],
                          ["--udid", "Shared name", "--open"],
                          ["--udid", UDID.replace("-", ""), "--open"], ["--overwrite"]):
            with self.subTest(arguments=arguments), \
                    patch.object(MODULE, "discover") as discover, \
                    contextlib.redirect_stderr(io.StringIO()):
                with self.assertRaises(SystemExit):
                    MODULE.main(arguments)
                discover.assert_not_called()

    def test_unavailable_target_prevents_operations(self) -> None:
        unavailable = MODULE.Simulator(UDID, "Shared name", RUNTIME, "Booted", False)
        inventory = MODULE.Inventory("developer", "simctl", (), (unavailable,), ())
        with patch.object(MODULE, "discover", return_value=inventory), \
                patch.object(MODULE, "capture") as capture, \
                contextlib.redirect_stdout(io.StringIO()):
            with self.assertRaisesRegex(RuntimeError, "unavailable"):
                MODULE.main(["--udid", UDID, "--capture", "out.png"])
            capture.assert_not_called()

    def test_capture_uses_exact_uuid_and_preserves_existing_file(self) -> None:
        output = self.directory / "capture.png"
        output.write_bytes(b"original")
        with patch.object(MODULE, "command_output") as run:
            with self.assertRaisesRegex(RuntimeError, "already exists"):
                MODULE.capture(TARGET, output, False)
            run.assert_not_called()
        self.assertEqual(output.read_bytes(), b"original")

        def screenshot(arguments):
            self.assertEqual(arguments[:-1], ["xcrun", "simctl", "io", UDID,
                                             "screenshot", "--type=png", "--mask=black"])
            Path(arguments[-1]).write_bytes(b"new screenshot")
            return ""

        with patch.object(MODULE, "command_output", side_effect=screenshot), \
                contextlib.redirect_stdout(io.StringIO()):
            MODULE.capture(TARGET, output, True)
        self.assertEqual(output.read_bytes(), b"new screenshot")

    def test_failed_capture_preserves_existing_output_even_with_overwrite(self) -> None:
        output = self.directory / "capture.png"
        output.write_bytes(b"original")

        def fail(arguments):
            Path(arguments[-1]).write_bytes(b"partial screenshot")
            raise RuntimeError("simctl disconnected")

        with patch.object(MODULE, "command_output", side_effect=fail):
            with self.assertRaisesRegex(RuntimeError, "disconnected"):
                MODULE.capture(TARGET, output, True)
        self.assertEqual(output.read_bytes(), b"original")

    def test_concurrent_output_creation_is_preserved(self) -> None:
        output = self.directory / "capture.png"

        def screenshot(arguments):
            Path(arguments[-1]).write_bytes(b"screenshot")
            output.write_bytes(b"another writer")
            return ""

        with patch.object(MODULE, "command_output", side_effect=screenshot):
            with self.assertRaises(FileExistsError):
                MODULE.capture(TARGET, output, False)
        self.assertEqual(output.read_bytes(), b"another writer")

    def test_shutdown_target_is_not_booted_for_capture(self) -> None:
        target = MODULE.Simulator(UDID, "Shared name", RUNTIME, "Shutdown", True)
        with patch.object(MODULE, "command_output") as run:
            with self.assertRaisesRegex(RuntimeError, "already Booted"):
                MODULE.capture(target, self.directory / "capture.png", False)
            run.assert_not_called()

    def test_gui_open_reports_manual_selection_without_an_undocumented_selector(self) -> None:
        application = self.directory / "DeviceHub.app"
        inventory = MODULE.Inventory("developer", "simctl", (application,), (TARGET,), ())
        with patch.object(MODULE, "command_output") as run, \
                contextlib.redirect_stdout(io.StringIO()) as output:
            MODULE.open_gui(inventory, TARGET)
        run.assert_called_once_with(["open", "-a", str(application)])
        self.assertIn("target selection is manual", output.getvalue())
        self.assertIn(UDID, output.getvalue())


if __name__ == "__main__":
    unittest.main()
