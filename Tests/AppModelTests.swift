import Foundation
import CoreFoundation
import AppKit

private enum TestFailure: Error, LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self { case .failed(let message): return message }
    }
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw TestFailure.failed(message) }
}

/// Pauses injected responses so tests can edit or queue actions while I/O is in flight.
/// No real socket is used; each test explicitly releases its expected requests.
private final class StubService {
    private let lock = NSLock()
    private let started = DispatchSemaphore(value: 0)
    private let release = DispatchSemaphore(value: 0)
    private var received: [ServiceRequest] = []
    private let responses: [Result<ServiceResponse, Error>]

    init(_ responses: [Result<ServiceResponse, Error>]) { self.responses = responses }

    var requests: [ServiceRequest] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func request(_ request: ServiceRequest) throws -> ServiceResponse {
        lock.lock()
        let index = received.count
        received.append(request)
        lock.unlock()
        started.signal()
        guard index < responses.count else { throw TestFailure.failed("Unexpected extra request") }
        guard release.wait(timeout: .now() + 5) == .success else {
            throw TestFailure.failed("Test transport was not released")
        }
        return try responses[index].get()
    }

    func waitForRequest() throws {
        try expect(started.wait(timeout: .now() + 2) == .success, "Expected a background request")
    }

    func respond() { release.signal() }
}

private func pump(until condition: () -> Bool) throws {
    let deadline = Date().addingTimeInterval(2)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.005))
    }
    try expect(condition(), "Timed out waiting for the model callback")
}

private func response(_ settings: Settings = Settings(), error: String? = nil) -> ServiceResponse {
    ServiceResponse(state: EngineState(settings: settings), error: error)
}

private func model(_ service: StubService, draft: Settings = Settings()) -> AppModel {
    let model = AppModel(requestService: service.request)
    model.connected = true
    model.state = EngineState()
    model.draft = draft
    model.isDirty = true
    return model
}

@main
private struct AppModelTests {
    static func main() throws {
        try expect(Thread.isMainThread, "App model tests must run on the main thread")
        let tests: [(String, () throws -> Void)] = [
            ("save preserves edits made in flight", editsDuringSave),
            ("confirmed save clears only submitted edits", confirmedSave),
            ("failed save can be retried", failedSave),
            ("service save error keeps unsaved changes", serviceSaveError),
            ("duplicate saves are coalesced", duplicateSave),
            ("duplicate skips are coalesced", duplicateSkip),
            ("cancel cannot also skip tomorrow", cancelThenSkip),
            ("save cannot also skip tomorrow", saveThenSkip),
            ("pause does not save unfinished edits", pausePreservesEdits),
            ("failed pause reports failure", failedPause),
            ("poll waits for all queued actions", pollBackpressure),
            ("poll timer runs during menu tracking", menuTrackingHeartbeat),
            ("visible warnings do not require keyboard focus", visibleWithoutKeyboardFocus)
        ]
        for (name, test) in tests { try test(); print("PASS \(name)") }
        print("\(tests.count) app model tests passed; injected transport only.")
    }

    static func editsDuringSave() throws {
        let submitted = Settings(hour: 21)
        let stub = StubService([.success(response(submitted)), .success(response(submitted))])
        let m = model(stub, draft: submitted)
        m.save()
        try stub.waitForRequest()
        m.draft.minute = 45
        stub.respond()
        try pump { !m.saving }
        try expect(m.isDirty && m.draft.minute == 45, "A save response discarded newer edits")
        var updates = 0
        m.onUpdate = { updates += 1 }
        m.poll()
        try stub.waitForRequest()
        stub.respond()
        try pump { updates == 1 }
        try expect(m.draft.minute == 45, "A later poll discarded newer edits")
    }

    static func confirmedSave() throws {
        let submitted = Settings(hour: 21)
        let stub = StubService([.success(response(submitted))])
        let m = model(stub, draft: submitted)
        m.save()
        try stub.waitForRequest()
        try expect(m.saving, "Save must expose its in-flight state")
        stub.respond()
        try pump { !m.saving }
        try expect(!m.isDirty && m.state?.settings == submitted, "Confirmed save should clear submitted changes")
    }

    static func failedSave() throws {
        let submitted = Settings(hour: 21)
        let stub = StubService([.failure(TestFailure.failed("Unavailable")), .success(response(submitted))])
        let m = model(stub, draft: submitted)
        m.save()
        try stub.waitForRequest()
        stub.respond()
        try pump { !m.saving }
        try expect(m.isDirty && m.draft == submitted && !m.connected, "Transport failure must retain edits")
        m.save()
        try stub.waitForRequest()
        stub.respond()
        try pump { !m.saving }
        try expect(!m.isDirty && m.connected, "Save must be retryable after a transport failure")
    }

    static func serviceSaveError() throws {
        let submitted = Settings(hour: 21)
        let stub = StubService([.success(response(submitted, error: "Storage unavailable"))])
        let m = model(stub, draft: submitted)
        m.save()
        try stub.waitForRequest()
        stub.respond()
        try pump { !m.saving }
        try expect(m.isDirty && m.message == "Storage unavailable", "A service error must not report saved changes")
    }

    static func duplicateSave() throws {
        let stub = StubService([.success(response())])
        let m = model(stub)
        m.save()
        try stub.waitForRequest()
        m.save()
        stub.respond()
        try pump { !m.saving }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(stub.requests.count == 1, "Duplicate save queued another request")
    }

    static func duplicateSkip() throws {
        let stub = StubService([.success(response())])
        let m = model(stub)
        m.skipNextSleep()
        try stub.waitForRequest()
        m.skipNextSleep()
        stub.respond()
        try pump { !m.skipping }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(stub.requests.count == 1, "Double-clicking skip queued another occurrence")
    }

    static func cancelThenSkip() throws {
        let stub = StubService([.success(response())])
        let m = model(stub)
        let now = Date()
        m.state?.pending = PendingWarning(id: "active-warning", day: "test", scheduledAt: now,
            deadline: now.addingTimeInterval(120), warningSeconds: 120, awaitingSince: now)
        m.cancelWarning()
        try stub.waitForRequest()
        m.skipNextSleep()
        stub.respond()
        try pump { !m.cancellingWarning }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(stub.requests.map(\.command) == ["cancel"],
                   "Cancelling tonight also queued a skip for tomorrow")
    }

    static func saveThenSkip() throws {
        let submitted = Settings(hour: 21)
        let stub = StubService([.success(response(submitted))])
        let m = model(stub, draft: submitted)
        let now = Date()
        m.state?.pending = PendingWarning(id: "active-warning", day: "test", scheduledAt: now,
            deadline: now.addingTimeInterval(120), warningSeconds: 120, awaitingSince: now)
        m.save()
        try stub.waitForRequest()
        m.skipNextSleep()
        stub.respond()
        try pump { !m.saving }
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(stub.requests.map(\.command) == ["settings"],
                   "Saving during tonight's warning also queued a skip for tomorrow")
    }

    static func pausePreservesEdits() throws {
        let paused = Settings(enabled: false)
        let stub = StubService([.success(response(paused))])
        let unfinished = Settings(hour: 23, minute: 45, chimeEnabled: true)
        let m = model(stub, draft: unfinished)
        var saved: Bool?
        m.pauseDailySleep { saved = $0 }
        try stub.waitForRequest()
        try expect(stub.requests.first?.settings == paused, "Menu pause saved unfinished time or chime edits")
        stub.respond()
        try pump { saved != nil }
        try expect(saved == true && m.state?.settings == paused, "Pause was not confirmed")
        try expect(m.isDirty && m.draft.hour == 23 && m.draft.minute == 45 && m.draft.chimeEnabled,
                   "Pause lost unfinished edits")
        try expect(!m.draft.enabled, "The draft must reflect the requested pause")
    }

    static func failedPause() throws {
        let stub = StubService([.failure(TestFailure.failed("Unavailable"))])
        let m = model(stub)
        var saved: Bool?
        m.pauseDailySleep { saved = $0 }
        try stub.waitForRequest()
        stub.respond()
        try pump { saved != nil }
        try expect(saved == false && m.message == "Unavailable" && !m.saving,
                   "A failed pause must stay visible and allow a retry")
    }

    static func pollBackpressure() throws {
        let stub = StubService([.success(response()), .success(response())])
        let m = model(stub)
        let now = Date()
        m.state?.pending = PendingWarning(id: "active-warning", day: "test", scheduledAt: now,
            deadline: now.addingTimeInterval(120), warningSeconds: 120, awaitingSince: now)
        m.save()
        try stub.waitForRequest()
        m.cancelWarning()
        stub.respond()
        try stub.waitForRequest()
        try pump { !m.saving }
        m.poll()
        stub.respond()
        try pump { !m.cancellingWarning }
        // Let an incorrectly queued poll reach the fake transport as well.
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        try expect(stub.requests.map(\.command) == ["settings", "cancel"],
                   "A poll was admitted while another user action was still queued")
    }

    static func menuTrackingHeartbeat() throws {
        let stub = StubService([.success(response()), .success(response())])
        let m = model(stub)
        var updates = 0
        m.onUpdate = { updates += 1 }
        m.start()
        try stub.waitForRequest()
        stub.respond()
        try pump { updates == 1 }

        // A CLI test does not start AppKit's event loop. Register its menu mode
        // as common explicitly, then run that mode instead of the default one.
        CFRunLoopAddCommonMode(CFRunLoopGetMain(),
                               CFRunLoopMode(rawValue: RunLoop.Mode.eventTracking.rawValue as CFString))
        let deadline = Date().addingTimeInterval(2)
        while stub.requests.count < 2, Date() < deadline {
            RunLoop.main.run(mode: .eventTracking, before: deadline)
        }
        try expect(stub.requests.count == 2, "The menu-tracking mode suspended the poll heartbeat")
        stub.respond()
        try pump { updates == 2 }
    }

    static func visibleWithoutKeyboardFocus() throws {
        for input in [WarningPresentation.InputAvailability.mouse, .keyboardAndMouse] {
            try expect(WarningPresentation(visibleOnCurrentDesktop: true, input: input).canAcknowledge,
                       "A visible warning with mouse cancellation must remain eligible without keyboard focus")
            try expect(!WarningPresentation(visibleOnCurrentDesktop: false, input: input).canAcknowledge,
                       "A hidden, occluded, or off-desktop warning must not acknowledge presentation")
        }
        try expect(!WarningPresentation(visibleOnCurrentDesktop: true, input: .blocked).canAcknowledge,
                   "A modal, mouse-disabled, or disabled cancellation control must not approve sleep")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let target = calendar.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 20, minute: 30))!
        let start = target.addingTimeInterval(-30)
        let engine = ScheduleEngine(state: EngineState(settings: Settings(warningSeconds: 30)),
                                    now: start.addingTimeInterval(-1), calendar: calendar)
        _ = engine.tick(now: start, consoleUID: 501, presence: nil)
        let id = engine.state.pending!.id
        for second in 1...31 {
            let now = start.addingTimeInterval(Double(second))
            let presentation = WarningPresentation(visibleOnCurrentDesktop: true,
                input: second < 10 ? .keyboardAndMouse : .mouse)
            let presence = AgentPresence(uid: 501, sessionID: "focus-test", lastSeen: now,
                isUsable: true, visibleWarningID: presentation.canAcknowledge ? id : nil)
            try expect(engine.tick(now: now, consoleUID: 501, presence: presence) == (second == 31),
                       "Continuing in another app must not reset or cancel a visible warning's full countdown")
        }
    }
}
