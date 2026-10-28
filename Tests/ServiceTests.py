#!/usr/bin/env python3
"""Exercise the real socket and persistence with power actions disabled."""
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
        assert "error" in request({"command": "execute", "path": "/bin/sh"})
        assert request({"command": "poll", "sessionID": "test-session", "isUsable": True})["dryRun"]
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
    print("PASS: real socket, validation, malformed requests, persistence, restart, single owner; dry run only")
