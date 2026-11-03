import Foundation
import Darwin

private final class FixturePresenceProbe: PresenceProbeTransport {
    var calls = 0
    var stops = 0
    var result: SystemPresence? = SystemPresence(displaysAsleep: true, idleSeconds: 120)
    var fails = false
    func sample(until deadline: TimeInterval) throws -> SystemPresence? {
        calls += 1
        if fails { throw SocketError.invalidResponse }
        return result
    }
    func stop() { stops += 1 }
}

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

        var elapsed: TimeInterval = 0
        var clockReads = [String]()
        let clockOrigin = Date(timeIntervalSince1970: 1_800_000_000)
        let delayedSample = NightfallDaemon.sampleTickInputs(readSystemPresence: {
            elapsed += 2
            return SystemPresence(displaysAsleep: true, idleSeconds: 120)
        }, readConsole: {
            elapsed += 3
            return 501
        }, readDate: {
            clockReads.append("date")
            return clockOrigin.addingTimeInterval(elapsed)
        }, readUptime: {
            clockReads.append("uptime")
            return elapsed
        })
        expect(delayedSample.now == clockOrigin.addingTimeInterval(5) && delayedSample.uptime == 5,
               "Slow system queries must precede both clock samples, so latency cannot mimic a clock jump")
        expect(clockReads == ["date", "uptime"], "The wall and monotonic clocks must be read adjacently in that order")
        expect(delayedSample.consoleUID == 501 && delayedSample.systemPresence?.displaysAsleep == true,
               "Clock sampling must retain the independently queried presence and console evidence")

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

        var monotonic: TimeInterval = 100
        var starts = [UInt32]()
        var fixtures = [FixturePresenceProbe]()
        let provider = SystemPresenceProvider(allowGUIProbe: true, readDirect: { preconditionFailure("GUI probe must be independent") },
                                             uptime: { monotonic }, startProbe: { uid, deadline in
            starts.append(uid)
            let worker = FixturePresenceProbe()
            fixtures.append(worker)
            precondition(deadline == monotonic + 0.8)
            return worker
        })
        expect(provider.sample(readConsole: { 501 }).presence == idle, "A protected probe should supply the current owner's sample")
        expect(provider.sample(readConsole: { 501 }).presence == idle && fixtures[0].calls == 1,
               "Routine polling should reuse a sample for less than one second")
        fixtures[0].result = SystemPresence(displaysAsleep: false, idleSeconds: 0)
        expect(provider.sample(readConsole: { 501 }, forceFresh: true).presence?.displaysAsleep == false && fixtures[0].calls == 2,
               "Final approval must bypass the ordinary cache")
        monotonic += 1
        expect(provider.sample(readConsole: { 501 }).presence?.displaysAsleep == false && fixtures[0].calls == 3,
               "Routine evidence must be refreshed after one second")
        expect(provider.sample(readConsole: { 502 }).presence == idle && starts == [501, 502] && fixtures[0].stops == 1,
               "Switching users must destroy the previous probe and its cache")
        var ownerReads = 0
        expect(provider.sample(readConsole: { ownerReads += 1; return ownerReads == 1 ? 502 : 503 }, forceFresh: true).presence == nil && fixtures[1].stops == 1,
               "A user switch during a probe must discard even a valid reply")
        expect(provider.sample(readConsole: { nil }).presence == nil && starts.count == 2,
               "No console owner must never launch a GUI-context probe")
        _ = provider.sample(readConsole: { 503 })
        fixtures[2].fails = true
        expect(provider.sample(readConsole: { 503 }, forceFresh: true).presence == nil && fixtures[2].stops == 1,
               "A malformed or failed probe must discard the worker")
        expect(provider.sample(readConsole: { 503 }, forceFresh: true).presence == nil && starts.count == 3,
               "Failure backoff also applies to final checks; missing evidence cannot authorize sleep")
        monotonic += 3
        expect(provider.sample(readConsole: { 503 }).presence == idle && starts.count == 4,
               "A failed probe must retry after its bounded backoff")
        var dryDirectReads = 0
        let dryProvider = SystemPresenceProvider(allowGUIProbe: false, readDirect: { dryDirectReads += 1; return nil },
                                                startProbe: { _, _ in preconditionFailure("Dry runs must not launch a GUI-context child") })
        expect(dryProvider.sample(readConsole: { 501 }).presence == nil && dryDirectReads == 1,
               "Dry runs retain direct reads and never invoke the privileged route")

        func rejects(_ payload: Data) -> Bool {
            do { _ = try SystemPresenceProbe.decodeResponse(payload); return false } catch { return true }
        }
        expect((try? SystemPresenceProbe.decodeResponse(Data("null".utf8))) == nil,
               "An unavailable probe sample must not become affirmative evidence")
        expect((try? SystemPresenceProbe.decodeResponse(Data("{\"displaysAsleep\":false,\"idleSeconds\":0}".utf8)))?.displaysAsleep == false,
               "Known awake is a valid diagnostic sample")
        for payload in ["{}", "true", "{\"displaysAsleep\":1,\"idleSeconds\":120}",
                        "{\"displaysAsleep\":true,\"idleSeconds\":-1}",
                        "{\"displaysAsleep\":true,\"idleSeconds\":1e309}",
                        "{\"displaysAsleep\":true,\"idleSeconds\":1.7976931348623157e308}", "NaN"] {
            expect(rejects(Data(payload.utf8)), "Malformed or nonfinite probe evidence must fail closed")
        }
        expect(rejects(Data(repeating: 32, count: SystemPresenceProbe.messageLimit + 1)),
               "Probe responses must have a strict size bound")

        func withPipe(_ body: (Int32, Int32) throws -> Void) rethrows {
            var pair = [Int32](repeating: -1, count: 2)
            precondition(pipe(&pair) == 0)
            defer { pair.forEach { Darwin.close($0) } }
            try body(pair[0], pair[1])
        }
        try! withPipe { reader, writer in
            try SystemPresenceProbe.configure(reader)
            try SystemPresenceProbe.configure(writer)
            try SystemPresenceProbe.writeLine(Data("null".utf8), fd: writer, until: ProcessInfo.processInfo.systemUptime + 1)
            expect(try SystemPresenceProbe.readLine(fd: reader, until: ProcessInfo.processInfo.systemUptime + 1) == Data("null".utf8),
                   "The private-pipe transport must accept a complete bounded frame")
        }
        for payload in ["null\nnull\n", String(repeating: "x", count: SystemPresenceProbe.messageLimit + 1) + "\n"] {
            try! withPipe { reader, writer in
                try SystemPresenceProbe.configure(reader)
                let bytes = Data(payload.utf8)
                precondition(bytes.withUnsafeBytes { Darwin.write(writer, $0.baseAddress!, $0.count) } == bytes.count)
                var rejected = false
                do { _ = try SystemPresenceProbe.readLine(fd: reader, until: ProcessInfo.processInfo.systemUptime + 1) }
                catch { rejected = true }
                expect(rejected, "Oversized or multiple replies must never be mistaken for a fresh sample")
            }
        }
        try! withPipe { reader, writer in
            try SystemPresenceProbe.configure(reader)
            precondition(Darwin.write(writer, "{", 1) == 1)
            let started = ProcessInfo.processInfo.systemUptime
            var timedOut = false
            do { _ = try SystemPresenceProbe.readLine(fd: reader, until: started + 0.05) }
            catch { timedOut = true }
            expect(timedOut && ProcessInfo.processInfo.systemUptime - started < 0.5,
                   "An incomplete response must obey one fixed deadline without waiting for EOF")
        }
        var broken = [Int32](repeating: -1, count: 2)
        precondition(pipe(&broken) == 0)
        try! SystemPresenceProbe.configure(broken[1])
        Darwin.close(broken[0])
        var brokenPipeRejected = false
        do { try SystemPresenceProbe.writeLine(Data("sample".utf8), fd: broken[1], until: ProcessInfo.processInfo.systemUptime + 1) }
        catch { brokenPipeRejected = true }
        Darwin.close(broken[1])
        expect(brokenPipeRejected, "A worker exiting before a request must produce an error without SIGPIPE terminating the service")
        print("PASS: \(checks) system-presence normalization and final-approval checks; injected reads only")
    }
}
