import Foundation
import Darwin

enum NightfallPaths {
    static let socket = "/var/run/com.nightfall.mac.sock"
    static let stateDirectory = "/Library/Application Support/Nightfall"
    static let installedApp = "/Applications/Nightfall.app"
    static let daemonLabel = "com.nightfall.mac.daemon"
    static let agentLabel = "com.nightfall.mac.agent"
}

enum NightfallVersion {
    static let current = "1.1.1"
}

struct ServiceRequest: Codable {
    var command: String
    var sessionID: String?
    var isUsable: Bool?
    var visibleWarningID: String?
    var warningID: String?
    var settings: Settings?
}

struct ServiceResponse: Codable {
    var state: EngineState?
    var nextRun: Date?
    var error: String?
    var version: String = NightfallVersion.current
    var dryRun: Bool = false
}

enum Wire {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

enum SocketError: LocalizedError {
    case system(String, Int32)
    case invalidResponse
    case oversized
    var errorDescription: String? {
        switch self {
        case .system(let operation, let code): return "\(operation): \(String(cString: strerror(code)))"
        case .invalidResponse: return "The background service sent an incomplete response."
        case .oversized: return "The service message exceeded its size limit."
        }
    }
}

enum LocalSocket {
    static let messageLimit = 32_768
    private static let operationTimeout: TimeInterval = 2.5

    static func address(_ path: String) throws -> sockaddr_un {
        var value = sockaddr_un()
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: value.sun_path) else { throw SocketError.oversized }
        value.sun_family = sa_family_t(AF_UNIX)
        value.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &value.sun_path) { target in
            bytes.withUnsafeBytes { source in target.copyBytes(from: source) }
        }
        return value
    }

    static func configure(_ fd: Int32) throws {
        var one: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw SocketError.system("Configure socket", errno)
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw SocketError.system("Configure socket", errno)
        }
    }

    /// One monotonic deadline covers every partial read/write, including a peer
    /// that trickles bytes just before a per-call socket timeout would expire.
    private static func wait(fd: Int32, events: Int16, until deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw SocketError.system("Service timed out", ETIMEDOUT) }
            var descriptor = pollfd(fd: fd, events: events, revents: 0)
            let result = Darwin.poll(&descriptor, 1, Int32(ceil(remaining * 1000)))
            if result < 0 && errno == EINTR { continue }
            guard result >= 0 else { throw SocketError.system("Wait for service", errno) }
            guard result > 0 else { throw SocketError.system("Service timed out", ETIMEDOUT) }
            guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw SocketError.system("Wait for service", EBADF) }
            // Let read/write report EOF or the underlying error after hangup.
            if descriptor.revents & (events | Int16(POLLHUP | POLLERR)) != 0 { return }
        }
    }

    static func send(_ data: Data, fd: Int32) throws {
        guard data.count <= messageLimit else { throw SocketError.oversized }
        var payload = data
        payload.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + operationTimeout
        try payload.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try wait(fd: fd, events: Int16(POLLOUT), until: deadline)
                let count = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard count > 0 else { throw SocketError.system("Send", errno) }
                offset += count
            }
        }
    }

    static func receive(fd: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let deadline = ProcessInfo.processInfo.systemUptime + operationTimeout
        while result.count <= messageLimit {
            try wait(fd: fd, events: Int16(POLLIN), until: deadline)
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            guard count > 0 else { throw SocketError.invalidResponse }
            if let newline = buffer[..<count].firstIndex(of: 10) {
                result.append(contentsOf: buffer[..<newline])
                guard result.count <= messageLimit else { throw SocketError.oversized }
                return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        throw SocketError.oversized
    }

    static func request(_ request: ServiceRequest, path: String = NightfallPaths.socket) throws -> ServiceResponse {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SocketError.system("Connect", errno) }
        defer { Darwin.close(fd) }
        try configure(fd)
        var address = try address(path)
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if status != 0 {
            guard errno == EINPROGRESS else { throw SocketError.system("Connect", errno) }
            try wait(fd: fd, events: Int16(POLLOUT), until: ProcessInfo.processInfo.systemUptime + operationTimeout)
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
                throw SocketError.system("Connect", errno)
            }
            guard error == 0 else { throw SocketError.system("Connect", error) }
        }
        // Production clients accept responses only from the root-owned service.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == 0 || path != NightfallPaths.socket else {
            throw SocketError.system("Verify service", EPERM)
        }
        try send(Wire.encoder().encode(request), fd: fd)
        return try Wire.decoder().decode(ServiceResponse.self, from: receive(fd: fd))
    }
}
