#!/usr/bin/env python3
"""Exercise the real socket and persistence with power actions disabled."""
from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else "build/Nightfall.app/Contents/MacOS/Nightfall").resolve()
with tempfile.TemporaryDirectory(prefix="nightfall-ipc-", dir="/private/tmp") as temporary:
    directory = Path(temporary)
    sock = str(directory / "s.sock")
    saved = {
        "settings": {"enabled": False, "hour": 20, "minute": 30, "warningSeconds": 120, "chimeEnabled": False},
        "handledDays": [],
    }
    (directory / "state.json").write_text(json.dumps(saved))

    def launch():
        process = subprocess.Popen([str(binary), "--daemon", "--dry-run", "--state-dir", temporary, "--socket", sock],
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(100):
            if process.poll() is not None:
                raise AssertionError(process.stderr.read().decode())
            if Path(sock).exists():
                try:
                    request({"command": "status"})
                    return process
                except (OSError, ValueError):
                    pass
            time.sleep(0.05)
        process.terminate()
        process.communicate(timeout=5)
        raise AssertionError("The dry-run service did not start")

    def request(payload, raw=False):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(3)
            client.connect(sock)
            client.sendall((payload if raw else json.dumps(payload).encode()) + b"\n")
            response = b""
            while b"\n" not in response:
                chunk = client.recv(4096)
                assert chunk, "The service closed without replying"
                response += chunk
            return json.loads(response.split(b"\n", 1)[0])

    def stop(process):
        process.terminate()
        process.communicate(timeout=5)

    def rejected_storage(name, prepare):
        fixture = directory / name
        fixture.mkdir(mode=0o700)
        state = fixture / "state.json"
        state.write_text(json.dumps(saved))
        prepare(fixture, state)
        result = subprocess.run([str(binary), "--daemon", "--dry-run", "--state-dir", str(fixture),
                                 "--socket", str(fixture / "s.sock")], capture_output=True, timeout=5)
        assert result.returncode != 0, f"The service accepted unsafe storage: {name}"
        assert not (fixture / "s.sock").exists(), f"The service listened with unsafe storage: {name}"

    process = launch()
    try:
        status = request({"command": "status"})
        assert status["dryRun"] is True
        assert status["state"]["settings"]["enabled"] is False
        settings = dict(saved["settings"], hour=21, minute=15, warningSeconds=60)
        updated = request({"command": "settings", "settings": settings})
        assert updated["state"]["settings"] == settings
        rejected = request({"command": "settings", "settings": dict(settings, hour=25)})
        assert "error" in rejected and rejected["state"]["settings"] == settings
        assert "error" in request(b"{broken", raw=True)
        assert "error" in request(b"x" * 32769, raw=True)
        assert "error" in request({"command": "execute", "path": "/bin/sh"})
        assert request({"command": "poll", "sessionID": "test-session", "isUsable": True})["dryRun"]

        # Incomplete clients use separate, bounded workers and cannot stall the
        # service's coordinator queue or another user's cancellation/settings.
        idle = []
        try:
            for _ in range(12):
                client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                client.connect(sock)
                client.sendall(b"{")
                idle.append(client)
            started = time.monotonic()
            assert request({"command": "status"})["dryRun"]
            assert time.monotonic() - started < 1.5, "Incomplete clients stalled other requests"
        finally:
            for client in idle:
                client.close()

        # This used to restart a two-second read timeout after each byte. A
        # single monotonic deadline must stop a trickling request in 2.5 seconds.
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
            client.settimeout(4)
            client.connect(sock)
            started = time.monotonic()
            client.sendall(b"{")
            time.sleep(1.5)
            client.sendall(b" ")
            response = b""
            while b"\n" not in response:
                chunk = client.recv(4096)
                assert chunk, "The service closed without reporting an incomplete request"
                response += chunk
            assert "error" in json.loads(response.split(b"\n", 1)[0])
            assert time.monotonic() - started < 3.3, "A trickling request extended the receive deadline"

        # A peer closing before the response must never terminate the service
        # through SIGPIPE; the next connection remains usable.
        for _ in range(8):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.connect(sock)
                client.sendall(b'{"command":"status"}\n')
        recovery_deadline = time.monotonic() + 4
        while True:
            try:
                assert request({"command": "status"})["dryRun"]
                break
            except (OSError, ValueError, AssertionError):
                assert process.poll() is None, (
                    f"A disconnected client terminated the service ({process.returncode}): "
                    f"{process.stderr.read().decode()}")
                if time.monotonic() >= recovery_deadline:
                    raise AssertionError("The service did not recover after disconnected clients")
                time.sleep(0.05)
        settings = dict(settings, enabled=True)
        assert request({"command": "settings", "settings": settings})["state"]["settings"] == settings
        skipped = request({"command": "skip"})
        assert skipped["state"].get("pending") is None
        assert skipped["state"]["lastOutcome"]["message"]
        day = skipped["state"]["lastOutcome"]["day"]
        assert day in skipped["state"]["handledDays"]
        assert os.stat(directory / "state.json").st_mode & 0o777 == 0o600
        duplicate = subprocess.run([str(binary), "--daemon", "--dry-run", "--state-dir", temporary,
                                    "--socket", sock], capture_output=True, timeout=5)
        assert duplicate.returncode != 0, "A second coordinator must not start"
        assert request({"command": "status"})["state"]["settings"] == settings
    finally:
        stop(process)
    process = launch()
    try:
        restarted = request({"command": "status"})
        assert restarted["state"]["settings"] == settings
        assert day in restarted["state"]["handledDays"]
    finally:
        stop(process)

    rejected_storage("writable-directory", lambda folder, state: folder.chmod(0o777))
    rejected_storage("writable-state", lambda folder, state: state.chmod(0o666))

    def linked_state(folder, state):
        state.rename(folder / "actual-state.json")
        state.symlink_to("actual-state.json")

    def linked_lock(folder, state):
        (folder / "actual-lock").touch(mode=0o600)
        (folder / "service.lock").symlink_to("actual-lock")

    def hardlinked_state(folder, state):
        os.link(state, folder / "second-state.json")

    def fifo_state(folder, state):
        state.unlink()
        os.mkfifo(state, 0o600)

    rejected_storage("linked-state", linked_state)
    rejected_storage("linked-lock", linked_lock)
    rejected_storage("hardlinked-state", hardlinked_state)
    rejected_storage("fifo-state", fifo_state)
    rejected_storage("damaged-state", lambda folder, state: state.write_text("{broken"))
    valid_directory = directory / "valid-directory"
    valid_directory.mkdir(mode=0o700)
    (valid_directory / "state.json").write_text(json.dumps(saved))
    linked_directory = directory / "linked-directory"
    linked_directory.symlink_to(valid_directory, target_is_directory=True)
    result = subprocess.run([str(binary), "--daemon", "--dry-run", "--state-dir", str(linked_directory),
                             "--socket", str(linked_directory / "s.sock")], capture_output=True, timeout=5)
    assert result.returncode != 0, "The service accepted a symbolic-link state directory"

    # Exercise the app's socket client too, using only an isolated fake service.
    # A stale/misbehaving listener must not keep a menu action waiting forever.
    fake_path = str(directory / "fake.sock")
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener, ThreadPoolExecutor(max_workers=1) as workers:
        listener.bind(fake_path)
        listener.listen(1)
        listener.settimeout(5)
        started = time.monotonic()
        response = workers.submit(subprocess.run, [str(binary), "--status", "--socket", fake_path],
                                  capture_output=True, timeout=5)
        client, _ = listener.accept()
        with client:
            client.settimeout(3)
            assert client.recv(4096), "The app did not send its status request"
            time.sleep(1.5)
            client.sendall(b"{")
            result = response.result(timeout=3)
        assert result.returncode != 0, "The app accepted an incomplete service response"
        assert time.monotonic() - started < 3.3, "A trickling service extended the client's receive deadline"
    print("PASS: socket validation, size/deadline bounds, concurrency, disconnected clients, persistence, "
          "restart, single owner, unsafe/damaged storage; dry run only")
