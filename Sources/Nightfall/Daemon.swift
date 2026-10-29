import Foundation
import Darwin
import SystemConfiguration
import IOKit.pwr_mgt
import CoreGraphics

/// Reads system evidence independently of every user agent. Raw display values
/// are checked before converting to Bool: an error-like nonzero value is not
/// proof of sleep. Unknown input/display state cannot authorize unattended sleep.
struct SystemPresenceReader {
    struct Display {
        var id: UInt32
        var online: UInt32
        var asleep: UInt32
    }

    struct DisplaySnapshot {
        var reportedCount: UInt32
        var displays: [Display]
    }

    static let maximumDisplays: UInt32 = 128
    var readDisplays: () -> DisplaySnapshot? = SystemPresenceReader.systemDisplays
    var readIdleSeconds: () -> TimeInterval? = SystemPresenceReader.systemIdleSeconds

    func sample() -> SystemPresence? {
        guard let snapshot = readDisplays(), snapshot.reportedCount > 0,
              snapshot.reportedCount < Self.maximumDisplays,
              snapshot.displays.count == Int(snapshot.reportedCount),
              Set(snapshot.displays.map(\.id)).count == snapshot.displays.count,
              snapshot.displays.allSatisfy({ $0.id != 0 && $0.online == 1 && ($0.asleep == 0 || $0.asleep == 1) }),
              let idle = readIdleSeconds(), idle.isFinite, idle >= 0,
              idle < TimeInterval.greatestFiniteMagnitude else { return nil }
        return SystemPresence(displaysAsleep: snapshot.displays.allSatisfy { $0.asleep == 1 },
                              idleSeconds: idle)
    }

    static func unchangedDisplayInventory(_ initial: [UInt32], _ final: [UInt32]) -> Bool {
        initial.count == final.count && Set(initial) == Set(final)
    }

    static func systemDisplays() -> DisplaySnapshot? {
        var expectedCount: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &expectedCount) == .success,
              expectedCount > 0, expectedCount < maximumDisplays else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(expectedCount))
        var actualCount: UInt32 = 0
        guard CGGetOnlineDisplayList(expectedCount, &ids, &actualCount) == .success,
              actualCount == expectedCount else { return nil }
        // boolean_t is signed on ARM and unsigned on Intel. Preserve raw bits
        // so negative error-like values remain invalid instead of becoming true.
        let displays = ids.map {
            Display(id: $0, online: UInt32(truncatingIfNeeded: CGDisplayIsOnline($0)),
                    asleep: UInt32(truncatingIfNeeded: CGDisplayIsAsleep($0)))
        }
        // Display hot-plugging can replace one display without changing the
        // count. Re-enumerate with spare capacity and require the same ID set.
        // An at-cap inventory is rejected rather than assumed complete.
        var finalIDs = [CGDirectDisplayID](repeating: 0, count: Int(maximumDisplays))
        var finalCount: UInt32 = 0
        guard CGGetOnlineDisplayList(maximumDisplays, &finalIDs, &finalCount) == .success,
              finalCount == expectedCount,
              unchangedDisplayInventory(ids, Array(finalIDs.prefix(Int(finalCount)))) else { return nil }
        return DisplaySnapshot(reportedCount: actualCount, displays: displays)
    }

    static func systemIdleSeconds() -> TimeInterval? {
        guard let anyInput = CGEventType(rawValue: UInt32.max) else { return nil }
        // HID system state combines hardware sources and is documented for
        // daemons. Combined-session state would inspect only the caller's login.
        return CGEventSource.secondsSinceLastEventType(.hidSystemState, eventType: anyInput)
    }
}

/// Identifies the foreground desktop's user. A console UID alone does not prove
/// the desktop is unlocked or that its warning can receive input.
func currentConsoleUID() -> UInt32? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
          name != "loginwindow", name != "_mbsetupuser", uid >= 500 else { return nil }
    return uid
}

/// Owns one machine-wide schedule. Once serving, `queue` serializes the
/// engine, agent presence, and persistence metadata. Socket workers perform I/O
/// outside that queue and enter it only to handle a decoded request.
/// The lifetime file lock excludes another coordinator using the same storage.
final class NightfallDaemon {
    private let queue = DispatchQueue(label: "com.nightfall.mac.coordinator")
    private let engine: ScheduleEngine
    private let directory: String
    private let socketPath: String
    private let dryRun: Bool
    private let systemPresenceReader: SystemPresenceReader
    private var agents: [UInt32: AgentPresence] = [:]
    private var timer: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var lastSaved: EngineState?
    private var storageHealthy = true

    /// Inspects the opened inode, rather than trusting a second pathname lookup.
    /// A single file link rejects hard-linked aliases of the lock or saved state.
    private static func validateOwnedItem(_ fd: Int32, type: mode_t, name: String) throws {
        var information = stat()
        guard fstat(fd, &information) == 0 else { throw SocketError.system("Inspect \(name)", errno) }
        guard information.st_mode & S_IFMT == type,
              information.st_uid == geteuid(), information.st_mode & 0o022 == 0,
              type == S_IFDIR || information.st_nlink == 1 else {
            throw SocketError.system("Unsafe \(name) ownership, permissions, or file type", EPERM)
        }
    }

    /// Validates the fresh sample taken after persistence. Owner reads bracket
    /// that sample, and idle time must cover the whole unattended interval, not
    /// just the configured minimum. A stable absent console is allowed only with
    /// the same independently verified display/input evidence.
    static func verifiesUnattendedSleep(_ warning: PendingWarning, consoleBefore: UInt32?, consoleAfter: UInt32?,
                                       systemPresence: SystemPresence?, now: Date) -> Bool {
        guard let start = warning.unattendedSince else { return false }
        let elapsed = now.timeIntervalSince(start)
        return consoleBefore == warning.recipientUID && consoleAfter == consoleBefore &&
            elapsed.isFinite && elapsed >= TimeInterval(warning.warningSeconds) && now >= warning.deadline &&
            systemPresence?.supportsUnattendedInterval(max(TimeInterval(warning.warningSeconds), elapsed)) == true
    }

    init(directory: String, socketPath: String, dryRun: Bool,
         systemPresenceReader: SystemPresenceReader = SystemPresenceReader()) throws {
        self.directory = directory
        self.socketPath = socketPath
        self.dryRun = dryRun
        self.systemPresenceReader = systemPresenceReader
        guard dryRun || geteuid() == 0 else { throw SocketError.system("Service requires administrator installation", EPERM) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // The installer protects the parent directories; each launch also checks
        // the final directory and file inodes. openat anchors file lookup to this
        // directory descriptor, and O_NOFOLLOW rejects final-component symlinks.
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SocketError.system("Open state directory", errno) }
        defer { Darwin.close(directoryFD) }
        try Self.validateOwnedItem(directoryFD, type: S_IFDIR, name: "state directory")
        // Nonblocking opens let validation reject FIFOs without waiting for a peer.
        let openedLock = openat(directoryFD, "service.lock", O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard openedLock >= 0 else { throw SocketError.system("Open service lock", errno) }
        var retainLock = false
        defer { if !retainLock { Darwin.close(openedLock) } }
        try Self.validateOwnedItem(openedLock, type: S_IFREG, name: "service lock")
        guard flock(openedLock, LOCK_EX | LOCK_NB) == 0 else {
            throw SocketError.system("Another service is already running", EBUSY)
        }
        let state: EngineState
        let stateFD = openat(directoryFD, "state.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if stateFD >= 0 {
            let file = FileHandle(fileDescriptor: stateFD, closeOnDealloc: true)
            try Self.validateOwnedItem(stateFD, type: S_IFREG, name: "saved state")
            // Only a missing file permits defaults. Invalid or unreadable saved
            // state aborts startup rather than silently forgetting consumed dates.
            state = try Wire.decoder().decode(EngineState.self, from: file.readToEnd() ?? Data())
            try state.settings.validate()
        } else if errno == ENOENT {
            state = EngineState(settings: Settings(), lastOutcome: nil, pending: nil)
        } else {
            throw SocketError.system("Open saved state", errno)
        }
        engine = ScheduleEngine(state: state, now: Date(), uptime: ProcessInfo.processInfo.systemUptime)
        lockFD = openedLock
        retainLock = true
    }

    deinit {
        timer?.cancel()
        if lockFD >= 0 { Darwin.close(lockFD) }
    }

    /// Called during startup, then only on the coordinator queue once serving.
    /// A failed write leaves in-memory state intact for a later retry, but callers
    /// must not request sleep on `false`.
    private func persist() -> Bool {
        if lastSaved == engine.state && storageHealthy { return true }
        do {
            let data = try Wire.encoder().encode(engine.state)
            try data.write(to: URL(fileURLWithPath: directory + "/state.json"), options: .atomic)
            chmod(directory + "/state.json", 0o600)
            lastSaved = engine.state
            storageHealthy = true
            return true
        } catch {
            storageHealthy = false
            fputs("Nightfall: could not save state: \(error.localizedDescription)\n", stderr)
            return false
        }
    }

    private func tick() {
        let systemPresence = systemPresenceReader.sample()
        let now = Date()
        let console = currentConsoleUID()
        let before = engine.state.pending
        let shouldSleep = engine.tick(now: now, consoleUID: console, presence: console.flatMap { agents[$0] },
                                      uptime: ProcessInfo.processInfo.systemUptime, systemPresence: systemPresence)
        // The engine consumes an approved occurrence before returning true.
        // Persist that decision before power to preserve it across service restarts.
        guard persist(), shouldSleep else { return }
        // Disk I/O may take time. Recheck the console and heartbeat afterward to
        // narrow the user-switch race before handing control to macOS.
        let finalConsole = currentConsoleUID()
        let verificationTime = Date()
        guard let expected = before else {
            engine.recordFailure("Skipped because the sleep warning was unavailable before sleep.", now: now)
            _ = persist()
            return
        }
        let verified: Bool
        if expected.unattendedSince != nil {
            let finalPresence = systemPresenceReader.sample()
            verified = Self.verifiesUnattendedSleep(expected, consoleBefore: finalConsole, consoleAfter: currentConsoleUID(),
                                                    systemPresence: finalPresence, now: Date())
        } else if let uid = expected.recipientUID, let agent = agents[uid] {
            verified = finalConsole == uid && agent.sessionID == expected.recipientSessionID &&
                agent.isUsable && agent.visibleWarningID == expected.id &&
                verificationTime.timeIntervalSince(agent.lastSeen) >= 0 &&
                verificationTime.timeIntervalSince(agent.lastSeen) <= 3
        } else {
            verified = false
        }
        guard verified else {
            engine.recordFailure("Skipped because the active user or system presence changed before sleep.", now: now)
            _ = persist()
            return
        }
        if dryRun {
            fputs("Nightfall dry run: sleep was approved; no power action performed.\n", stderr)
            return
        }
        let port = IOPMFindPowerManagement(mach_port_t(MACH_PORT_NULL))
        guard port != 0 else {
            engine.recordFailure("macOS power management was unavailable. No retry tonight.", now: now)
            _ = persist()
            return
        }
        // Success reports acceptance of the request, not an observed hardware
        // sleep transition; macOS and its drivers retain control of that transition.
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess {
            engine.recordFailure("macOS declined the sleep request (\(result)). No retry tonight.", now: now)
            _ = persist()
        }
    }

    /// Runs on `queue` with the kernel-reported peer UID, never a UID from JSON.
    /// Peer credentials identify a user, not a signed app; presentation fields
    /// remain that user's claims. All accepted users may prevent sleep, while
    /// schedule changes require the active desktop except in isolated dry runs.
    private func handle(_ request: ServiceRequest, uid: UInt32) -> ServiceResponse {
        let now = Date()
        var message: String?
        guard uid >= 500 || (dryRun && uid == getuid()) else {
            return ServiceResponse(error: "This service is available to local user accounts.")
        }
        switch request.command {
        case "poll":
            if let sessionID = request.sessionID, sessionID.count <= 80 {
                agents[uid] = AgentPresence(uid: uid, sessionID: sessionID, lastSeen: now,
                                            isUsable: request.isUsable ?? false,
                                            visibleWarningID: request.visibleWarningID)
            }
        case "status": break
        case "settings":
            guard currentConsoleUID() == uid || dryRun else {
                return ServiceResponse(error: "Change the schedule from the active desktop.")
            }
            do {
                guard let settings = request.settings else { throw SocketError.invalidResponse }
                try engine.updateSettings(settings, now: now)
            } catch { message = error.localizedDescription }
        case "skip": engine.skipTonight(now: now)
        case "cancel":
            if let id = request.warningID { engine.cancelWarning(id: id, now: now) }
        default: message = "Unknown request."
        }
        if !persist() { message = "The schedule could not be saved. Automatic sleep is suspended until storage recovers." }
        // Trim only the response copy. Authoritative state retains consumed dates
        // for clock-rollback protection; IPC carries a bounded recent history.
        var snapshot = engine.state
        snapshot.handledDays = Array(snapshot.handledDays.suffix(60))
        return ServiceResponse(state: snapshot, nextRun: engine.nextRun(after: now), error: message, dryRun: dryRun,
                               systemPresence: systemPresenceReader.sample())
    }

    func run() throws -> Never {
        _ = persist()
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError.system("Create listener", errno) }
        // Production uses protected /var/run; dry runs supply a private test path.
        // The socket admits all users, but getpeereid and command authorization
        // below determine what each connection can do.
        unlink(socketPath)
        var address = try LocalSocket.address(socketPath)
        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0, chmod(socketPath, 0o666) == 0, listen(listener, 16) == 0 else {
            throw SocketError.system("Listen", errno)
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in self?.tick() }
        self.timer = timer
        timer.resume()
        // Socket I/O stays off the coordinator queue. Bound concurrent workers
        // and close excess connections; this keeps slow peers off the safety
        // timer, but does not promise request availability during a flood.
        let admission = DispatchSemaphore(value: 16)
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(listener, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                guard admission.wait(timeout: .now()) == .success else { Darwin.close(client); continue }
                DispatchQueue.global(qos: .utility).async { [self] in
                    defer { Darwin.close(client); admission.signal() }
                    // A disconnected peer can make configuration fail. Do not
                    // send even an error response until SIGPIPE is suppressed.
                    do { try LocalSocket.configure(client) } catch { return }
                    var uid: uid_t = 0
                    var gid: gid_t = 0
                    guard getpeereid(client, &uid, &gid) == 0 else { return }
                    do {
                        let request = try Wire.decoder().decode(ServiceRequest.self, from: LocalSocket.receive(fd: client))
                        let response = queue.sync { handle(request, uid: uid) }
                        try LocalSocket.send(Wire.encoder().encode(response), fd: client)
                    } catch {
                        let response = ServiceResponse(error: "Invalid or incomplete service request.")
                        if let data = try? Wire.encoder().encode(response) { try? LocalSocket.send(data, fd: client) }
                    }
                }
            }
        }
        dispatchMain()
    }
}
