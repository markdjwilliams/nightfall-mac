# Changes

## 1.1.2 beta 2 — October 29, 2026

- Handle macOS's signed-out GUI-session response during installation and removal. Keep permission errors and failures inspecting the system service fatal, and still verify that existing jobs have stopped before replacing files.
- Test the observed signed-out-session response, compatibility with earlier absence responses, and users signing out during maintenance.

## 1.1.2 beta 1 — October 29, 2026

- Address a failed field test in 1.1.0: the Mac was idle with its displays asleep, so the visible-warning requirement consumed the scheduled occurrence without requesting sleep.
- Allow a full unattended countdown only when the service independently verifies every online display is asleep, no input occurs throughout the warning interval, and the console user remains unchanged. Idle time alone is insufficient while a display is awake.
- Require a fresh, full visible warning after input, a waking display, a user change, or an unknown system reading revokes unattended approval. If all displays later sleep while the occurrence is still pending and within presentation grace, start a new full unattended interval without inheriting earlier elapsed time. Cleared or skipped occurrences stay consumed.
- Keep the visible countdown running when another application has keyboard focus, provided the warning remains usable, visible, not occluded, and on the active desktop. Accept the first click on **Skip tonight** even when its window is inactive.
- Keep per-user polling active while menus or dialogs use another run-loop mode, so opening the menu does not stall the app's presentation updates.
- Expose optional display/input evidence in status responses and add probe-failure and unattended-countdown regression checks.

Automated checks use injected system samples or run with power actions disabled. The installed root service's readings with sleeping displays, return-to-desktop behavior, focus and first-click handling, user switching, and actual hardware sleep still need hands-on testing. This change does not establish that every Mac or display configuration will sleep successfully.

## 1.1.1 beta — October 28, 2026

- Keep edits made while a save is in progress. Pausing from the menu changes only the enabled setting and preserves unfinished time or chime edits.
- Disable duplicate or conflicting actions while a save, skip, or cancellation is pending. A cancellation or settings change must not also skip tomorrow's sleep.
- Use **Skip next sleep** in settings and the menu, including for schedules just after midnight. Cancelling a visible warning still affects only that occurrence.
- Compare the countdown against monotonic elapsed time so clock corrections cannot silently shorten the warning.
- Bound socket connection, read and write operations. Handle disconnected and slow clients without blocking the service or crashing it with a broken pipe.
- Validate ownership, permissions and file types before trusting the service's stored state or lock.
- Verify the old service has stopped before replacing it, retain recovery backups if rollback fails, and restart the installing user's app only after cleanup finishes.
- Offer installation when opening a downloaded update, instead of silently redirecting to the older running app.
- Include signed-in network accounts when updating or removing login agents.
- Check every shell script and keep app, service and bundle version numbers consistent.

The expanded checks use injected responses or temporary test fixtures. They do not trigger real sleep, installation, or removal. This remains an early beta: Developer ID signing, notarization, Apple Silicon hardware behavior, and interactive user-switching/lock-screen checks remain outstanding.

## 1.1.0 beta — October 28, 2026

Initial public beta with a shared daily sleep schedule, a cancellable warning for the active desktop, an optional chime off by default, system-wide installation and removal, Git LFS downloads, and manual GitHub Actions builds.
