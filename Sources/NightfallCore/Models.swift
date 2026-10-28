import Foundation

public struct Settings: Codable, Equatable {
    public var enabled: Bool
    public var hour: Int
    public var minute: Int
    public var warningSeconds: Int
    public var spokenWarning: Bool

    public init(enabled: Bool = true, hour: Int = 20, minute: Int = 30,
                warningSeconds: Int = 120, spokenWarning: Bool = true) {
        self.enabled = enabled
        self.hour = hour
        self.minute = minute
        self.warningSeconds = warningSeconds
        self.spokenWarning = spokenWarning
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

public struct PendingWarning: Codable, Equatable {
    public var id: String
    public var day: String
    public var scheduledAt: Date
    public var deadline: Date
    public var warningSeconds: Int
    public var recipientUID: UInt32?
    public var recipientSessionID: String?
    public var awaitingSince: Date
    public var presented: Bool

    public init(id: String, day: String, scheduledAt: Date, deadline: Date,
                warningSeconds: Int, recipientUID: UInt32? = nil,
                recipientSessionID: String? = nil, awaitingSince: Date,
                presented: Bool = false) {
        self.id = id
        self.day = day
        self.scheduledAt = scheduledAt
        self.deadline = deadline
        self.warningSeconds = warningSeconds
        self.recipientUID = recipientUID
        self.recipientSessionID = recipientSessionID
        self.awaitingSince = awaitingSince
        self.presented = presented
    }
}

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

public struct EngineState: Codable, Equatable {
    public var settings: Settings
    public var lastOutcome: LastOutcome?
    public var pending: PendingWarning?
    /// Day keys are retained so a clock rollback cannot repeat an occurrence.
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

public struct AgentPresence: Equatable {
    public var uid: UInt32
    public var sessionID: String
    public var lastSeen: Date
    public var isUsable: Bool
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
