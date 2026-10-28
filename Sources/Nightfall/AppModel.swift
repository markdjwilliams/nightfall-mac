import AppKit
import SwiftUI
import CoreGraphics

final class AppModel: ObservableObject {
    @Published var state: EngineState?
    @Published var nextRun: Date?
    @Published var draft = Settings()
    @Published var isDirty = false
    @Published var connected = false
    @Published var installing = false
    @Published var uninstalling = false
    @Published var message: String?
    @Published var previewWarning: PendingWarning?
    let sessionID = UUID().uuidString
    var warningWindow: NSWindow?
    var onUpdate: (() -> Void)?
    var previewOnly = false
    var performingMaintenance: Bool { installing || uninstalling }
    private var timer: Timer?
    private var busy = false
    private let transport = DispatchQueue(label: "com.nightfall.mac.client")
    private var sessionActive = true
    private var screenAwake = true
    private var observers: [NSObjectProtocol] = []

    var installed: Bool { FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/" + NightfallPaths.daemonLabel + ".plist") }
    var warning: PendingWarning? { state?.pending ?? previewWarning }
    var time: Date {
        get { Calendar.current.date(bySettingHour: draft.hour, minute: draft.minute, second: 0, of: Date()) ?? Date() }
        set {
            let parts = Calendar.current.dateComponents([.hour, .minute], from: newValue)
            draft.hour = parts.hour ?? 20
            draft.minute = parts.minute ?? 30
            isDirty = true
        }
    }
    var scheduleText: String {
        let settings = state?.settings ?? draft
        let date = Calendar.current.date(bySettingHour: settings.hour, minute: settings.minute, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }
    var statusText: String {
        guard connected else { return installed ? "Connecting to the background service…" : "Ready to set up on this Mac" }
        guard state?.settings.enabled == true else { return "Daily schedule paused" }
        if state?.pending != nil { return "Sleep countdown in progress" }
        if let nextRun {
            return "Next sleep: " + nextRun.formatted(.dateTime.weekday(.wide).hour().minute())
        }
        return "Daily sleep is on"
    }
    var canSkipToday: Bool {
        guard connected, state?.settings.enabled == true else { return false }
        return true
    }

    func start() {
        guard !previewOnly else { return }
        let center = NSWorkspace.shared.notificationCenter
        func observe(_ name: NSNotification.Name, _ action: @escaping () -> Void) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { _ in action() })
        }
        observe(NSWorkspace.sessionDidBecomeActiveNotification) { [weak self] in self?.sessionActive = true; self?.poll() }
        observe(NSWorkspace.sessionDidResignActiveNotification) { [weak self] in self?.sessionActive = false; self?.poll() }
        observe(NSWorkspace.screensDidSleepNotification) { [weak self] in self?.screenAwake = false; self?.poll() }
        observe(NSWorkspace.screensDidWakeNotification) { [weak self] in self?.screenAwake = true; self?.poll() }
        observe(NSWorkspace.willSleepNotification) { [weak self] in self?.screenAwake = false; self?.poll() }
        observe(NSWorkspace.didWakeNotification) { [weak self] in self?.screenAwake = true; self?.poll() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        poll()
    }

    var isCurrentSessionUsable: Bool {
        guard sessionActive, screenAwake,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              currentConsoleUID() == getuid() else { return false }
        // No Accessibility, screen recording, private lock keys, or automation access.
        return true
    }

    private var visibleWarningID: String? {
        guard isCurrentSessionUsable, previewWarning == nil, let pending = state?.pending,
              let window = warningWindow, window.isVisible, window.isOnActiveSpace,
              window.occlusionState.contains(.visible), window.isKeyWindow, NSApp.isActive else { return nil }
        return pending.id
    }

    func poll() {
        guard !busy, !previewOnly, !performingMaintenance else { return }
        let request = ServiceRequest(command: "poll", sessionID: sessionID, isUsable: isCurrentSessionUsable,
                                     visibleWarningID: visibleWarningID)
        exchange(request, quiet: true)
    }

    private func exchange(_ request: ServiceRequest, quiet: Bool = false, completion: (() -> Void)? = nil) {
        busy = true
        transport.async { [weak self] in
            let result = Result { try LocalSocket.request(request) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.busy = false
                switch result {
                case .success(let response):
                    self.connected = response.state != nil
                    if let state = response.state {
                        if state.pending != nil { self.previewWarning = nil }
                        self.state = state
                        self.nextRun = response.nextRun
                        if !self.isDirty { self.draft = state.settings }
                    }
                    if let error = response.error { self.message = error }
                    else if !quiet { self.message = nil }
                    completion?()
                case .failure(let error):
                    self.connected = false
                    // A lost connection must immediately stop certifying the warning.
                    self.state = nil
                    if !quiet { self.message = error.localizedDescription }
                }
                self.onUpdate?()
            }
        }
    }

    func save() {
        do { try draft.validate() } catch { message = error.localizedDescription; return }
        let submitted = draft
        exchange(ServiceRequest(command: "settings", settings: submitted)) { [weak self] in
            guard let self, self.state?.settings == submitted else { return }
            self.isDirty = false
            self.message = "Schedule saved for everyone on this Mac."
        }
    }

    func skipTonight() { exchange(ServiceRequest(command: "skip")) }
    func cancelWarning() {
        if previewWarning != nil { previewWarning = nil; onUpdate?(); return }
        guard let warning = state?.pending else { return }
        // Keep the warning open until the service confirms the cancellation.
        exchange(ServiceRequest(command: "cancel", warningID: warning.id))
    }

    func preview() {
        guard state?.pending == nil else { onUpdate?(); return }
        let now = Date()
        previewWarning = PendingWarning(id: "preview-" + UUID().uuidString, day: "preview", scheduledAt: now,
                                         deadline: now.addingTimeInterval(30), warningSeconds: 30,
                                         recipientUID: getuid(), recipientSessionID: sessionID,
                                         awaitingSince: now, presented: true)
        onUpdate?()
    }

    func install() {
        guard !performingMaintenance else { return }
        guard let script = Bundle.main.path(forResource: "install", ofType: "sh") else {
            message = "The installer is missing. Rebuild the app and try again."
            return
        }
        installing = true
        message = nil
        let command = shellQuote(script) + " " + shellQuote(Bundle.main.bundlePath)
        let source = "do shell script " + appleScriptQuote(command) + " with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: source)
            if let appleScript { _ = appleScript.executeAndReturnError(&error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installing = false
                if appleScript == nil {
                    self.message = "The administrator request could not be created."
                } else if let error {
                    self.message = error[NSAppleScript.errorMessage] as? String ?? "Installation was cancelled."
                } else {
                    self.message = "Installed. Nightfall will reopen from Applications."
                    // The system-wide LaunchAgent now owns the app lifecycle.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { NSApp.terminate(nil) }
                }
            }
        }
    }

    func uninstall() {
        guard installed, !performingMaintenance else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Uninstall Nightfall from this Mac?"
        alert.informativeText = "This removes Nightfall for every user, including the daily schedule and background service. macOS will ask for an administrator password."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Uninstall Nightfall")
        alert.buttons.last?.hasDestructiveAction = true
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        guard let script = Bundle.main.path(forResource: "uninstall", ofType: "sh") else {
            message = "The uninstaller is missing. Repair the installation and try again."
            return
        }
        uninstalling = true
        message = "Waiting for administrator authorization…"
        let command = shellQuote(script) + " --caller-uid " + String(getuid())
        let source = "do shell script " + appleScriptQuote(command) + " with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: source)
            if let appleScript { _ = appleScript.executeAndReturnError(&error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.uninstalling = false
                if appleScript == nil {
                    self.message = "The administrator request could not be created."
                } else if let error {
                    let number = error[NSAppleScript.errorNumber] as? Int
                    self.message = number == -128 ? "Uninstall cancelled." :
                        (error[NSAppleScript.errorMessage] as? String ?? "Nightfall could not be completely removed.")
                } else {
                    // The managed agent usually exits at the uninstaller's last
                    // step; this also closes a manually opened copy of the app.
                    NSApp.terminate(nil)
                }
            }
        }
    }
}

func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func appleScriptQuote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
