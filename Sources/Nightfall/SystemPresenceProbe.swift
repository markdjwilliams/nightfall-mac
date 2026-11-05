import Foundation
import Darwin

/// Private pipes connect the service to a protected copy of this executable.
/// This protocol never accepts display claims from clients of the public socket.
protocol PresenceProbeTransport: AnyObject {
    func sample(until deadline: TimeInterval) throws -> SystemPresence?
    func stop()
}

private enum ProbeFramingError: Error { case endOfFile }

/// Serial coordinator-owned cache. Unknown readings cannot authorize sleep;
/// final verification bypasses the cache, and an owner change discards the child.
final class SystemPresenceProvider {
    private let allowGUIProbe: Bool
    private let readDirect: () -> SystemPresence?
    private let uptime: () -> TimeInterval
    private let startProbe: (UInt32, TimeInterval) throws -> PresenceProbeTransport
    private var worker: PresenceProbeTransport?
    private var owner: UInt32?
    private var cached: (time: TimeInterval, value: SystemPresence?)?
    private var retryAfter: TimeInterval = 0
    private(set) var diagnostic: String?

    init(allowGUIProbe: Bool, readDirect: @escaping () -> SystemPresence?,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         startProbe: @escaping (UInt32, TimeInterval) throws -> PresenceProbeTransport = {
             try SystemPresenceProbe(consoleUID: $0, until: $1)
         }) {
        self.allowGUIProbe = allowGUIProbe
        self.readDirect = readDirect
        self.uptime = uptime
        self.startProbe = startProbe
    }

    deinit { worker?.stop() }

    private func discardWorker() {
        worker?.stop()
        worker = nil
        cached = nil
    }

    func sample(readConsole: () -> UInt32?, forceFresh: Bool = false)
        -> (consoleUID: UInt32?, presence: SystemPresence?) {
        let before = readConsole()
        if owner != before {
            discardWorker()
            owner = before
            retryAfter = 0
        }
        let value: SystemPresence?
        if !allowGUIProbe {
            // Isolated dry runs never launch a root helper or enter another login.
            value = readDirect()
        } else if let uid = before, uid >= 500 {
            let now = uptime()
            if !forceFresh, let cached, now >= cached.time, now - cached.time < 1 {
                value = cached.value
            } else if now < retryAfter {
                value = nil
            } else {
                do {
                    let deadline = now + 0.8
                    if worker == nil { worker = try startProbe(uid, deadline) }
                    value = try worker!.sample(until: deadline)
                    cached = (uptime(), value)
                    diagnostic = value == nil ? "The desktop probe could not verify display and input state." : nil
                } catch {
                    discardWorker()
                    retryAfter = uptime() + 3
                    diagnostic = "The desktop probe was unavailable or its response was invalid."
                    value = nil
                }
            }
        } else {
            discardWorker()
            diagnostic = "No active desktop is available for the display probe."
            value = nil
        }
        let after = readConsole()
        guard before == after else {
            discardWorker()
            owner = after
            retryAfter = 0
            diagnostic = "The active desktop changed during the display probe."
            return (after, nil)
        }
        return (after, value)
    }
}

/// A persistent root child adopts only the selected user's bootstrap/audit
/// context through launchctl. Its executable, environment and command are fixed.
/// posix_spawn children are reaped explicitly, so a stopped child's PID cannot
/// be reused between its termination request and waitpid.
final class SystemPresenceProbe: PresenceProbeTransport {
    static let messageLimit = 4096
    static let helperPath = "/Library/PrivilegedHelperTools/com.nightfall.mac.daemon"
    static var greeting: Data { Data("NIGHTFALL-PRESENCE/1/\(NightfallVersion.current)".utf8) }
    private var pid: pid_t = 0
    private var input: Int32 = -1
    private var output: Int32 = -1

    init(consoleUID: UInt32, until deadline: TimeInterval) throws {
        guard geteuid() == 0, consoleUID >= 500 else { throw SocketError.invalidResponse }
        try Self.validateProtectedExecutable(Self.helperPath)
        try Self.validateProtectedExecutable("/bin/launchctl")
        var incoming = [Int32](repeating: -1, count: 2)
        var outgoing = [Int32](repeating: -1, count: 2)
        guard pipe(&incoming) == 0 else { throw SocketError.system("Create probe input", errno) }
        defer { incoming.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        guard pipe(&outgoing) == 0 else { throw SocketError.system("Create probe output", errno) }
        defer { outgoing.filter { $0 >= 0 }.forEach { Darwin.close($0) } }
        try Self.configure(incoming[1])
        try Self.configure(outgoing[0])
        let nullFD = open("/dev/null", O_WRONLY | O_CLOEXEC)
        guard nullFD >= 0 else { throw SocketError.system("Open probe error output", errno) }
        defer { Darwin.close(nullFD) }
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw SocketError.invalidResponse }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw SocketError.invalidResponse }
        defer { posix_spawnattr_destroy(&attributes) }
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGALRM, SIGTERM, SIGPIPE] { sigaddset(&defaults, signal) }
        var mask = sigset_t()
        sigemptyset(&mask)
        let flags = Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)
        guard posix_spawn_file_actions_adddup2(&actions, incoming[0], STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, outgoing[1], STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, nullFD, STDERR_FILENO) == 0,
              posix_spawnattr_setflags(&attributes, flags) == 0,
              posix_spawnattr_setsigdefault(&attributes, &defaults) == 0,
              posix_spawnattr_setsigmask(&attributes, &mask) == 0 else { throw SocketError.invalidResponse }
        let arguments = ["/bin/launchctl", "asuser", String(consoleUID), Self.helperPath, "--system-presence-probe-loop"]
        let environment = ["PATH=/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL=C"]
        let argumentPointers = arguments.map { strdup($0) } + [nil]
        let environmentPointers = environment.map { strdup($0) } + [nil]
        defer {
            argumentPointers.compactMap { $0 }.forEach { free($0) }
            environmentPointers.compactMap { $0 }.forEach { free($0) }
        }
        let result = argumentPointers.withUnsafeBufferPointer { argv in
            environmentPointers.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/launchctl", &actions, &attributes,
                            UnsafeMutablePointer(mutating: argv.baseAddress!),
                            UnsafeMutablePointer(mutating: env.baseAddress!))
            }
        }
        guard result == 0 else { throw SocketError.system("Launch desktop probe", result) }
        input = incoming[1]
        incoming[1] = -1
        output = outgoing[0]
        outgoing[0] = -1
        do {
            guard try Self.readLine(fd: output, until: deadline) == Self.greeting else { throw SocketError.invalidResponse }
        } catch {
            stop()
            throw error
        }
    }

    deinit { stop() }

    /// Every path component is root-owned and not writable by other users.
    /// Reject symlinks so verification and execution resolve the same path.
    static func validateProtectedExecutable(_ path: String) throws {
        let parts = path.split(separator: "/")
        var current = ""
        for (index, part) in parts.enumerated() {
            current += "/" + part
            var info = stat()
            guard lstat(current, &info) == 0, info.st_uid == 0, info.st_mode & 0o022 == 0,
                  info.st_mode & S_IFMT == (index == parts.count - 1 ? S_IFREG : S_IFDIR),
                  index != parts.count - 1 || info.st_mode & 0o111 != 0 else {
                throw SocketError.system("Unsafe desktop probe path", EPERM)
            }
        }
    }

    func sample(until deadline: TimeInterval) throws -> SystemPresence? {
        guard pid > 0 else { throw SocketError.invalidResponse }
        // A leftover frame must never be mistaken for a fresh sample.
        var pending = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
        guard Darwin.poll(&pending, 1, 0) == 0 else { throw SocketError.invalidResponse }
        try Self.writeLine(Data("sample".utf8), fd: input, until: deadline)
        return try Self.decodeResponse(Self.readLine(fd: output, until: deadline))
    }

    func stop() {
        if input >= 0 { Darwin.close(input); input = -1 }
        if output >= 0 { Darwin.close(output); output = -1 }
        guard pid > 0 else { return }
        let child = pid
        pid = 0
        Darwin.kill(child, SIGKILL)
        var status: Int32 = 0
        var reaped: pid_t
        repeat { reaped = waitpid(child, &status, WNOHANG) } while reaped < 0 && errno == EINTR
        if reaped == 0 {
            // Do not block the coordinator waiting for a stalled system query.
            DispatchQueue.global(qos: .utility).async {
                var result: Int32 = 0
                while waitpid(child, &result, 0) < 0 && errno == EINTR {}
            }
        }
    }

    static func decodeResponse(_ data: Data) throws -> SystemPresence? {
        guard data.count <= messageLimit else { throw SocketError.oversized }
        let presence = try JSONDecoder().decode(SystemPresence?.self, from: data)
        if let presence {
            guard presence.idleSeconds.isFinite, presence.idleSeconds >= 0,
                  presence.idleSeconds < .greatestFiniteMagnitude else { throw SocketError.invalidResponse }
        }
        return presence
    }

    static func configure(_ fd: Int32) throws {
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
              fcntl(fd, F_SETNOSIGPIPE, 1) == 0 else { throw SocketError.system("Configure probe pipe", errno) }
    }

    private static func wait(fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SocketError.system("Desktop probe timed out", ETIMEDOUT) }
            var item = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&item, 1, Int32(ceil(min(remaining, 60) * 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result > 0, item.revents & Int16(POLLNVAL) == 0 else {
                throw SocketError.system("Desktop probe timed out or disconnected", result < 0 ? errno : ETIMEDOUT)
            }
            if item.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
        }
    }

    static func readLine(fd: Int32, until deadline: TimeInterval) throws -> Data {
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: messageLimit + 1)
        while data.count <= messageLimit {
            try wait(fd: fd, events: Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            if count == 0 && data.isEmpty { throw ProbeFramingError.endOfFile }
            guard count > 0 else { throw SocketError.invalidResponse }
            if let newline = bytes[..<count].firstIndex(of: 10) {
                guard newline == count - 1, data.count + newline <= messageLimit else { throw SocketError.invalidResponse }
                data.append(contentsOf: bytes[..<newline])
                return data
            }
            data.append(contentsOf: bytes[..<count])
        }
        throw SocketError.oversized
    }

    static func writeLine(_ data: Data, fd: Int32, until deadline: TimeInterval) throws {
        guard data.count <= messageLimit else { throw SocketError.oversized }
        var payload = data
        payload.append(10)
        try payload.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(fd: fd, events: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw SocketError.invalidResponse }
                offset += count
            }
        }
    }

    /// Child-only mode. Idle and query watchdogs request termination without
    /// relying on parent cleanup when a desktop query stalls.
    static func runLoop() -> Never {
        signal(SIGALRM) { _ in _exit(1) }
        do {
            try configure(STDIN_FILENO)
            try configure(STDOUT_FILENO)
            try writeLine(greeting, fd: STDOUT_FILENO, until: ProcessInfo.processInfo.systemUptime + 1)
            while true {
                alarm(60)
                guard try readLine(fd: STDIN_FILENO, until: ProcessInfo.processInfo.systemUptime + 60) == Data("sample".utf8) else {
                    _exit(1)
                }
                alarm(2)
                let data = try autoreleasepool { try JSONEncoder().encode(SystemPresenceReader().sample()) }
                try writeLine(data, fd: STDOUT_FILENO, until: ProcessInfo.processInfo.systemUptime + 0.5)
                alarm(0)
            }
        } catch ProbeFramingError.endOfFile { _exit(0) }
        catch { _exit(1) }
    }
}
