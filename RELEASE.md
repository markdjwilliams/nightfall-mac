# Public beta and testing review

Mark approved making the repository public on **October 28, 2026**, superseding the earlier plan to keep it private until November 11. Nightfall remains an early beta. The two-week test period began October 28, with a testing follow-up planned for **November 11, 2026**. Do not infer successful testing from public availability or a lack of messages.

## Test evidence

- The first field test on October 28 failed to request scheduled sleep: version 1.1.0 consumed the occurrence when its warning could not be presented while the Mac was idle with sleeping displays. This is a reported failure, not evidence of a completed testing period. Version 1.1.2 addresses that case with independently sampled display/input evidence and a full unattended interval; the installed behavior still needs confirmation.
- Obtain Mark's report of the two-week test period and resolve any reported problems.
- Confirm real sleep, one-occurrence cancellation, tomorrow's schedule, multiple logged-in users, user switching, screen locking, full-screen apps, and restart behavior on the destination Mac. Keeping keyboard focus in another application must not cancel a warning that remains usable, visible, not occluded, and on the active desktop; **Skip tonight** must work on the first click in its inactive window. Automated tests and rendered previews do not establish these interactive results.
- Confirm the installed root service detects all online displays asleep and no input for a full unattended warning interval. Return partway through, wake one of several displays, and switch console users; each must revoke unattended approval and require a full visible warning for an awake user. If the displays sleep again while the occurrence is pending and within presentation grace, a new full unattended interval may start; no earlier elapsed time may carry over. A skipped or cleared occurrence must never return. An awake display must retain the visible-warning requirement even during long reading or video sessions. Unknown/failed readings cannot authorize unattended sleep; if neither usable presentation nor valid unattended evidence becomes available within grace, the occurrence must skip. These hardware and session transitions remain manual checks.
- Re-run the scheduling, app-model, system-presence probe, dry-run service, isolated installer/uninstaller, and packaging checks. Injected samples and probe failures cover decision logic; they do not establish the root service's real display/input observations. Do not trigger real sleep or uninstall as part of an unattended release review.
- State tested hardware and macOS versions accurately. The field-test Mac is Intel-based. Downloads are built separately for Intel and Apple Silicon; Apple Silicon hardware has not been tested. Cross-compilation and signature checks do not establish native runtime behavior or constitute a universal binary release.

## Licensing and public content

- MIT was selected by Mark on October 28. Preserve `LICENSE` and `NOTICE.md` in source distributions and compiled app bundles.
- Review new dependencies, copied code, and assets. The initial source/history scan found no bundled third-party packages or media, detected secrets, or personal machine paths. This is a bounded source audit, not legal clearance or a guarantee of originality.
- Keep Apple system symbols in permitted interface roles. Review any branding use against Apple's current SF Symbols restrictions; use the original application artwork for app identity. Do not redistribute Apple system assets under MIT.
- Git history includes its original commit author metadata. Do not silently rewrite history; agree on any identity changes or cleanup with Mark first.
- Review new source, artifacts and Git history for secrets and unintended personal data before later releases.
- Developer ID signing and notarization are separate distribution decisions. The current build is ad hoc signed, as the README states.

## Publication

The November 11 follow-up is **review only**. Review the public beta's reported bugs and testing evidence, then report readiness and unresolved items. Do not change visibility, publish another release, or claim the beta has completed testing without Mark's authorization and supporting evidence. Keep the current signing and hardware-testing limitations explicit.

References: [MIT license](https://opensource.org/license/mit), [Apple's Xcode and SDK agreement](https://www.apple.com/legal/sla/docs/xcode.pdf), and [SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).
