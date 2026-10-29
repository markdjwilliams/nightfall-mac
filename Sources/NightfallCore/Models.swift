import Foundation

/// The shared schedule, interpreted in the engine calendar's local time zone.
/// Construction and decoding preserve values; callers validate before use.
public struct Settings: Codable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    /// Full interval for visible presentation or verified unattended observation.
    /// Late presentation can move sleep beyond the configured hour and minute.
    public var warningSeconds: Int
    public var chimeEnabled: Bool

    public init(enabled: Bool = true, hour: Int = 20, minute: Int = 30,
                warningSeconds: Int = 120, chimeEnabled: Bool = false) {
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.warningSeconds = warningSeconds
        self.chimeEnabled = chimeEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, hour, minute, warningSeconds, chimeEnabled
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        hour = try values.decode(Int.self, forKey: .hour)
        minute = try values.decode(Int.self, forKey: .minute)
        warningSeconds = try values.decode(Int.self, forKey: .warningSeconds)
        // Legacy spokenWarning is intentionally ignored: a previous speech
        // preference must never enable the replacement chime automatically.
        chimeEnabled = try values.decodeIfPresent(Bool.self, forKey: .chimeEnabled) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(enabled, forKey: .enabled)
        try values.encode(hour, forKey: .hour)
        try values.encode(minute, forKey: .minute)
        try values.encode(warningSeconds, forKey: .warningSeconds)
        try values.encode(chimeEnabled, forKey: .chimeEnabled)
    }

    public enum ValidationError: Error, LocalizedError {
        case invalidHour, invalidMinute, invalidWarningSeconds

        public var errorDescription: String? {
            switch self {
            case .invalidHour: return "The hour must be between 0 and 23."
            case .invalidMinute: return "The minute must be between 0 and 59."
            case .invalidWarningSeconds: return "The warning must last between 30 and 600 seconds."
            }
        }
    }

    public func validate() throws {
        guard (0...23).contains(hour) else { throw ValidationError.invalidHour }
        guard (0...59).contains(minute) else { throw ValidationError.invalidMinute }
        guard (30...600).contains(warningSeconds) else { throw ValidationError.invalidWarningSeconds }
    }
}

/// A consumed occurrence receiving presentation evidence or an independently
/// verified unattended countdown. Restoration skips it because continuity of
/// either route cannot be established across a service restart.
public struct PendingWarning: Codable, Equatable {
    public var id: String
    /// Target sleep date in the engine calendar, even if the warning starts yesterday.
    public var day: String
    /// Original intended sleep time, before presentation delays or user switches.
    public var scheduledAt: Date
    /// Wall-clock countdown end. The visible route restarts it when presentation is acknowledged.
    public var deadline: Date
    public var warningSeconds: Int
    public var recipientUID: UInt32?
    /// Identifies an agent instance so a new login or restarted app gets a full countdown.
    public var recipientSessionID: String?
    /// Start of the current presentation-grace period, then the latest engine
    /// time accepting visible evidence. Recipient changes alone do not renew grace.
    /// Unattended verification uses its separate start time instead of this grace.
    public var awaitingSince: Date
    /// Whether the latest engine step accepted visible presentation for this recipient.
    public var presented: Bool
    /// Start of the current countdown with all displays asleep and no later input.
    /// Revocation clears it; new verified darkness can start a full new interval
    /// only while this occurrence remains pending within its presentation grace.
    public var unattendedSince: Date?

    public init(id: String, day: String, scheduledAt: Date, deadline: Date,
                warningSeconds: Int, recipientUID: UInt32? = nil,
                recipientSessionID: String? = nil, awaitingSince: Date,
                presented: Bool = false, unattendedSince: Date? = nil) {
        self.id = id
        self.day = day
        self.scheduledAt = scheduledAt
        self.deadline = deadline
        self.warningSeconds = warningSeconds
        self.recipientUID = recipientUID
        self.recipientSessionID = recipientSessionID
        self.awaitingSince = awaitingSince
        self.presented = presented
        self.unattendedSince = unattendedSince
    }
}

/// Most recent consumption or power-request outcome. `day` identifies the target
/// sleep date; `date` records when the outcome happened and can fall on another day.
public struct LastOutcome: Codable, Equatable {
    public var day: String
    public var date: Date
    public var message: String

    public init(day: String, date: Date, message: String) {
        self.day = day
        self.date = date
        self.message = message
    }
}

/// Durable scheduler state. The owner saves mutations before attempting sleep.
public struct EngineState: Codable, Equatable {
    public var settings: Settings
    public var lastOutcome: LastOutcome?
    public var pending: PendingWarning?
    /// Consumed target-date keys, including any pending warning. History is kept
    /// across restarts and clock rollback; a UI's shortened snapshot is not a
    /// replacement for the full history when restoring the engine.
    public var handledDays: [String]

    public init(settings: Settings = Settings(), lastOutcome: LastOutcome? = nil,
                pending: PendingWarning? = nil, handledDays: [String] = []) {
        self.settings = settings
        self.lastOutcome = lastOutcome
        self.pending = pending
        self.handledDays = handledDays
    }

    private enum CodingKeys: String, CodingKey {
        case settings, lastOutcome, pending, handledDays
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        settings = try values.decode(Settings.self, forKey: .settings)
        lastOutcome = try values.decodeIfPresent(LastOutcome.self, forKey: .lastOutcome)
        pending = try values.decodeIfPresent(PendingWarning.self, forKey: .pending)
        handledDays = try values.decodeIfPresent([String].self, forKey: .handledDays) ?? []
    }
}

/// Transient presentation evidence. The owner obtains `uid` from the authenticated
/// peer and stamps `lastSeen` itself; the engine does not authenticate these values.
public struct AgentPresence: Equatable {
    public var uid: UInt32
    public var sessionID: String
    public var lastSeen: Date
    public var isUsable: Bool
    /// The warning the agent reports as visible and able to receive input.
    public var visibleWarningID: String?

    public init(uid: UInt32, sessionID: String, lastSeen: Date,
                isUsable: Bool, visibleWarningID: String? = nil) {
        self.uid = uid
        self.sessionID = sessionID
        self.lastSeen = lastSeen
        self.isUsable = isUsable
        self.visibleWarningID = visibleWarningID
    }
}

/// A fresh, trusted system sample obtained by the service, independently of the
/// per-user agent. Missing or invalid evidence cannot authorize unattended sleep.
public struct SystemPresence: Codable, Equatable {
    public var displaysAsleep: Bool
    public var idleSeconds: TimeInterval

    public init(displaysAsleep: Bool, idleSeconds: TimeInterval) {
        self.displaysAsleep = displaysAsleep
        self.idleSeconds = idleSeconds
    }

    /// Checks this sample's display/idle evidence only. The owner also verifies
    /// a stable console owner and uninterrupted observation before requesting sleep.
    public func supportsUnattendedInterval(_ seconds: TimeInterval) -> Bool {
        displaysAsleep && seconds.isFinite && seconds >= 0 &&
            idleSeconds.isFinite && idleSeconds >= seconds
    }
}
