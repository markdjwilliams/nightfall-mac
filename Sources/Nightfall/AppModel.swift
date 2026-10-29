import AppKit
import SwiftUI
import CoreGraphics

/// Mouse input is enough to cancel a floating warning while the user keeps
/// keyboard focus in another app.
struct WarningPresentation {
    enum InputAvailability { case blocked, mouse, keyboardAndMouse }
    var visibleOnCurrentDesktop: Bool
    var input: InputAvailability

    var canAcknowledge: Bool {
        visibleOnCurrentDesktop && input != .blocked
    }
}

/// Main-thread UI state and actions for one login session.
///
/// `state` is the last service snapshot; `draft` holds independent, unsaved edits.
/// Blocking transport runs on a serial background queue. Responses and action
/// completions return to the main thread before updating the UI.
final class AppModel: ObservableObject {
    enum InstallationResult {
        case success, cancelled
        case failure(String)
    }

    @Published var state: EngineState?
    @Published var nextRun: Date?
    @Published var draft = Settings()
    @Published var isDirty = false
    @Published var connected = false
    @Published var installing = false
    @Published var uninstalling = false
    @Published private(set) var saving = false
    @Published private(set) var skipping = false
    @Published private(set) var cancellingWarning = false
    @Published var message: String?
    @Published var previewWarning: PendingWarning?
    let sessionID = UUID().uuidString
    var warningWindow: NSWindow?
    var onUpdate: (() -> Void)?
    var previewOnly = false
    var performingMaintenance: Bool { installing || uninstalling }
    private var timer: Timer?
    // Include queued requests until their responses have been applied on the
    // main thread, so a poll cannot slip between unfinished user actions.
    private var requestsInFlight = 0
    private let transport = DispatchQueue(label: "com.nightfall.mac.client")
    private let requestService: (ServiceRequest) throws -> ServiceResponse
    private var sessionActive = true
    private var screenAwake = true
    private var observers: [NSObjectProtocol] = []

    /// Allows tests to control response timing without contacting a real service.
    init(requestService: @escaping (ServiceRequest) throws -> ServiceResponse = { try LocalSocket.request($0) }) {
        self.requestService = requestService
    }

    deinit {
        timer?.invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

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
    var canSkipNextSleep: Bool {
        connected && state?.settings.enabled == true && !saving && !skipping && !cancellingWarning && !performingMaintenance
    }

    func start() {
        guard !previewOnly, timer == nil else { return }
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
        // Menu tracking uses a different run-loop mode. Keep heartbeats alive
        // there so an open menu does not make this login's agent appear stale.
        let pollTimer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.poll() }
        timer = pollTimer
        RunLoop.main.add(pollTimer, forMode: .common)
        poll()
    }

    /// Public session and workspace signals permit attempting presentation.
    /// Window visibility and cancellation availability are checked separately.
    var isCurrentSessionUsable: Bool {
        guard sessionActive, screenAwake,
              let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              session[kCGSessionOnConsoleKey as String] as? Bool == true,
              session[kCGSessionLoginDoneKey as String] as? Bool == true,
              currentConsoleUID() == getuid() else { return false }
        return true
    }

    /// Acknowledges this process's visible warning while its cancel button can
    /// receive mouse input, even while another app has keyboard focus.
    /// The service independently checks the console owner and heartbeat freshness.
    private var visibleWarningID: String? {
        guard isCurrentSessionUsable, previewWarning == nil, !cancellingWarning,
              !performingMaintenance, let pending = state?.pending,
              pending.unattendedSince == nil, let window = warningWindow else { return nil }
        let visible = window.isVisible && window.isOnActiveSpace && !window.isMiniaturized &&
            window.alphaValue > 0 && window.occlusionState.contains(.visible)
        let modalBlocksInput = NSApp.modalWindow.map { $0 !== window } ?? false
        let blocked = !window.canBecomeKey || window.ignoresMouseEvents ||
            window.attachedSheet != nil || modalBlocksInput
        let input: WarningPresentation.InputAvailability = blocked ? .blocked :
            (window.isKeyWindow && NSApp.isActive ? .keyboardAndMouse : .mouse)
        guard WarningPresentation(visibleOnCurrentDesktop: visible, input: input).canAcknowledge else { return nil }
        return pending.id
    }

    func poll() {
        guard requestsInFlight == 0, !previewOnly, !performingMaintenance else { return }
        let request = ServiceRequest(command: "poll", sessionID: sessionID, isUsable: isCurrentSessionUsable,
                                     visibleWarningID: visibleWarningID)
        exchange(request, quiet: true)
    }

    /// Applies a service snapshot before calling `completion` and then `onUpdate`.
    /// Both callbacks run on the main thread. A successful transport result may
    /// still contain `response.error`; mutations must check the service's acknowledgment.
    private func exchange(_ request: ServiceRequest, quiet: Bool = false,
                          completion: ((Result<ServiceResponse, Error>) -> Void)? = nil) {
        requestsInFlight += 1
        let requestService = self.requestService
        transport.async { [weak self] in
            let result = Result { try requestService(request) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.requestsInFlight -= 1
                switch result {
                case .success(let response):
                    self.connected = response.state != nil
                    self.state = response.state
                    self.nextRun = response.nextRun
                    if let state = response.state {
                        if state.pending != nil { self.previewWarning = nil }
                        if !self.isDirty { self.draft = state.settings }
                    }
                    if let error = response.error { self.message = error }
                    else if !quiet { self.message = nil }
                case .failure(let error):
                    self.connected = false
                    // A lost connection must immediately stop certifying the warning.
                    self.state = nil
                    self.nextRun = nil
                    if !quiet { self.message = error.localizedDescription }
                }
                completion?(result)
                self.onUpdate?()
            }
        }
    }

    func save() {
        submitSettings(draft, successMessage: "Schedule saved for everyone on this Mac.")
    }

    func pauseDailySleep(completion: @escaping (Bool) -> Void) {
        guard connected, !saving, !performingMaintenance, var settings = state?.settings else {
            completion(false)
            return
        }
        settings.enabled = false
        // Pausing from the menu must not also save unfinished time or chime edits.
        draft.enabled = false
        isDirty = true
        submitSettings(settings, successMessage: "Daily sleep paused for everyone on this Mac.", completion: completion)
    }

    private func submitSettings(_ submitted: Settings, successMessage: String,
                                completion: ((Bool) -> Void)? = nil) {
        guard !saving, !performingMaintenance else { completion?(false); return }
        do { try submitted.validate() } catch {
            message = error.localizedDescription
            completion?(false)
            return
        }
        saving = true
        exchange(ServiceRequest(command: "settings", settings: submitted)) { [weak self] result in
            guard let self else { return }
            self.saving = false
            guard case .success(let response) = result, response.error == nil,
                  response.state?.settings == submitted else { completion?(false); return }
            // A user may keep editing while the background request is running.
            // Only clear the dirty state if those edits are the ones just saved.
            self.isDirty = self.draft != submitted
            self.message = self.isDirty ? "Saved. You still have unsaved changes." : successMessage
            completion?(true)
        }
    }

    func skipNextSleep() {
        guard canSkipNextSleep else { return }
        skipping = true
        exchange(ServiceRequest(command: "skip")) { [weak self] _ in self?.skipping = false }
    }

    /// Closes previews locally, or cancels the specific warning shown to the user.
    /// While cancellation is pending, polls stop acknowledging its presentation.
    func cancelWarning() {
        if previewWarning != nil { previewWarning = nil; onUpdate?(); return }
        guard !cancellingWarning, let warning = state?.pending else { return }
        cancellingWarning = true
        // An ID-bound cancellation cannot accidentally consume a later occurrence
        // if this warning has already ended by the time the service receives it.
        exchange(ServiceRequest(command: "cancel", warningID: warning.id)) { [weak self] _ in
            self?.cancellingWarning = false
        }
    }

    /// Creates local display state without consuming a scheduled occurrence.
    func preview() {
        guard state?.pending == nil else { onUpdate?(); return }
        let now = Date()
        previewWarning = PendingWarning(id: "preview-" + UUID().uuidString, day: "preview", scheduledAt: now,
                                         deadline: now.addingTimeInterval(30), warningSeconds: 30,
                                         recipientUID: getuid(), recipientSessionID: sessionID,
                                         awaitingSince: now, presented: true)
        onUpdate?()
    }

    /// Runs the bundled installer through macOS administrator authorization.
    /// Completion runs on the main thread; success hands this copy's lifecycle
    /// to the installed login agent and schedules this copy to quit.
    func install(completion: ((InstallationResult) -> Void)? = nil) {
        guard !performingMaintenance else {
            completion?(.failure("Another installation or removal is already in progress."))
            return
        }
        guard let script = Bundle.main.path(forResource: "install", ofType: "sh") else {
            let message = "The installer is missing. Download a fresh copy of Nightfall and try again."
            self.message = message
            completion?(.failure(message))
            return
        }
        installing = true
        message = nil
        let command = shellQuote(script) + " " + shellQuote(Bundle.main.bundlePath) + " --caller-uid " + String(getuid())
        let source = "do shell script " + appleScriptQuote(command) + " with administrator privileges"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var error: NSDictionary?
            let appleScript = NSAppleScript(source: source)
            if let appleScript { _ = appleScript.executeAndReturnError(&error) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.installing = false
                if appleScript == nil {
                    let message = "The administrator request could not be created."
                    self.message = message
                    completion?(.failure(message))
                } else if let error {
                    if error[NSAppleScript.errorNumber] as? Int == -128 {
                        self.message = "Installation cancelled."
                        completion?(.cancelled)
                    } else {
                        let message = error[NSAppleScript.errorMessage] as? String ?? "Nightfall could not be installed."
                        self.message = message
                        completion?(.failure(message))
                    }
                } else {
                    self.message = "Installed. Nightfall will reopen from Applications."
                    completion?(.success)
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

/// Quotes one literal shell argument before embedding the command in AppleScript.
func shellQuote(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
/// Encodes the completed shell command as an AppleScript string literal.
func appleScriptQuote(_ text: String) -> String {
    "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
}
