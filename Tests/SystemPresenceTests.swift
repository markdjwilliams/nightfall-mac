import Foundation

/// Exercises normalization with injected system reads; never changes displays,
/// captures input, starts a service, or invokes the power-request path.
@main
enum SystemPresenceTests {
    static func main() {
        typealias Display = SystemPresenceReader.Display
        typealias Snapshot = SystemPresenceReader.DisplaySnapshot
        let sleeping = [Display(id: 1, online: 1, asleep: 1), Display(id: 2, online: 1, asleep: 1)]
        var checks = 0
        func expect(_ condition: Bool, _ message: String) {
            precondition(condition, message)
            checks += 1
        }
        func sample(_ rows: [Display], count: UInt32? = nil, idle: TimeInterval? = 120) -> SystemPresence? {
            SystemPresenceReader(readDisplays: { Snapshot(reportedCount: count ?? UInt32(rows.count), displays: rows) },
                                 readIdleSeconds: { idle }).sample()
        }

        expect(sample(sleeping) == SystemPresence(displaysAsleep: true, idleSeconds: 120),
               "Every online display asleep with valid idle evidence should be available")
        let mixed = [sleeping[0], Display(id: 2, online: 1, asleep: 0)]
        expect(sample(mixed) == SystemPresence(displaysAsleep: false, idleSeconds: 120),
               "One awake display must block unattended sleep even when another display sleeps")
        expect(sample(sleeping, idle: 0)?.supportsUnattendedInterval(1) == false,
               "A dark display does not replace the required no-input interval")
        expect(SystemPresenceReader(readDisplays: { nil }, readIdleSeconds: { 120 }).sample() == nil,
               "A failed display query must remain unknown")
        expect(sample([]) == nil, "Zero displays must not count as all displays asleep")
        expect(sample(sleeping, count: 1) == nil, "An inconsistent display list must remain unknown")
        let tooMany = (1...Int(SystemPresenceReader.maximumDisplays + 1)).map {
            Display(id: UInt32($0), online: 1, asleep: 1)
        }
        expect(sample(tooMany) == nil, "An over-limit or truncated display list must remain unknown")
        expect(sample(Array(tooMany.prefix(Int(SystemPresenceReader.maximumDisplays)))) == nil,
               "An at-cap display list must not be assumed complete")
        expect(sample([sleeping[0], sleeping[0]]) == nil, "Duplicate IDs are not a complete display list")
        expect(sample([Display(id: 0, online: 1, asleep: 1)]) == nil, "A null display ID must remain unknown")
        for raw in [UInt32(0), 2, UInt32.max] {
            expect(sample([Display(id: 1, online: raw, asleep: 1)]) == nil,
                   "Only an explicit online value of one can verify a display")
        }
        for raw in [UInt32(2), UInt32.max] {
            expect(sample([Display(id: 1, online: 1, asleep: raw)]) == nil,
                   "Malformed sleep values must not be treated as true")
        }
        expect(sample(sleeping, idle: nil) == nil, "Missing idle evidence must remain unknown")
        for idle in [TimeInterval.nan, .infinity, -.infinity, -1, .greatestFiniteMagnitude] {
            expect(sample(sleeping, idle: idle) == nil, "Invalid or sentinel idle values must remain unknown")
        }
        expect(SystemPresenceReader.unchangedDisplayInventory([1, 2], [2, 1]),
               "Display enumeration order may change without changing the inventory")
        expect(!SystemPresenceReader.unchangedDisplayInventory([1, 2], [1, 3]),
               "Same-count replacement must invalidate earlier display sleep readings")
        expect(!SystemPresenceReader.unchangedDisplayInventory([1, 2], [1, 2, 3]),
               "An added display must invalidate earlier display sleep readings")

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var warning = PendingWarning(id: "fixture", day: "fixture", scheduledAt: now, deadline: now,
                                     warningSeconds: 120, recipientUID: 501, awaitingSince: now,
                                     unattendedSince: now.addingTimeInterval(-120))
        func verifies(_ evidence: SystemPresence?, before: UInt32? = 501, after: UInt32? = 501,
                      at time: Date? = nil) -> Bool {
            NightfallDaemon.verifiesUnattendedSleep(warning, consoleBefore: before, consoleAfter: after,
                                                    systemPresence: evidence, now: time ?? now)
        }
        let idle = SystemPresence(displaysAsleep: true, idleSeconds: 120)
        expect(verifies(idle), "A fresh sample covering the full stable-owner interval should verify")
        expect(!verifies(nil), "Unknown final evidence must not approve sleep")
        expect(!verifies(SystemPresence(displaysAsleep: false, idleSeconds: 120)),
               "A display waking during persistence must revoke approval")
        expect(!verifies(SystemPresence(displaysAsleep: true, idleSeconds: 119)),
               "New input during persistence must revoke approval")
        expect(!verifies(idle, before: 502, after: 502), "An owner change before resampling must revoke approval")
        expect(!verifies(idle, after: 502), "An owner change during resampling must revoke approval")
        expect(!verifies(idle, after: nil), "A disappearing console during resampling must revoke approval")
        expect(!verifies(idle, at: now.addingTimeInterval(1)),
               "Idle evidence must cover time spent persisting and resampling too")
        expect(!verifies(idle, at: now.addingTimeInterval(-121)), "A backward final clock jump must fail closed")
        warning.deadline = now.addingTimeInterval(-10)
        expect(!verifies(SystemPresence(displaysAsleep: true, idleSeconds: 1000), at: now.addingTimeInterval(-0.1)),
               "A final clock jump shortening the warning must fail despite abundant idle time")
        warning.deadline = now.addingTimeInterval(1)
        expect(!verifies(SystemPresence(displaysAsleep: true, idleSeconds: 1000)),
               "Final verification must not precede the pending deadline")
        warning.deadline = now
        warning.recipientUID = nil
        expect(verifies(idle, before: nil, after: nil), "A stable absent console still requires full system evidence")
        expect(!verifies(idle, before: nil, after: 501), "A newly active console must revoke unattended approval")
        warning.unattendedSince = nil
        expect(!verifies(idle, before: nil, after: nil), "An interactive warning cannot use unattended approval")
        print("PASS: \(checks) system-presence normalization and final-approval checks; injected reads only")
    }
}
