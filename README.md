# Nightfall

A native menu bar app that gives everyone on this Mac a chance to finish up before its daily sleep.

The default is **sleep at 8:30 p.m. every day**, with a **two-minute countdown** starting around 8:28 p.m. An optional gentle chime is **off by default**; there are no spoken announcements. The countdown always gives the active user the full warning period, so a late presentation or user switch may delay sleep. **Skip tonight** cancels that occurrence for the entire Mac. Tomorrow’s schedule stays on. The time, warning length, and chime are configurable. Existing speech preferences migrate to sound off.

Nightfall puts the Mac to **sleep**. It does not power it off.

## Install

1. Open `build/Nightfall.app`.
2. Choose **Install for all users…** and authorize the standard macOS administrator prompt.
3. Nightfall reopens from Applications. Use the moon in the menu bar to open **Schedule & settings…**.

The installer adds one system service and one agent for every graphical login. It starts agents for users who are already signed in, as well as future logins. The schedule is shared by the whole Mac. An active desktop user may change it; any logged-in account can cancel an occurrence. If macOS disables Nightfall under **System Settings → General → Login Items & Extensions**, re-enable it or use **Repair installation…**.

**Preview warning** is harmless: it never sends a sleep request or consumes tonight’s schedule. The daily-sleep toggle takes effect when you choose **Save changes**. Pausing daily sleep keeps it off until someone enables it again.

## Courtesy and safety

- The countdown starts only after the active user’s app reports that its warning is visible and can receive input.
- A different active user gets a fresh, full countdown. Cancellation applies to everyone.
- A hidden, locked, switched-out, missing, or disconnected warning cannot approve sleep. Uncertain presentation is given a short grace period, then the occurrence is skipped. If you switch to another application during the warning, it loses input focus; the timer restarts if you return promptly, or skips after ten seconds.
- A service restart during a warning consumes the occurrence safely. A long pause or wake after a missed scheduled time does not cause immediate sleep. No timer wakes the Mac for this app.
- Processed calendar dates are saved before a power request, preventing repeated attempts after restart, clock rollback, or a cancelled warning. A failed sleep request is recorded and is not retried that day.
- Storage failures suspend power requests. No forced shutdown, private lock-screen API, Accessibility permission, or Screen Recording permission is used.

The service requests normal macOS system sleep using `IOPMSleepSystem`. A successful request does not guarantee hardware will sleep: macOS and device drivers retain control. The warning can protect interactive users, but does not detect the needs of unattended jobs or remote SSH users. Press **Skip tonight** or pause the schedule when those must continue.

## Build and verify

Requires macOS 13 or later and Apple Command Line Tools. No third-party packages are required. The build targets the current Mac’s processor; set `NIGHTFALL_ARCH=arm64` or `x86_64` to build for a different Mac.

```sh
./Scripts/build.sh
./Tests/run-tests.sh
python3 Tests/ServiceTests.py
python3 Tests/UninstallTests.py
```

The first Swift build creates a local module cache and can take a few minutes. The build is ad-hoc signed for local use; it is not Developer ID signed or notarized for public distribution.

Core tests cover scheduling, cancellation, presentation, multiple users, stale agents, restarts, wake gaps, daylight-saving changes, and clock changes. The service test uses the real socket and persistence with **power actions disabled**. It never sleeps the Mac.

For manual checks, use **Preview warning** first. Then verify a real countdown with the Mac in use, another signed-in user, user switching, full-screen apps, screen locking, and an app restart. Save work before allowing a real countdown to complete. These interactive conditions and actual hardware sleep need testing on the destination Mac; automated simulations cannot establish their behavior.

## Design

`Sources/NightfallCore` contains a deterministic Foundation scheduling state machine. `Sources/Nightfall` contains the AppKit/SwiftUI menu bar interface, per-user presentation, a root service, and a small authenticated local-socket protocol.

The daemon checks the current console UID independently and checks the socket client’s UID with `getpeereid`. Presentation acknowledgments are bound to the agent session and warning ID. Before sleeping, the service saves the consumed occurrence and checks the console user and heartbeat again. Its interface accepts a bounded set of schedule, status, and cancellation messages; it does not execute caller-supplied commands or paths.

Installed files:

| Location | Purpose |
| --- | --- |
| `/Applications/Nightfall.app` | Menu bar app and installer |
| `/Library/PrivilegedHelperTools/com.nightfall.mac.daemon` | Root-owned service executable, outside the group-writable Applications directory |
| `/Library/LaunchDaemons/com.nightfall.mac.daemon.plist` | System service registration |
| `/Library/LaunchAgents/com.nightfall.mac.agent.plist` | Courtesy agent in each Aqua login |
| `/Library/Application Support/Nightfall/` | Root-owned schedule, processed dates, and service log |
| `/var/run/com.nightfall.mac.sock` | Local IPC socket; no network service |

## Remove

Choose **Uninstall Nightfall…** in settings or the moon’s menu. Confirm removal for all users, then authorize the standard macOS administrator prompt. The uninstaller stops automatic sleep before removing the app and shared schedule, and closes each user’s menu bar agent.

Or remove it from Terminal:

```sh
sudo /Applications/Nightfall.app/Contents/Resources/uninstall.sh
```

This removes Nightfall’s app, services, and saved schedule. It leaves unrelated power-management settings alone.

## License and release status

Nightfall is licensed under [MIT](LICENSE). See [NOTICE.md](NOTICE.md) for Apple system-component notices. The repository remains private during the two-week testing period; the public-release review is planned for November 11, 2026. See [RELEASE.md](RELEASE.md) for the release conditions.

Source: https://github.com/markdjwilliams/nightfall-mac
