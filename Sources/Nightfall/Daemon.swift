import Foundation
import Darwin
import SystemConfiguration
import IOKit.pwr_mgt

func currentConsoleUID() -> UInt32? {
    var uid: uid_t = 0
    var gid: gid_t = 0
    guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?,
          name != "loginwindow", name != "_mbsetupuser", uid >= 500 else { return nil }
    return uid
}

final class NightfallDaemon {
    private let queue = DispatchQueue(label: "com.nightfall.mac.coordinator")
    private let engine: ScheduleEngine
    private let directory: String
    private let socketPath: String
    private let dryRun: Bool
    private var agents: [UInt32: AgentPresence] = [:]
    private var timer: DispatchSourceTimer?
    private var lockFD: Int32 = -1
    private var lastSaved: EngineState?
    private var storageHealthy = true

    private static func validateOwnedItem(_ fd: Int32, type: mode_t, name: String) throws {
        var information = stat()
        guard fstat(fd, &information) == 0 else { throw SocketError.system("Inspect \(name)", errno) }
        guard information.st_mode & S_IFMT == type,
              information.st_uid == geteuid(), information.st_mode & 0o022 == 0,
              type == S_IFDIR || information.st_nlink == 1 else {
            throw SocketError.system("Unsafe \(name) ownership, permissions, or file type", EPERM)
        }
    }

    init(directory: String, socketPath: String, dryRun: Bool) throws {
        self.directory = directory
        self.socketPath = socketPath
        self.dryRun = dryRun
        guard dryRun || geteuid() == 0 else { throw SocketError.system("Service requires administrator installation", EPERM) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // Installation checks are not a substitute for validating privileged
        // storage on every launch. O_NOFOLLOW and descriptor checks also avoid
        // following a replaced state/lock file before its contents are trusted.
        let directoryFD = open(directory, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryFD >= 0 else { throw SocketError.system("Open state directory", errno) }
        defer { Darwin.close(directoryFD) }
        try Self.validateOwnedItem(directoryFD, type: S_IFDIR, name: "state directory")
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
            // A damaged state must not silently re-enable an already skipped occurrence.
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
        let now = Date()
        let console = currentConsoleUID()
        let before = engine.state.pending
        let shouldSleep = engine.tick(now: now, consoleUID: console, presence: console.flatMap { agents[$0] },
                                      uptime: ProcessInfo.processInfo.systemUptime)
        // Consume and save the occurrence before making a power request; never retry it.
        guard persist(), shouldSleep else { return }
        let finalConsole = currentConsoleUID()
        let verificationTime = Date()
        guard let expected = before, let uid = expected.recipientUID,
              finalConsole == uid, let agent = agents[uid],
              agent.sessionID == expected.recipientSessionID,
              agent.isUsable, agent.visibleWarningID == expected.id,
              verificationTime.timeIntervalSince(agent.lastSeen) >= 0,
              verificationTime.timeIntervalSince(agent.lastSeen) <= 3 else {
            engine.recordFailure("Skipped because the active user changed before sleep.", now: now)
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
        let result = IOPMSleepSystem(port)
        IOServiceClose(port)
        if result != kIOReturnSuccess {
            engine.recordFailure("macOS declined the sleep request (\(result)). No retry tonight.", now: now)
            _ = persist()
        }
    }

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
        // The UI needs recent dates only. Full history stays on disk so responses
        // remain bounded even after years of use.
        var snapshot = engine.state
        snapshot.handledDays = Array(snapshot.handledDays.suffix(60))
        return ServiceResponse(state: snapshot, nextRun: engine.nextRun(after: now), error: message, dryRun: dryRun)
    }

    func run() throws -> Never {
        _ = persist()
        let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard listener >= 0 else { throw SocketError.system("Create listener", errno) }
        // Protected parent /var/run prevents ordinary users from replacing this socket.
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
        // A slow client never blocks the safety timer or other clients.
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
