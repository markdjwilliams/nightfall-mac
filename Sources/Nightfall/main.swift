import AppKit
import SwiftUI

let arguments = CommandLine.arguments
func value(after flag: String) -> String? {
    guard let index = arguments.firstIndex(of: flag), arguments.count > index + 1 else { return nil }
    return arguments[index + 1]
}

if arguments.contains("--version") {
    print(NightfallVersion.current)
} else if arguments.contains("--daemon") {
    do {
        let dryRun = arguments.contains("--dry-run")
        let directory = dryRun ? (value(after: "--state-dir") ?? NSTemporaryDirectory() + "Nightfall-test") : NightfallPaths.stateDirectory
        let socket = dryRun ? (value(after: "--socket") ?? directory + "/service.sock") : NightfallPaths.socket
        try NightfallDaemon(directory: directory, socketPath: socket, dryRun: dryRun).run()
    } catch {
        fputs("Nightfall: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
} else if arguments.contains("--status") {
    do {
        let response = try LocalSocket.request(ServiceRequest(command: "status"), path: value(after: "--socket") ?? NightfallPaths.socket)
        let data = try Wire.encoder().encode(response)
        print(String(decoding: data, as: UTF8.self))
    } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
} else if let path = value(after: "--render-preview") {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = AppModel()
    model.previewOnly = true
    model.connected = true
    model.state = EngineState(settings: Settings(), lastOutcome: nil, pending: nil)
    model.nextRun = Calendar.current.date(bySettingHour: 20, minute: 30, second: 0, of: Date().addingTimeInterval(86400))
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    func render<V: View>(_ view: V, name: String, size: NSSize) throws {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let data = bitmap.representation(using: .png, properties: [:]) { try data.write(to: URL(fileURLWithPath: path + "/" + name + ".png")) }
    }
    try render(NightfallView(model: model), name: "schedule", size: NSSize(width: 590, height: 650))
    let now = Date()
    model.state?.pending = PendingWarning(id: "render-only", day: "render-only", scheduledAt: now.addingTimeInterval(120),
                                          deadline: now.addingTimeInterval(120), warningSeconds: 120,
                                          recipientUID: getuid(), recipientSessionID: model.sessionID,
                                          awaitingSince: now, presented: true)
    try render(WarningView(model: model), name: "warning", size: NSSize(width: 500, height: 490))
    print("Rendered app previews in \(path)")
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
