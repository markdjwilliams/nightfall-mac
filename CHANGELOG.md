# Changes

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
