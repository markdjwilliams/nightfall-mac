#!/usr/bin/env python3
"""Check installer ordering and rollback using a disposable script copy.

System paths point into a temporary filesystem, and privileged tools are mocked.
These tests cover control flow and file recovery, not macOS authorization,
publisher identity, or real launchd behavior.
"""
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1] / "Scripts/install.sh"
DAEMON = "system/com.nightfall.mac.daemon"
CALLER = "gui/501/com.nightfall.mac.agent"
OTHER = "gui/502/com.nightfall.mac.agent"

MOCK = r'''#!/usr/bin/env python3
import json, os, pathlib, shutil, stat, subprocess, sys
root = pathlib.Path(os.environ["NIGHTFALL_TEST_ROOT"])
state_file = root / "mock-state.json"
state = json.loads(state_file.read_text())
name, args = pathlib.Path(sys.argv[0]).name, sys.argv[1:]
with (root / "operations.jsonl").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "dscl":
    print("mark 501\nother 502\nloggedout 503")
    sys.exit(state.get("dscl_failure", 0))
if name == "ps":
    print("\n".join(state.get("process_users", ["501", "502"])))
    sys.exit(state.get("ps_failure", 0))
if name == "launchctl":
    action, target, *rest = args
    if action == "print":
        if target in state.get("print_errors", {}): sys.exit(state["print_errors"][target])
        if target in state["loaded"] or target in state["domains"]: sys.exit(0)
        sys.exit(113 if target.count("/") >= 2 or target.startswith("system/") else 112)
    if action == "bootout":
        if target in state.get("bootout_errors", {}): sys.exit(state["bootout_errors"][target])
        if target not in state.get("stuck", []) and target in state["loaded"]: state["loaded"].remove(target)
    elif action == "bootstrap":
        if target in state.get("bootstrap_errors", {}):
            error = state["bootstrap_errors"].pop(target)
            state_file.write_text(json.dumps(state))
            sys.exit(error)
        service = DAEMON if target == "system" else target + "/com.nightfall.mac.agent"
        if service in state["loaded"]: sys.exit(5)
        state["loaded"].append(service)
    elif action == "kickstart" and target == "-k":
        if rest[0] not in state["loaded"]: sys.exit(113)
    else: raise SystemExit("Unexpected launchctl operation")
    state_file.write_text(json.dumps(state))
    sys.exit(0)
if name == "stat":
    print(0 if args[1] == "%u" else format(stat.S_IMODE(pathlib.Path(args[2]).stat().st_mode), "o"))
    sys.exit(0)
if name == "codesign": sys.exit(0)
if name in ("rm", "mv", "cp", "install", "chown", "chmod", "ditto"):
    # Reject absolute arguments outside the fixture before using real file tools.
    for arg in args:
        if arg.startswith("/") and not pathlib.Path(arg).is_relative_to(root):
            raise SystemExit("Refusing path outside test fixture: " + arg)
    if name == "chown": sys.exit(0)
    if name == "rm" and state.get("rm_error_target") in args:
        del state["rm_error_target"]
        state_file.write_text(json.dumps(state))
        sys.exit(1)
    if name == "ditto":
        shutil.copytree(args[0], args[1])
        sys.exit(0)
    if name == "install":
        if args[-1] == state.get("install_error_target"):
            del state["install_error_target"]
            state_file.write_text(json.dumps(state))
            sys.exit(1)
        args = [arg for arg in args if arg not in ("-o", "root", "-g", "wheel")]
    command = ("/usr/bin/" if name == "install" else "/bin/") + name
    sys.exit(subprocess.run([command, *args]).returncode)
raise SystemExit("Unexpected mock command: " + name)
'''.replace("DAEMON", repr(DAEMON))


class InstallerTests(unittest.TestCase):
    def setUp(self):
        """Create old/new app fixtures and redirect only the disposable installer."""
        self.temporary = tempfile.TemporaryDirectory(prefix="nightfall-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.filesystem = self.root / "filesystem"
        self.app = self.filesystem / "Applications/Nightfall.app"
        self.helper = self.filesystem / "Library/PrivilegedHelperTools/com.nightfall.mac.daemon"
        self.daemon_plist = self.filesystem / "Library/LaunchDaemons/com.nightfall.mac.daemon.plist"
        self.agent_plist = self.filesystem / "Library/LaunchAgents/com.nightfall.mac.agent.plist"
        self.state_directory = self.filesystem / "Library/Application Support/Nightfall"
        self.state_directory.mkdir(parents=True, mode=0o700)
        # State and an unrelated app detect cleanup that reaches beyond the
        # files being upgraded, even when replacement or rollback fails.
        self.saved_state = self.state_directory / "state.json"
        self.saved_state.write_text("keep schedule")
        for path, text in ((self.helper, "old helper"), (self.daemon_plist, "old daemon plist"),
                           (self.agent_plist, "old agent plist")):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(text)
        self.make_app(self.app, "old app")
        self.source_app = self.root / "source/Nightfall.app"
        self.make_app(self.source_app, "new app")
        self.unrelated = self.filesystem / "Applications/Other.app/keep"
        self.unrelated.parent.mkdir(parents=True)
        self.unrelated.write_text("keep")
        self.state = {"loaded": [DAEMON, CALLER, OTHER], "domains": ["gui/501", "gui/502"]}
        source = SOURCE.read_text()
        # Bypass authorization only in this copy; the shipped script is untouched.
        guard = '[[ "$EUID" -eq 0 ]]'
        self.assertEqual(source.count(guard), 1)
        source = source.replace(guard, "[[ 1 -eq 1 ]]")
        for tool, prefix in (("launchctl", "/bin/"), ("dscl", "/usr/bin/"), ("ps", "/bin/"), ("stat", "/usr/bin/"),
                             ("codesign", "/usr/bin/"), ("install", "/usr/bin/"), ("chown", "/usr/sbin/"),
                             ("chmod", "/bin/"), ("ditto", "/usr/bin/"), ("rm", "/bin/"),
                             ("mv", "/bin/"), ("cp", "/bin/")):
            mock = self.root / tool
            mock.write_text(MOCK)
            mock.chmod(0o755)
            source = source.replace(prefix + tool, str(mock))
        source = re.sub(r"(?<=[\s\"'>])/(Library|Applications)/",
                        lambda match: str(self.filesystem) + match.group(), source)
        self.script = self.root / "install.sh"
        self.script.write_text(source)

    @staticmethod
    def make_app(path, content):
        """Provide the bundle layout consumed by the script, without real code signing."""
        (path / "Contents/MacOS").mkdir(parents=True)
        helper = path / "Contents/Library/LaunchServices/com.nightfall.mac.daemon"
        helper.parent.mkdir(parents=True)
        helper.write_text(content + " helper")
        helper.chmod(0o755)
        executable = path / "Contents/MacOS/Nightfall"
        executable.write_text(content)
        executable.chmod(0o755)
        (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "com.nightfall.mac", "CFBundleExecutable": "Nightfall"}))

    def run_fixture(self, *args, sudo_uid=""):
        """Record simulated service/file operations and enforce retained-file checks."""
        (self.root / "mock-state.json").write_text(json.dumps(self.state))
        environment = os.environ.copy()
        environment.update(NIGHTFALL_TEST_ROOT=str(self.root), SUDO_UID=sudo_uid)
        result = subprocess.run(["/bin/bash", str(self.script), str(self.source_app), *args],
                                env=environment, text=True, capture_output=True, timeout=20)
        log = self.root / "operations.jsonl"
        operations = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
        self.assertEqual(self.saved_state.read_text(), "keep schedule")
        self.assertEqual(self.unrelated.read_text(), "keep")
        return result, operations

    def assert_old_installation(self):
        self.assertEqual((self.app / "Contents/MacOS/Nightfall").read_text(), "old app")
        self.assertEqual(self.helper.read_text(), "old helper")
        self.assertEqual(self.daemon_plist.read_text(), "old daemon plist")
        self.assertEqual(self.agent_plist.read_text(), "old agent plist")

    def test_caller_restarts_only_after_installation_and_cleanup(self):
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/MacOS/Nightfall").read_text(), "new app")
        self.assertNotIn(["launchctl", "bootout", CALLER], operations)
        self.assertEqual(operations[-1], ["launchctl", "kickstart", "-k", CALLER])
        self.assertFalse(list(self.helper.parent.glob(".nightfall-install.*")))

    def test_daemon_bootout_failure_preserves_files(self):
        self.state["bootout_errors"] = {DAEMON: 5}
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()

    def test_daemon_must_be_verified_stopped(self):
        self.state["stuck"] = [DAEMON]
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()

    def test_agent_stop_failure_restores_running_service(self):
        self.state["bootout_errors"] = {OTHER: 5}
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertIn(["launchctl", "bootstrap", "system", str(self.daemon_plist)], operations)

    def test_daemon_start_failure_rolls_back_files_and_services(self):
        self.state["bootstrap_errors"] = {"system": 5}
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        final_state = json.loads((self.root / "mock-state.json").read_text())
        self.assertCountEqual(final_state["loaded"], [DAEMON, CALLER, OTHER])
        self.assertFalse(list(self.helper.parent.glob(".nightfall-install.*")))

    def test_helper_replacement_failure_restores_old_app(self):
        self.state["install_error_target"] = str(self.helper)
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        final_state = json.loads((self.root / "mock-state.json").read_text())
        self.assertCountEqual(final_state["loaded"], [DAEMON, CALLER, OTHER])

    def test_failed_rollback_retains_old_app_instead_of_nesting_it(self):
        self.state["install_error_target"] = str(self.helper)
        self.state["rm_error_target"] = str(self.app)
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        stages = list(self.helper.parent.glob(".nightfall-install.*"))
        self.assertEqual(len(stages), 1)
        self.assertEqual((stages[0] / "previous.app/Contents/MacOS/Nightfall").read_text(), "old app")
        self.assertFalse((self.app / "previous.app").exists())
        self.assertIn("Recovery files were retained", result.stderr)
        final_state = json.loads((self.root / "mock-state.json").read_text())
        self.assertNotIn(DAEMON, final_state["loaded"])

    def test_first_install_starts_agents_for_signed_in_users(self):
        shutil.rmtree(self.app)
        for path in (self.helper, self.daemon_plist, self.agent_plist): path.unlink()
        self.state["loaded"] = []
        result, _ = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.app / "Contents/MacOS/Nightfall").read_text(), "new app")
        final_state = json.loads((self.root / "mock-state.json").read_text())
        self.assertCountEqual(final_state["loaded"], [DAEMON, CALLER, OTHER])

    def test_user_directory_failure_is_not_ignored(self):
        self.state["dscl_failure"] = 1
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertFalse(any(operation[:2] == ["launchctl", "bootout"] for operation in operations))

    def test_process_listing_failure_preserves_files(self):
        self.state["ps_failure"] = 1
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertFalse(any(operation[:2] == ["launchctl", "bootout"] for operation in operations))

    def test_unknown_service_inspection_error_preserves_files(self):
        self.state["print_errors"] = {DAEMON: 5}
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertFalse(any(operation[:2] == ["launchctl", "bootout"] for operation in operations))

    def test_network_account_caller_is_restarted(self):
        network_caller = "gui/504/com.nightfall.mac.agent"
        self.state["loaded"].append(network_caller)
        self.state["domains"].append("gui/504")
        result, operations = self.run_fixture("--caller-uid", "504")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations[-1], ["launchctl", "kickstart", "-k", network_caller])

    def test_other_network_login_is_updated(self):
        network_agent = "gui/504/com.nightfall.mac.agent"
        self.state["loaded"].append(network_agent)
        self.state["domains"].append("gui/504")
        self.state["process_users"] = ["501", "502", "504"]
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn(["launchctl", "bootout", network_agent], operations)
        self.assertIn(["launchctl", "bootstrap", "gui/504", str(self.agent_plist)], operations)

    def test_invalid_caller_is_rejected(self):
        result, operations = self.run_fixture("--caller-uid", "0")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertFalse(operations)

    def test_original_cli_arguments_remain_supported(self):
        result, operations = self.run_fixture(sudo_uid="501")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(operations[-1], ["launchctl", "kickstart", "-k", CALLER])

    def test_writable_state_parent_is_rejected_before_services_stop(self):
        self.state_directory.parent.chmod(0o777)
        result, operations = self.run_fixture("--caller-uid", "501")
        self.assertNotEqual(result.returncode, 0)
        self.assert_old_installation()
        self.assertFalse(any(operation[:2] == ["launchctl", "bootout"] for operation in operations))


if __name__ == "__main__":
    unittest.main(verbosity=2)
