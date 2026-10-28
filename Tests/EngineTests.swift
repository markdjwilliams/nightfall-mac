import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

private func expect(_ condition: @autoclosure () -> Bool, _ message: String,
                    file: StaticString = #filePath, line: UInt = #line) throws {
    if !condition() { throw TestFailure(description: "\(file):\(line): \(message)") }
}

private var vancouver: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Vancouver")!
    return calendar
}

private func date(_ year: Int = 2026, _ month: Int = 10, _ day: Int = 28,
                  _ hour: Int = 20, _ minute: Int = 30, _ second: Int = 0) -> Date {
    vancouver.date(from: DateComponents(year: year, month: month, day: day,
                                        hour: hour, minute: minute, second: second))!
}

private func agent(_ now: Date, uid: UInt32 = 501, session: String = "session-a",
                   visible: String? = nil, usable: Bool = true) -> AgentPresence {
    AgentPresence(uid: uid, sessionID: session, lastSeen: now,
                  isUsable: usable, visibleWarningID: visible)
}

private func warningDate(_ seconds: Double = 0, target: Date = date(), warningSeconds: Int = 30) -> Date {
    target.addingTimeInterval(seconds - Double(warningSeconds))
}

private func engine(_ now: Date = warningDate(-5),
                    settings: Settings = Settings(warningSeconds: 30)) -> ScheduleEngine {
    ScheduleEngine(state: EngineState(settings: settings), now: now, calendar: vancouver)
}

private func trigger(_ engine: ScheduleEngine, at due: Date = date()) throws -> String {
    let start = warningDate(target: due, warningSeconds: engine.state.settings.warningSeconds)
    try expect(!engine.tick(now: start, consoleUID: 501, presence: agent(start)),
               "Creating the warning must not request sleep")
    guard let id = engine.state.pending?.id else { throw TestFailure(description: "Expected pending warning") }
    return id
}

private func visibleTicks(_ engine: ScheduleEngine, id: String, due: Date = date(),
                          seconds: ClosedRange<Int>, uid: UInt32 = 501,
                          session: String = "session-a", sleepAt: Int? = nil) throws {
    for second in seconds {
        let now = warningDate(Double(second), target: due, warningSeconds: engine.state.settings.warningSeconds)
        let requested = engine.tick(now: now, consoleUID: uid,
                                    presence: agent(now, uid: uid, session: session, visible: id))
        try expect(requested == (sleepAt == second), "Unexpected sleep request at second \(second)")
    }
}

@main
private enum EngineTests {
    static func main() throws {
        let tests: [(String, () throws -> Void)] = [
            ("defaults and validation", defaultsAndValidation),
            ("legacy audio settings migrate silently", legacyAudioSettings),
            ("explicit chime settings roundtrip", chimeSettingsRoundtrip),
            ("configured time is the intended sleep time", intendedSleepTime),
            ("warnings crossing midnight use the target sleep date", midnightWarning),
            ("warning acknowledgment starts full countdown", acknowledgmentCountdown),
            ("skip today and resume tomorrow", skipTodayOnly),
            ("cancel current warning only", cancelWarning),
            ("switch active users and sessions", switchUsers),
            ("missing unseen unusable and stale agents", missingAgents),
            ("lost visibility resets the full countdown", lostVisibility),
            ("fresh visible active agent required at deadline", deadlineSafety),
            ("pause during countdown skips occurrence", countdownPause),
            ("missed startup and wake do not catch up", missedSchedule),
            ("persisted warning restarts safely", restartSafety),
            ("settings changes cancel and invalid settings do not mutate", settingsChanges),
            ("clock rollback and persisted day history", clockRollback),
            ("daylight saving calendar behavior", daylightSaving),
            ("failure outcome preserves consumption", failureOutcome)
        ]
        for (name, test) in tests {
            try test()
            print("PASS \(name)")
        }
        print("\(tests.count) scheduling safety tests passed.")
    }

    static func defaultsAndValidation() throws {
        let settings = Settings()
        try expect(settings.enabled && settings.hour == 20 && settings.minute == 30,
                   "Default must be enabled at 8:30 p.m.")
        try expect(settings.warningSeconds == 120 && !settings.chimeEnabled,
                   "Default must include a two-minute silent warning")
        try settings.validate()
        for invalid in [Settings(hour: -1), Settings(hour: 24), Settings(minute: -1),
                        Settings(minute: 60), Settings(warningSeconds: 29), Settings(warningSeconds: 601)] {
            do {
                try invalid.validate()
                throw TestFailure(description: "Invalid settings were accepted")
            } catch is Settings.ValidationError { }
        }
        try Settings(hour: 0, minute: 0, warningSeconds: 30).validate()
        try Settings(hour: 23, minute: 59, warningSeconds: 600).validate()
    }

    static func legacyAudioSettings() throws {
        let expected = Settings(enabled: false, hour: 21, minute: 15, warningSeconds: 60)
        let base: [String: Any] = ["enabled": false, "hour": 21, "minute": 15, "warningSeconds": 60]
        for spoken in [true, false] {
            var legacy = base
            legacy["spokenWarning"] = spoken
            let decoded = try JSONDecoder().decode(Settings.self,
                from: JSONSerialization.data(withJSONObject: legacy))
            try expect(decoded == expected,
                       "Legacy speech set to \(spoken) must preserve schedule settings with the chime off")
        }
        let withoutAudio = try JSONDecoder().decode(Settings.self,
            from: JSONSerialization.data(withJSONObject: base))
        try expect(withoutAudio == expected, "Missing audio preferences must default to silence")

        for key in ["enabled", "hour", "minute", "warningSeconds"] {
            var incomplete = base
            incomplete.removeValue(forKey: key)
            do {
                _ = try JSONDecoder().decode(Settings.self,
                    from: JSONSerialization.data(withJSONObject: incomplete))
                throw TestFailure(description: "Missing required \(key) was accepted")
            } catch DecodingError.keyNotFound { }
        }
    }

    static func chimeSettingsRoundtrip() throws {
        for enabled in [true, false] {
            let settings = Settings(enabled: false, hour: 22, minute: 45,
                                    warningSeconds: 90, chimeEnabled: enabled)
            let encoded = try JSONEncoder().encode(settings)
            let decoded = try JSONDecoder().decode(Settings.self, from: encoded)
            try expect(decoded == settings, "Explicit chime preference must survive a save and reload")
            var object = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
            try expect(object["chimeEnabled"] as? Bool == enabled && object["spokenWarning"] == nil,
                       "Saved settings must contain only the new audio preference")
            object["spokenWarning"] = !enabled
            let mixed = try JSONDecoder().decode(Settings.self,
                from: JSONSerialization.data(withJSONObject: object))
            try expect(mixed == settings, "An explicit chime preference must take precedence over legacy speech")
        }
    }

    static func intendedSleepTime() throws {
        let target = date()
        let start = warningDate(target: target, warningSeconds: 120)
        let e = engine(start.addingTimeInterval(-1), settings: Settings())
        try expect(!e.tick(now: start.addingTimeInterval(-1), consoleUID: 501,
                           presence: agent(start.addingTimeInterval(-1))), "Warning must not begin early")
        try expect(e.state.pending == nil, "No warning before 8:28 p.m. by default")
        let id = try trigger(e)
        try expect(e.state.pending?.scheduledAt == target && e.state.pending?.deadline == target,
                   "The configured 8:30 p.m. time must be the intended sleep time")
        try visibleTicks(e, id: id, seconds: 0...120, sleepAt: 120)
        try expect(e.state.lastOutcome?.date == target, "Timely presentation should sleep at the configured time")

        let late = start.addingTimeInterval(60)
        let delayed = engine(late, settings: Settings())
        try expect(!delayed.tick(now: late, consoleUID: 501, presence: agent(late)),
                   "A late warning must not request immediate sleep")
        let lateID = delayed.state.pending!.id
        try visibleTicks(delayed, id: lateID, seconds: 61...180)
        try expect(delayed.state.pending?.deadline == target.addingTimeInterval(61),
                   "Late presentation still receives the full two-minute countdown")
        try visibleTicks(delayed, id: lateID, seconds: 181...181, sleepAt: 181)
    }

    static func midnightWarning() throws {
        let target = date(2026, 10, 29, 0, 1)
        let start = warningDate(target: target, warningSeconds: 120)
        let settings = Settings(hour: 0, minute: 1)
        let e = engine(start.addingTimeInterval(-1), settings: settings)
        try expect(e.nextRun(after: start.addingTimeInterval(-1)) == target,
                   "Next run is the intended 12:01 a.m. sleep time")
        let id = try trigger(e, at: target)
        try expect(e.state.pending?.day == "2026-10-29" && e.state.pending?.scheduledAt == target,
                   "A 11:59 p.m. warning belongs to the following sleep date")
        try expect(e.nextRun(after: start) == date(2026, 10, 30, 0, 1),
                   "The pending target date must be excluded from next run")
        try visibleTicks(e, id: id, due: target, seconds: 0...120, sleepAt: 120)
        try expect(e.state.lastOutcome?.day == "2026-10-29", "Cross-midnight warning may complete normally")

        let skipped = engine(start.addingTimeInterval(-1), settings: settings)
        _ = try trigger(skipped, at: target)
        skipped.skipTonight(now: start.addingTimeInterval(1))
        try expect(skipped.state.pending == nil && skipped.state.lastOutcome?.day == "2026-10-29",
                   "Skip must consume a pending tomorrow target when its warning starts tonight")
        try expect(!skipped.tick(now: target, consoleUID: 501, presence: agent(target)),
                   "A pending target skipped before midnight must not reappear after midnight")
        try expect(skipped.state.pending == nil && skipped.nextRun(after: target) == date(2026, 10, 30, 0, 1),
                   "Cross-midnight skip must last for exactly the target date")

        let beforeWarning = engine(date(2026, 10, 28, 12), settings: settings)
        beforeWarning.skipTonight(now: date(2026, 10, 28, 12))
        try expect(beforeWarning.state.lastOutcome?.day == "2026-10-28" &&
                   !beforeWarning.state.handledDays.contains("2026-10-29"),
                   "Before a warning, skip applies to today's intended event")
        _ = try trigger(beforeWarning, at: target)

        let missed = engine(start.addingTimeInterval(91), settings: settings)
        try expect(missed.state.handledDays.contains("2026-10-29") && missed.state.pending == nil,
                   "A missed cross-midnight warning must consume its target date even before sleep is due")

        // A late presentation or user switch can also move the end of a late-
        // evening countdown past midnight. Its original target remains consumed.
        let eveningTarget = date(2026, 10, 28, 23, 59)
        let evening = engine(warningDate(-1, target: eveningTarget, warningSeconds: 120),
                             settings: Settings(hour: 23, minute: 59))
        let eveningID = try trigger(evening, at: eveningTarget)
        try visibleTicks(evening, id: eveningID, due: eveningTarget, seconds: 0...119)
        let switched = eveningTarget
        try expect(!evening.tick(now: switched, consoleUID: 502,
                                presence: agent(switched, uid: 502, session: "evening-b")),
                   "A user switch at the target time still requires a full warning")
        try visibleTicks(evening, id: eveningID, due: eveningTarget, seconds: 121...241,
                         uid: 502, session: "evening-b", sleepAt: 241)
        try expect(evening.state.lastOutcome?.day == "2026-10-28" &&
                   evening.state.lastOutcome?.date == date(2026, 10, 29, 0, 1, 1),
                   "A continuously visible full countdown may safely finish after the target day ends")
    }

    static func acknowledgmentCountdown() throws {
        let e = engine()
        let id = try trigger(e)
        try expect(e.state.handledDays == ["2026-10-28"], "Persist consumption before presenting")
        let t1 = warningDate(1)
        try expect(!e.tick(now: t1, consoleUID: 501, presence: agent(t1)), "Unseen warning cannot sleep")
        try visibleTicks(e, id: id, seconds: 2...31)
        try expect(e.state.pending?.deadline == warningDate(32),
                   "Full countdown begins when the warning is acknowledged visible")
        try visibleTicks(e, id: id, seconds: 32...33, sleepAt: 32)
        try expect(e.state.pending == nil && e.state.lastOutcome?.message == "Requested scheduled sleep.",
                   "Consume and clear pending before returning a sleep request")
    }

    static func skipTodayOnly() throws {
        let e = engine()
        e.skipTonight(now: warningDate(-5))
        try expect(!e.tick(now: date(), consoleUID: 501, presence: agent(date())), "Skip must suppress today")
        try expect(e.state.pending == nil, "Skipped date cannot create a warning")
        let tomorrow = date(2026, 10, 29)
        try expect(e.nextRun(after: warningDate(-4)) == tomorrow, "Next run must be tomorrow")
        _ = try trigger(e, at: tomorrow)
        try expect(e.state.pending?.day == "2026-10-29", "Skip must not disable the next date")
    }

    static func cancelWarning() throws {
        let e = engine()
        let id = try trigger(e)
        e.cancelWarning(id: "older-warning", now: warningDate(1))
        try expect(e.state.pending?.id == id, "Stale cancellation must not cancel a new warning")
        e.cancelWarning(id: id, now: warningDate(2))
        try expect(e.state.pending == nil, "Current cancellation must clear warning")
        try expect(!e.tick(now: warningDate(3), consoleUID: 501,
                           presence: agent(warningDate(3), visible: id)),
                   "Canceled warning must never request sleep")
        try expect(e.nextRun(after: date()) == date(2026, 10, 29), "Cancel must preserve tomorrow")
    }

    static func switchUsers() throws {
        for newUID: UInt32 in [501, 502] {
            let e = engine()
            let id = try trigger(e)
            try visibleTicks(e, id: id, seconds: 1...20)
            let switched = warningDate(21)
            try expect(!e.tick(now: switched, consoleUID: newUID,
                               presence: agent(switched, uid: newUID, session: "session-b")),
                       "A session switch cannot sleep")
            try expect(e.state.pending?.recipientUID == newUID &&
                       e.state.pending?.recipientSessionID == "session-b" &&
                       e.state.pending?.presented == false, "New user or login session must acknowledge")
            try visibleTicks(e, id: id, seconds: 22...51, uid: newUID, session: "session-b")
            try expect(e.state.pending?.deadline == warningDate(52),
                       "New user must receive the full countdown")
            try visibleTicks(e, id: id, seconds: 52...52, uid: newUID, session: "session-b", sleepAt: 52)
        }
    }

    static func missingAgents() throws {
        for kind in ["missing", "unseen", "unusable", "stale", "wrong-user", "future-heartbeat"] {
            let e = engine()
            let id = try trigger(e)
            for second in 1...11 {
                let now = warningDate(Double(second))
                var presence: AgentPresence?
                switch kind {
                case "missing": presence = nil
                case "unseen": presence = agent(now)
                case "unusable": presence = agent(now, visible: id, usable: false)
                case "stale": presence = agent(now.addingTimeInterval(-5), visible: id)
                case "wrong-user": presence = agent(now, uid: 502, visible: id)
                default: presence = agent(now.addingTimeInterval(1), visible: id)
                }
                try expect(!e.tick(now: now, consoleUID: 501, presence: presence),
                           "\(kind) agent must never cause sleep")
            }
            try expect(e.state.pending == nil && e.state.lastOutcome != nil,
                       "\(kind) agent must skip after ten seconds without presentation")
        }
        let switching = engine()
        _ = try trigger(switching)
        for second in 1...11 {
            let now = warningDate(Double(second))
            try expect(!switching.tick(now: now, consoleUID: UInt32(501 + second % 2), presence: nil),
                       "Repeated console changes with no warning must not sleep")
        }
        try expect(switching.state.pending == nil,
                   "Repeated user changes must not extend an unseen warning indefinitely")
    }

    static func lostVisibility() throws {
        let e = engine()
        let id = try trigger(e)
        try visibleTicks(e, id: id, seconds: 1...10)
        let missing = warningDate(11)
        try expect(!e.tick(now: missing, consoleUID: 501, presence: agent(missing)), "Hidden warning cannot sleep")
        try expect(e.state.pending?.presented == false, "Visibility loss must stop countdown")
        try visibleTicks(e, id: id, seconds: 12...41)
        try expect(e.state.pending?.deadline == warningDate(42),
                   "Recovered warning must begin a new full countdown")
        try visibleTicks(e, id: id, seconds: 42...42, sleepAt: 42)
    }

    static func deadlineSafety() throws {
        for kind in ["stale", "unusable", "hidden", "wrong-user", "missing-console"] {
            let e = engine()
            let id = try trigger(e)
            try visibleTicks(e, id: id, seconds: 1...30)
            for second in 31...41 {
                let now = warningDate(Double(second))
                var presence = agent(now, visible: id)
                var consoleUID: UInt32? = 501
                switch kind {
                case "stale": presence.lastSeen = now.addingTimeInterval(-5)
                case "unusable": presence.isUsable = false
                case "hidden": presence.visibleWarningID = nil
                case "wrong-user": presence.uid = 502
                default: consoleUID = nil
                }
                try expect(!e.tick(now: now, consoleUID: consoleUID, presence: presence),
                           "\(kind) at deadline must prevent sleep")
            }
            // Console changes begin their own ten-second presentation grace.
            if e.state.pending != nil {
                let now = warningDate(42)
                try expect(!e.tick(now: now, consoleUID: nil, presence: nil), "Unavailable console must not sleep")
            }
            try expect(e.state.pending == nil, "Unavailable deadline must eventually skip")
        }
    }

    static func countdownPause() throws {
        let e = engine()
        let id = try trigger(e)
        try visibleTicks(e, id: id, seconds: 1...1)
        let wake = warningDate(32)
        try expect(!e.tick(now: wake, consoleUID: 501, presence: agent(wake, visible: id)),
                   "Wake after the deadline must not sleep immediately")
        try expect(e.state.pending == nil && e.state.lastOutcome?.message.contains("paused") == true,
                   "A countdown pause must leave an explanatory skip")
    }

    static func missedSchedule() throws {
        let late = warningDate(91)
        let awake = engine(warningDate(-60))
        try expect(!awake.tick(now: late, consoleUID: 501, presence: agent(late)), "Missed wake must skip")
        try expect(awake.state.pending == nil && awake.state.handledDays.contains("2026-10-28"),
                   "Missed wake must consume today")
        let startup = engine(late)
        try expect(startup.state.pending == nil && startup.state.handledDays.contains("2026-10-28"),
                   "Missed startup must consume today before any tick")
        try expect(startup.nextRun(after: late) == date(2026, 10, 29), "Late startup must wait until tomorrow")
        let allowed = engine(warningDate(90))
        try expect(!allowed.tick(now: warningDate(90), consoleUID: 501,
                                 presence: agent(warningDate(90))), "Late startup still must warn")
        try expect(allowed.state.pending != nil, "A delay within ninety seconds may begin a fresh warning")
    }

    static func restartSafety() throws {
        let e = engine()
        let id = try trigger(e)
        try visibleTicks(e, id: id, seconds: 1...5)
        let encoded = try JSONEncoder().encode(e.state)
        let saved = try JSONDecoder().decode(EngineState.self, from: encoded)
        let restarted = ScheduleEngine(state: saved, now: warningDate(6), calendar: vancouver)
        try expect(restarted.state.pending == nil && restarted.state.lastOutcome?.message.contains("restarted") == true,
                   "A persisted warning must be canceled on restart")
        try expect(!restarted.tick(now: warningDate(7), consoleUID: 501,
                                   presence: agent(warningDate(7), visible: id)),
                   "An acknowledged pre-restart warning must never fire")
        var legacy = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        legacy.removeValue(forKey: "handledDays")
        let legacyState = try JSONDecoder().decode(EngineState.self,
                                                   from: JSONSerialization.data(withJSONObject: legacy))
        let legacyRestart = ScheduleEngine(state: legacyState, now: warningDate(6), calendar: vancouver)
        try expect(legacyRestart.state.handledDays.contains("2026-10-28"), "Legacy persisted pending must consume its date")
    }

    static func settingsChanges() throws {
        let e = engine()
        _ = try trigger(e)
        let before = e.state
        do {
            try e.updateSettings(Settings(warningSeconds: 1), now: warningDate(1))
            throw TestFailure(description: "Invalid settings were accepted")
        } catch is Settings.ValidationError { }
        try expect(e.state == before, "Invalid settings must leave warning and settings unchanged")
        try e.updateSettings(Settings(hour: 21, warningSeconds: 30), now: warningDate(2))
        try expect(e.state.pending == nil, "Changing settings must cancel a pending warning")
        let later = date(2026, 10, 28, 21)
        try expect(!e.tick(now: later, consoleUID: 501, presence: agent(later)), "Reconfiguring must not repeat today")
        try expect(e.state.pending == nil && e.nextRun(after: later) == date(2026, 10, 29, 21),
                   "New time applies on the next unconsumed date")
        try e.updateSettings(Settings(enabled: false), now: later)
        try expect(e.nextRun(after: later) == nil, "Disabled schedule must have no next run")
    }

    static func clockRollback() throws {
        let e = engine()
        let id = try trigger(e)
        try visibleTicks(e, id: id, seconds: 1...5)
        let backward = warningDate(-1)
        try expect(!e.tick(now: backward, consoleUID: 501, presence: agent(backward, visible: id)),
                   "Clock rollback must cancel the countdown")
        try expect(e.state.pending == nil, "Clock rollback must clear pending")
        let tomorrow = date(2026, 10, 29)
        _ = try trigger(e, at: tomorrow)
        e.skipTonight(now: tomorrow)
        let saved = try JSONDecoder().decode(EngineState.self, from: JSONEncoder().encode(e.state))
        let restarted = ScheduleEngine(state: saved, now: backward, calendar: vancouver)
        try expect(!restarted.tick(now: date(), consoleUID: 501, presence: agent(date())),
                   "Rollback across restart must not repeat an earlier handled date")
        try expect(restarted.state.pending == nil && restarted.nextRun(after: backward) == date(2026, 10, 30),
                   "History must remember multiple handled dates after rollback")
    }

    static func daylightSaving() throws {
        let spring = engine(date(2025, 3, 8, 12), settings: Settings(hour: 2, minute: 30, warningSeconds: 30))
        let springRun = spring.nextRun(after: date(2025, 3, 8, 12))!
        let components = vancouver.dateComponents([.year, .month, .day, .hour, .minute], from: springRun)
        try expect(components.year == 2025 && components.month == 3 && components.day == 9 &&
                   components.hour == 3 && components.minute == 0,
                   "A nonexistent local time must use the calendar's next valid time")
        _ = try trigger(spring, at: springRun)
        spring.skipTonight(now: springRun)
        try expect(spring.nextRun(after: springRun) == date(2025, 3, 10, 2, 30),
                   "The next date must return to the configured wall-clock time")

        let fall = engine(date(2025, 11, 1, 12), settings: Settings(hour: 1, minute: 30, warningSeconds: 30))
        let fallRun = fall.nextRun(after: date(2025, 11, 1, 12))!
        try expect(vancouver.timeZone.secondsFromGMT(for: fallRun) == -7 * 3600,
                   "A repeated local time must choose its first occurrence")
        _ = try trigger(fall, at: fallRun)
        fall.skipTonight(now: fallRun)
        let repeated = fallRun.addingTimeInterval(3600)
        try expect(!fall.tick(now: repeated, consoleUID: 501, presence: agent(repeated)),
                   "The repeated local hour must not create a second occurrence")
        try expect(fall.state.pending == nil && fall.nextRun(after: fallRun) == date(2025, 11, 3, 1, 30),
                   "Fall-back date must be handled only once")
    }

    static func failureOutcome() throws {
        let e = engine()
        let id = try trigger(e)
        try visibleTicks(e, id: id, seconds: 1...31, sleepAt: 31)
        e.recordFailure("Sleep request was declined.", now: warningDate(32))
        try expect(e.state.lastOutcome?.message == "Sleep request was declined.", "Failure must be recorded")
        try expect(!e.tick(now: warningDate(33), consoleUID: 501,
                           presence: agent(warningDate(33), visible: id)), "Failure must not cause a retry")
        var legacy = e.state
        legacy.handledDays = []
        let restarted = ScheduleEngine(state: legacy, now: warningDate(34), calendar: vancouver)
        try expect(!restarted.tick(now: warningDate(35), consoleUID: 501,
                                   presence: agent(warningDate(35))),
                   "A persisted outcome must prevent repeats even without the day history")
        try expect(restarted.state.pending == nil, "A completed occurrence cannot reappear after restart")
    }
}
