#!/usr/bin/env python3
"""Exercise a rewritten copy only: no privileges, real services, or system files."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "Scripts/uninstall.sh"
DAEMON = "system/com.nightfall.mac.daemon"
CALLER = "gui/501/com.nightfall.mac.agent"
OTHER = "gui/502/com.nightfall.mac.agent"

MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["NIGHTFALL_TEST_ROOT"])
state_file = root / "mock-state.json"
state = json.loads(state_file.read_text())
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "operations.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "dscl":
    print("mark 501\nother 502\nloggedout 503")
    sys.exit(state.get("dscl_failure", 0))
if name == "ps":
    print("\n".join(state.get("process_users", ["501", "502"])))
    sys.exit(state.get("ps_failure", 0))
if name == "launchctl":
    action, target = args
    if target in state.get("print_errors", {}) and action == "print":
        sys.exit(state["print_errors"][target])
    if action == "print":
        if target in state["loaded"] or target in state["domains"]:
            sys.exit(0)
        sys.exit(113 if target.count("/") >= 2 or target.startswith("system/") else 112)
    if action == "bootout":
        if target in state.get("disappears_during_bootout", []):
            state["loaded"].remove(target)
            state_file.write_text(json.dumps(state))
            sys.exit(113)
        if target in state.get("bootout_errors", {}):
            sys.exit(state["bootout_errors"][target])
        if target not in state.get("stuck", []):
            state["loaded"].remove(target)
        state_file.write_text(json.dumps(state))
        sys.exit(0)
if name == "rm":
    # Even a fixture rewrite bug must never let this mock touch a system path.
    for arg in args:
        if not arg.startswith("-"):
            path = pathlib.Path(arg)
            if not path.is_absolute() or not path.is_relative_to(root / "filesystem"):
                raise SystemExit("Refusing path outside test fixture: " + arg)
    sys.exit(subprocess.run(["/bin/rm", *args]).returncode)
raise SystemExit("Unexpected mock command")
'''


class UninstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="nightfall-uninstall-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.filesystem = self.root / "filesystem"
        self.targets = [
            "Library/LaunchAgents/com.nightfall.mac.agent.plist",
            "Library/LaunchDaemons/com.nightfall.mac.daemon.plist",
            "Library/PrivilegedHelperTools/com.nightfall.mac.daemon",
            "var/run/com.nightfall.mac.sock",
            "Library/Application Support/Nightfall/state.json",
            "Applications/Nightfall.app/Contents/Resources/uninstall.sh",
        ]
        for relative in self.targets:
            path = self.filesystem / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text("fixture")
        self.unrelated = self.filesystem / "Applications/Other.app/keep.txt"
        self.unrelated.parent.mkdir(parents=True)
        self.unrelated.write_text("keep")
        self.state = {
            "loaded": [DAEMON, CALLER, OTHER],
            "domains": ["gui/501", "gui/502"],
        }
        self.script = self.filesystem / self.targets[-1]
        source = SOURCE.read_text()
        guard = '[[ "$EUID" -eq 0 ]]'
        self.assertEqual(source.count(guard), 1)
        source = source.replace(guard, "[[ 1 -eq 1 ]]")
        for tool, executable in (("launchctl", "/bin/launchctl"), ("dscl", "/usr/bin/dscl"),
                                 ("ps", "/bin/ps"), ("rm", "/bin/rm")):
            path = self.root / tool
            path.write_text(MOCK)
            path.chmod(0o755)
            source = source.replace(executable, str(path))
        for prefix in ("/Library/", "/Applications/", "/var/run/"):
            source = source.replace(prefix, str(self.filesystem) + prefix)
        self.script.write_text(source)

    def run_fixture(self, *args, sudo_uid=""):
        (self.root / "mock-state.json").write_text(json.dumps(self.state))
        environment = os.environ.copy()
        environment.update(NIGHTFALL_TEST_ROOT=str(self.root), SUDO_UID=sudo_uid)
        result = subprocess.run(["/bin/bash", str(self.script), *args], env=environment,
                                text=True, capture_output=True, timeout=10)
        log = self.root / "operations.jsonl"
        operations = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertTrue(self.unrelated.exists())
        return result, operations

    def assert_nothing_removed(self, operations):
        self.assertFalse(any(operation[0] == "rm" for operation in operations))
        self.assertTrue(all((self.filesystem / path).exists() for path in self.targets))

    def test_caller_stops_only_after_cleanup(self):
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        daemon = operations.index(["launchctl", "bootout", DAEMON])
        other = operations.index(["launchctl", "bootout", OTHER])
        removal = [index for index, operation in enumerate(operations) if operation[0] == "rm"]
        caller = operations.index(["launchctl", "bootout", CALLER])
        self.assertLess(daemon, other)
        self.assertLess(other, min(removal))
        self.assertLess(max(removal), caller)
        self.assertEqual(caller, len(operations) - 1)
        self.assertTrue(all(not (self.filesystem / path).exists() for path in self.targets))

    def test_daemon_bootout_failure_preserves_files(self):
        self.state["bootout_errors"] = {DAEMON: 5}
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)
        self.assertNotIn(["launchctl", "bootout", OTHER], operations)

    def test_daemon_must_be_verified_stopped(self):
        self.state["stuck"] = [DAEMON]
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)

    def test_other_agent_failure_preserves_files(self):
        self.state["bootout_errors"] = {OTHER: 5}
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)
        self.assertNotIn(["launchctl", "bootout", CALLER], operations)

    def test_unexpected_inspection_error_preserves_files(self):
        self.state["print_errors"] = {DAEMON: 5}
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)

    def test_service_disappearing_during_bootout_is_safe(self):
        self.state["disappears_during_bootout"] = [OTHER]
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_user_directory_failure_preserves_files(self):
        self.state["dscl_failure"] = 1
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)

    def test_process_listing_failure_preserves_files(self):
        self.state["ps_failure"] = 1
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_nothing_removed(operations)

    def test_other_network_login_is_stopped_before_removal(self):
        network_agent = "gui/504/com.nightfall.mac.agent"
        self.state["loaded"].append(network_agent)
        self.state["domains"].append("gui/504")
        self.state["process_users"] = ["501", "502", "504"]
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        stopped = operations.index(["launchctl", "bootout", network_agent])
        removed = next(index for index, operation in enumerate(operations) if operation[0] == "rm")
        self.assertLess(stopped, removed)

    def test_already_absent_services_are_supported(self):
        self.state["loaded"] = []
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(operation[:2] == ["launchctl", "bootout"] for operation in operations))
        self.assertFalse(self.script.exists())

    def test_cli_sudo_user_is_stopped_last(self):
        result, operations = self.run_fixture(sudo_uid="501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations[-1], ["launchctl", "bootout", CALLER])

    def test_invalid_uid_is_rejected_without_changes(self):
        for uid in ("0", "499", "501;touch /tmp/unwanted", "999999999999999999999"):
            with self.subTest(uid=uid):
                result, operations = self.run_fixture("--caller-uid", uid)
                self.assertNotEqual(result.returncode, 0)
                self.assert_nothing_removed(operations)


if __name__ == "__main__":
    unittest.main(verbosity=2)
