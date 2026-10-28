# Public release review

The repository stays private during the two-week test period beginning October 28, 2026. Review it for public visibility on **November 11, 2026**, provided testing has found no unresolved problems and the licensing and privacy checks below are satisfied. Do not infer successful testing from a lack of messages.

## Test evidence

- Obtain Mark's report of the two-week test period and resolve any reported problems.
- Confirm real sleep, one-occurrence cancellation, tomorrow's schedule, multiple logged-in users, user switching, screen locking, full-screen apps, and restart behavior on the destination Mac. Automated tests and rendered previews do not establish these interactive results.
- Re-run the scheduling/settings, dry-run service, isolated uninstall, and packaging checks. Do not trigger real sleep or uninstall as part of an unattended release review.
- State tested hardware and macOS versions accurately. The installed beta is Intel-only; native Apple Silicon support has not been hardware-tested. A public source repository does not itself claim a universal binary release.

## Licensing and public content

- MIT was selected by Mark on October 28. Preserve `LICENSE` and `NOTICE.md` in source distributions and compiled app bundles.
- Review new dependencies, copied code, and assets. The initial source/history scan found no bundled third-party packages or media, detected secrets, or personal machine paths. This is a bounded source audit, not legal clearance or a guarantee of originality.
- Keep Apple system symbols in permitted interface roles. Review any branding use against Apple's current SF Symbols restrictions; use the original application artwork for app identity. Do not redistribute Apple system assets under MIT.
- Confirm Mark is comfortable publishing the commit author metadata, which currently includes a personal email address. If not, agree on a GitHub no-reply identity and history cleanup before publication. Do not silently rewrite history.
- Review the complete Git history again for secrets and unintended personal data before changing visibility.
- Developer ID signing and notarization are separate distribution decisions. The current build is ad hoc signed, as the README states.

## Publication

Only change visibility after the issue-free testing condition and applicable licensing/privacy checks are confirmed. If information is missing, ask Mark and leave the repository private. Honor any required action-time approval for exposing a private repository. Verify the resulting GitHub visibility and report it after the change.

References: [MIT license](https://opensource.org/license/mit), [Apple's Xcode and SDK agreement](https://www.apple.com/legal/sla/docs/xcode.pdf), and [SF Symbols guidance](https://developer.apple.com/design/human-interface-guidelines/sf-symbols).
