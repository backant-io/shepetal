"""install must survive launchd's asynchronous bootout. Never calls the real launchctl.

    python3 -m unittest agent/test_run.py
"""
import subprocess
import sys
import types
import unittest
from pathlib import Path
from unittest import mock

# run.py imports the SDK at the top; the code under test does not use it.
sdk = types.ModuleType("anthropic")
sdk.lib = types.ModuleType("anthropic.lib")
sdk.lib.environments = types.ModuleType("anthropic.lib.environments")
sdk.lib.environments.EnvironmentWorker = object
sys.modules.setdefault("anthropic", sdk)
sys.modules.setdefault("anthropic.lib", sdk.lib)
sys.modules.setdefault("anthropic.lib.environments", sdk.lib.environments)
sys.path.insert(0, str(Path(__file__).parent))
import run  # noqa: E402


class FakeLaunchd:
    """bootout returns at once, but the old job stays loaded for `lag` more calls; bootstrap fails with 5 meanwhile."""

    def __init__(self, loaded=True, lag=3):
        self.loaded, self.lag, self.stopping, self.calls = loaded, lag, False, []

    def __call__(self, argv, **kw):
        verb = argv[1]
        self.calls.append(verb)
        if self.stopping:
            self.lag -= 1
            if self.lag < 0:
                self.loaded = self.stopping = False
        if verb == "bootout":
            self.stopping = self.loaded
            return subprocess.CompletedProcess(argv, 0 if self.loaded else 3, "", "")
        if verb == "print":
            return subprocess.CompletedProcess(argv, 0 if self.loaded else 113, "", "")
        if verb == "bootstrap":
            if self.loaded:
                return subprocess.CompletedProcess(argv, 5, "", "Bootstrap failed: 5: Input/output error")
            self.loaded = True
            return subprocess.CompletedProcess(argv, 0, "", "")
        raise AssertionError(argv)


class ReloadJob(unittest.TestCase):
    def reload(self, launchd, wait=30.0):
        with mock.patch.object(run.subprocess, "run", launchd), mock.patch.object(run.time, "sleep"):
            run.reload_job("gui/501", wait=wait)

    def test_waits_for_old_job_before_bootstrap(self):
        launchd = FakeLaunchd(loaded=True, lag=3)
        self.reload(launchd)
        self.assertTrue(launchd.loaded)
        self.assertEqual(launchd.calls.count("bootstrap"), 1, launchd.calls)

    def test_first_install(self):
        launchd = FakeLaunchd(loaded=False)
        self.reload(launchd)
        self.assertEqual(launchd.calls, ["bootout", "print", "bootstrap"])

    def test_old_job_never_stops_fails_loud(self):
        launchd = FakeLaunchd(loaded=True, lag=10**9)
        with mock.patch.object(run.time, "monotonic", side_effect=[0.0, 1.0, 31.0]):
            with self.assertRaises(SystemExit) as stop:
                self.reload(launchd)
        self.assertIn("still loaded", str(stop.exception))
        self.assertNotIn("bootstrap", launchd.calls)


if __name__ == "__main__":
    unittest.main()
