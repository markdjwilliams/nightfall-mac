# Public beta and testing review

Mark approved making the repository public on **October 28, 2026**, superseding the earlier plan to keep it private until November 11. Nightfall remains an early beta. The two-week test period began October 28, with a testing follow-up planned for **November 11, 2026**. Do not infer successful testing from public availability or a lack of messages.

## Test evidence

- Obtain Mark's report of the two-week test period and resolve any reported problems.
- Confirm real sleep, one-occurrence cancellation, tomorrow's schedule, multiple logged-in users, user switching, screen locking, full-screen apps, and restart behavior on the destination Mac. Automated tests and rendered previews do not establish these interactive results.
- Re-run the scheduling/settings, dry-run service, isolated uninstall, and packaging checks. Do not trigger real sleep or uninstall as part of an unattended release review.
- State tested hardware and macOS versions accurately. The installed beta is Intel-only; native Apple Silicon support has not been hardware-tested. A public source repository does not itself claim a universal binary release.

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
