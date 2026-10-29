import Foundation

/// A state machine with no storage, UI, or power API calls. One owner serializes
/// access, persists state changes, and suppresses power requests if saving fails.
/// A `true` tick permits one power attempt after persistence and a final owner-side
/// check that the console owner and authorization evidence are still current.
public final class ScheduleEngine {
    public private(set) var state: EngineState
    private var calendar: Calendar
    private var lastTick: Date
    private var lastUptime: TimeInterval?
    private var unattendedStartUptime: TimeInterval?
    // Cumulative wall/monotonic elapsed-time difference for the current warning.
    // It is transient: restoring a persisted warning always consumes it safely.
    private var warningClockDrift: TimeInterval = 0
    private let presentationGrace: TimeInterval = 10
    private let freshness: TimeInterval = 4
    private let maximumLateness: TimeInterval = 90

    /// Restores a snapshot without resuming interrupted warnings. Production
    /// owners supply monotonic uptime here and on every tick; omitting it leaves
    /// clock-drift detection unavailable, as in tests that supply wall time alone.
    public init(state: EngineState, now: Date, calendar: Calendar = .autoupdatingCurrent,
                uptime: TimeInterval? = nil) {
        self.state = state
        self.calendar = calendar
        self.lastTick = now
        self.lastUptime = uptime
        if let outcome = state.lastOutcome { markHandled(outcome.day) }
        if let pending = state.pending {
            finish(day: pending.day, now: now,
                   message: "Skipped because Nightfall restarted during the warning.")
        }
        do {
            try self.state.settings.validate()
        } catch {
            self.state.settings = Settings(enabled: false)
            finish(day: dayKey(now), now: now,
                   message: "Schedule disabled because its saved settings were invalid.")
        }
        skipMissedOccurrence(now: now)
    }

    /// Returns true at most once per target date after a full visible countdown or
    /// continuously verified unattended interval. The target is consumed first.
    /// Sample wall time, uptime, and system presence close together; uptime also
    /// prevents clock adjustments from shortening an unattended interval.
    @discardableResult
    public func tick(now: Date, consoleUID: UInt32?, presence: AgentPresence?,
                     uptime: TimeInterval? = nil, systemPresence: SystemPresence? = nil) -> Bool {
        let gap = now.timeIntervalSince(lastTick)
        let uptimeGap = uptime.flatMap { current in lastUptime.map { current - $0 } }
        lastTick = now
        lastUptime = uptime

        if let pending = state.pending {
            if gap < 0 {
                finish(day: pending.day, now: now,
                       message: "Skipped because the clock moved backward during the warning.")
                return false
            }
            // A small wall-clock adjustment can shorten the countdown without
            // exceeding the pause grace. Compare elapsed time on a monotonic
            // clock when supplied. Accumulation also catches several small
            // corrections; one second of tolerance allows normal sampling jitter.
            if let uptimeGap {
                warningClockDrift += gap - uptimeGap
                if !uptimeGap.isFinite || uptimeGap < 0 || abs(warningClockDrift) > 1 {
                    finish(day: pending.day, now: now,
                           message: "Skipped because the clock changed during the warning.")
                    return false
                }
            }
            if (pending.presented || pending.unattendedSince != nil) && gap > presentationGrace {
                finish(day: pending.day, now: now,
                       message: "Skipped because the Mac or schedule service paused during the warning.")
                return false
            }
            if pending.day != dayKey(pending.scheduledAt) {
                finish(day: pending.day, now: now,
                       message: "Skipped because the scheduled time zone or calendar changed during the warning.")
                return false
            }
            if pending.unattendedSince != nil {
                return advanceUnattended(now: now, consoleUID: consoleUID, presence: presence,
                                         uptime: uptime, systemPresence: systemPresence)
            }
            if beginUnattended(now: now, consoleUID: consoleUID, presence: presence,
                               uptime: uptime, systemPresence: systemPresence) {
                return false
            }
            return advanceWarning(now: now, consoleUID: consoleUID, presence: presence)
        }

        warningClockDrift = 0
        unattendedStartUptime = nil
        guard state.settings.enabled else { return false }
        for due in candidateSleepTimes(around: now) {
            let day = dayKey(due)
            let warningStart = due.addingTimeInterval(-TimeInterval(state.settings.warningSeconds))
            guard !isHandled(day), now >= warningStart else { continue }
            guard now.timeIntervalSince(warningStart) <= maximumLateness else {
                finish(day: day, now: now,
                       message: "Skipped because the Mac was unavailable when the sleep warning was due.")
                continue
            }

            // Consume the target sleep date before publishing the warning,
            // including when its warning starts on the previous calendar date.
            markHandled(day)
            let agent = usablePresence(presence, consoleUID: consoleUID, now: now)
            let unattended = systemPresence?.supportsUnattendedInterval(0) == true &&
                uptime.map { $0.isFinite && $0 >= 0 } == true
            if unattended { unattendedStartUptime = uptime }
            state.pending = PendingWarning(
                id: UUID().uuidString, day: day, scheduledAt: due,
                deadline: now.addingTimeInterval(TimeInterval(state.settings.warningSeconds)),
                warningSeconds: state.settings.warningSeconds,
                recipientUID: consoleUID, recipientSessionID: agent?.sessionID,
                awaitingSince: now, unattendedSince: unattended ? now : nil)
            break
        }
        return false
    }

    /// Validates before mutating and leaves identical settings untouched. A change
    /// consumes any pending warning; otherwise old-schedule misses are recorded
    /// before replacing settings.
    public func updateSettings(_ settings: Settings, now: Date) throws {
        try settings.validate()
        guard settings != state.settings else { return }
        if let pending = state.pending {
            finish(day: pending.day, now: now,
                   message: "Skipped because the schedule settings changed during the warning.")
        } else {
            skipMissedOccurrence(now: now)
        }
        state.settings = settings
    }

    /// Skips the pending warning or next eligible unhandled sleep, which may
    /// belong to tomorrow. Repeated calls can skip successive dates; an idle,
    /// disabled schedule is unchanged.
    public func skipTonight(now: Date) {
        if let pending = state.pending {
            finish(day: pending.day, now: now, message: "Skipped this scheduled sleep.")
            return
        }
        guard state.settings.enabled else { return }
        skipMissedOccurrence(now: now)

        // Before midnight, the next sleep can belong to tomorrow. A sleep time
        // that just passed may also still be eligible for its full warning.
        let due = candidateSleepTimes(around: now).first {
            !isHandled(dayKey($0)) &&
            now >= $0.addingTimeInterval(-TimeInterval(state.settings.warningSeconds))
        } ?? nextRun(after: now)
        guard let due else { return }
        finish(day: dayKey(due), now: now, message: "Skipped this scheduled sleep.")
    }

    /// Consumes only the matching warning, making stale or duplicate cancels harmless.
    public func cancelWarning(id: String, now: Date) {
        guard let pending = state.pending, pending.id == id else { return }
        finish(day: pending.day, now: now, message: "Skipped for today by the active user.")
    }

    /// Finds the next unhandled intended sleep time strictly after the argument.
    /// A pending warning is already handled; its possibly extended deadline is
    /// represented by `state.pending` instead of this schedule lookup.
    public func nextRun(after: Date) -> Date? {
        guard state.settings.enabled, (try? state.settings.validate()) != nil else { return nil }
        var cursor = after
        let components = DateComponents(hour: state.settings.hour, minute: state.settings.minute, second: 0)
        // Bound the search by saved history, with slack for a repeated local
        // hour at the initial cursor. Each match advances the search cursor.
        for _ in 0...(state.handledDays.count + 1) {
            guard let next = calendar.nextDate(after: cursor, matching: components,
                                               matchingPolicy: .nextTime,
                                               repeatedTimePolicy: .first,
                                               direction: .forward) else { return nil }
            if !isHandled(dayKey(next)) { return next }
            cursor = next
        }
        return nil
    }

    /// Records an owner-side failure after a sleep decision without reopening its occurrence.
    /// Reusing the recent outcome's target day preserves cross-midnight identity.
    public func recordFailure(_ message: String, now: Date) {
        let day: String
        if let outcome = state.lastOutcome, calendar.isDate(outcome.date, inSameDayAs: now) {
            day = outcome.day
        } else {
            day = dayKey(now)
        }
        finish(day: day, now: now, message: message)
    }

    /// Starts a new full interval only while the existing occurrence still has
    /// presentation grace. No time from a visible or revoked interval carries over.
    private func beginUnattended(now: Date, consoleUID: UInt32?, presence: AgentPresence?,
                                 uptime: TimeInterval?, systemPresence: SystemPresence?) -> Bool {
        guard var pending = state.pending,
              now.timeIntervalSince(pending.awaitingSince) <= presentationGrace,
              let uptime, uptime.isFinite, uptime >= 0,
              systemPresence?.supportsUnattendedInterval(0) == true else { return false }
        pending.unattendedSince = now
        pending.presented = false
        pending.recipientUID = consoleUID
        pending.recipientSessionID = usablePresence(presence, consoleUID: consoleUID, now: now)?.sessionID
        pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
        pending.awaitingSince = now
        unattendedStartUptime = uptime
        state.pending = pending
        return true
    }

    private func advanceUnattended(now: Date, consoleUID: UInt32?, presence: AgentPresence?,
                                   uptime: TimeInterval?, systemPresence: SystemPresence?) -> Bool {
        guard var pending = state.pending else { return false }
        let elapsed = uptime.flatMap { current in unattendedStartUptime.map { current - $0 } }
        if let elapsed, consoleUID == pending.recipientUID,
           systemPresence?.supportsUnattendedInterval(elapsed) == true {
            if now >= pending.deadline, elapsed >= TimeInterval(pending.warningSeconds),
               systemPresence?.supportsUnattendedInterval(TimeInterval(pending.warningSeconds)) == true {
                finish(day: pending.day, now: now, message: "Requested scheduled sleep.")
                return true
            }
            return false
        }

        // Discard this interval completely. A returning user receives fresh
        // presentation grace and a full visible warning. Later verified darkness
        // may begin another full unattended interval while this warning is pending.
        pending.unattendedSince = nil
        pending.presented = false
        pending.recipientUID = consoleUID
        pending.recipientSessionID = nil
        pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
        pending.awaitingSince = now
        unattendedStartUptime = nil
        state.pending = pending
        return advanceWarning(now: now, consoleUID: consoleUID, presence: presence)
    }

    private func advanceWarning(now: Date, consoleUID: UInt32?, presence: AgentPresence?) -> Bool {
        guard var pending = state.pending else { return false }
        let agent = usablePresence(presence, consoleUID: consoleUID, now: now)

        // Check grace before changing recipients: repeated user/session switches
        // must not indefinitely extend an unseen warning's presentation budget.
        if now.timeIntervalSince(pending.awaitingSince) > presentationGrace {
            let reason = agent == nil
                ? "Skipped because the active user did not have an available Nightfall app."
                : "Skipped because the active user could not see the sleep warning."
            finish(day: pending.day, now: now, message: reason)
            return false
        }

        // Both user changes and agent restarts require a new visible
        // acknowledgment before their full countdown can begin.
        if pending.recipientUID != consoleUID {
            pending.recipientUID = consoleUID
            pending.recipientSessionID = nil
            pending.presented = false
            pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
        }
        if let agent, pending.recipientSessionID != agent.sessionID {
            pending.recipientSessionID = agent.sessionID
            pending.presented = false
            pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
        }

        let visible = agent.map {
            $0.uid == pending.recipientUID &&
            $0.sessionID == pending.recipientSessionID &&
            $0.visibleWarningID == pending.id
        } ?? false

        if visible {
            if !pending.presented {
                pending.presented = true
                pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
            }
            pending.awaitingSince = now
            if now >= pending.deadline {
                finish(day: pending.day, now: now, message: "Requested scheduled sleep.")
                return true
            }
        } else if pending.presented {
            pending.presented = false
            pending.deadline = now.addingTimeInterval(TimeInterval(pending.warningSeconds))
        }

        state.pending = pending
        return false
    }

    private func usablePresence(_ presence: AgentPresence?, consoleUID: UInt32?, now: Date) -> AgentPresence? {
        guard let presence, let consoleUID,
              presence.uid == consoleUID, presence.isUsable, !presence.sessionID.isEmpty else { return nil }
        let age = now.timeIntervalSince(presence.lastSeen)
        guard age >= 0, age <= freshness else { return nil }
        return presence
    }

    /// Consumes missed warning starts without catching up with a late countdown.
    private func skipMissedOccurrence(now: Date) {
        guard state.settings.enabled else { return }
        for due in candidateSleepTimes(around: now) {
            let day = dayKey(due)
            let warningStart = due.addingTimeInterval(-TimeInterval(state.settings.warningSeconds))
            guard !isHandled(day), now.timeIntervalSince(warningStart) > maximumLateness else { continue }
            finish(day: day, now: now,
                   message: "Skipped because the Mac was unavailable when the sleep warning was due.")
        }
    }

    /// Includes tomorrow because its warning may start tonight. Calendar-day
    /// arithmetic also handles dates that contain fewer or more than 24 hours.
    private func candidateSleepTimes(around now: Date) -> [Date] {
        let start = calendar.startOfDay(for: now)
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return [scheduledTime(on: now), scheduledTime(on: tomorrow)].compactMap { $0 }
    }

    private func scheduledTime(on date: Date) -> Date? {
        guard (try? state.settings.validate()) != nil else { return nil }
        let start = calendar.startOfDay(for: date)
        // Start just before midnight so 00:00 is included. A missing local time
        // moves to the next valid time; a repeated time uses its first occurrence.
        return calendar.nextDate(after: start.addingTimeInterval(-1),
                                 matching: DateComponents(hour: state.settings.hour,
                                                          minute: state.settings.minute, second: 0),
                                 matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                 direction: .forward)
    }

    /// Local calendar date identity, independent of the warning's presentation date.
    private func dayKey(_ date: Date) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private func isHandled(_ day: String) -> Bool { state.handledDays.contains(day) }

    private func markHandled(_ day: String) {
        if !isHandled(day) { state.handledDays.append(day) }
    }

    private func finish(day: String, now: Date, message: String) {
        markHandled(day)
        state.pending = nil
        state.lastOutcome = LastOutcome(day: day, date: now, message: message)
    }
}
