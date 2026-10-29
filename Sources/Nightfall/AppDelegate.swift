import AppKit
import SwiftUI
import Darwin

/// The cancel button must work on the first click when another app is active.
private final class WarningHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Owns one login's menu and windows; the system service owns sleep decisions.
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate {
    let model = AppModel()
    private var statusItem: NSStatusItem!
    private var settingsWindow: NSWindow?
    private var warningWindow: NSWindow?
    private var displayedWarningID: String?
    private var warningSound: NSSound?
    private var instanceLock: Int32 = -1
    private var reopenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A downloaded update must reach its own installer before the running
        // installed agent redirects it through the per-user instance lock.
        if !CommandLine.arguments.contains("--agent"), model.installed,
           Bundle.main.bundlePath != NightfallPaths.installedApp {
            NSApp.setActivationPolicy(.accessory)
            offerDownloadedInstallation()
            return
        }
        guard claimInstance() else { NSApp.terminate(nil); return }
        reopenObserver = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.nightfall.mac.showSettings"), object: nil, queue: .main) { [weak self] _ in
            if self?.model.isCurrentSessionUsable == true { self?.showSettings() }
        }
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "moon.stars", accessibilityDescription: "Nightfall daily sleep")
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        model.onUpdate = { [weak self] in self?.update() }
        model.start()
        if !CommandLine.arguments.contains("--agent") { showSettings() }
        if CommandLine.arguments.contains("--preview") { model.preview() }
        if CommandLine.arguments.contains("--install") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.model.install() }
        }
    }

    /// Runs without claiming the agent lock or starting service polling. Existing
    /// agents keep running until the installer is ready to replace and restart them.
    private func offerDownloadedInstallation() {
        let alert = NSAlert()
        alert.messageText = "Install Nightfall \(NightfallVersion.current) for all users?"
        alert.informativeText = "This replaces the existing Nightfall app and restarts its background service. Your shared schedule and skipped occurrences are kept. macOS will ask for an administrator password."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Install this version…")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertSecondButtonReturn else { NSApp.terminate(nil); return }
        model.install { result in
            switch result {
            case .success: break // Successful installation schedules this copy to quit.
            case .cancelled: NSApp.terminate(nil)
            case .failure(let message):
                let failure = NSAlert()
                failure.alertStyle = .warning
                failure.messageText = "Nightfall could not be installed"
                failure.informativeText = message
                failure.runModal()
                NSApp.terminate(nil)
            }
        }
    }

    /// Holds a per-user lock for this process's lifetime, redirecting later app
    /// launches to the owner. This coordinates UI copies; it does not authenticate IPC.
    private func claimInstance() -> Bool {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/com.nightfall.mac")
        do { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        catch { return false }
        instanceLock = open(directory.appendingPathComponent("agent.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard instanceLock >= 0, flock(instanceLock, LOCK_EX | LOCK_NB) == 0 else {
            if !CommandLine.arguments.contains("--agent") {
                DistributedNotificationCenter.default().postNotificationName(NSNotification.Name("com.nightfall.mac.showSettings"), object: nil, userInfo: nil, deliverImmediately: true)
            }
            return false
        }
        return true
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title = NSMenuItem(title: "Nightfall · Sleep at " + model.scheduleText, action: nil, keyEquivalent: "")
        menu.addItem(title)
        menu.addItem(NSMenuItem(title: model.statusText, action: nil, keyEquivalent: ""))
        menu.addItem(.separator())
        add(menu, "Skip next sleep", #selector(skip), enabled: model.canSkipNextSleep)
        add(menu, "Preview warning…", #selector(preview))
        add(menu, "Schedule & settings…", #selector(showSettings), key: ",")
        menu.addItem(.separator())
        add(menu, "About Nightfall", #selector(about))
        if model.connected { add(menu, "Pause daily sleep…", #selector(pauseSchedule)) }
        if model.installed { add(menu, "Uninstall Nightfall…", #selector(uninstall)) }
        else if !model.installed { add(menu, "Quit Nightfall", #selector(quitUninstalled), key: "q") }
    }

    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, key: String = "", enabled: Bool = true) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        item.isEnabled = enabled
        menu.addItem(item)
    }

    @objc func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 590, height: 650),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
            window.title = "Nightfall"
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: NightfallView(model: model))
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func skip() { model.skipNextSleep() }
    @objc private func preview() { model.preview() }
    @objc private func uninstall() { model.uninstall() }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Nightfall", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? NightfallVersion.current,
            .credits: NSAttributedString(string: "Daily sleep, with a little courtesy.\nBuilt for this Mac.")
        ])
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func quitUninstalled() { NSApp.terminate(nil) }
    @objc private func pauseSchedule() {
        let alert = NSAlert()
        alert.messageText = "Pause Nightfall’s daily schedule?"
        alert.informativeText = "Automatic sleep will stay off for everyone until you turn it on again. You can reopen Nightfall from Applications."
        alert.addButton(withTitle: "Pause daily sleep")
        alert.addButton(withTitle: "Keep running")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.pauseDailySleep { [weak self] saved in
            if saved { self?.settingsWindow?.close() }
            else { self?.showSettings() }
        }
    }

    /// Avoids repeated activation and chimes on routine polls, but permits a fresh
    /// presentation after an unusable session. Showing the window alone never
    /// authorizes a power request.
    private func update() {
        statusItem.button?.toolTip = model.statusText
        guard let warning = model.warning else {
            warningWindow?.orderOut(nil)
            model.warningWindow = nil
            displayedWarningID = nil
            warningSound?.stop()
            return
        }
        // Do not wake a sleeping display to show an unattended countdown. After
        // activity returns, the service revokes that path before we present the
        // user's new full countdown.
        if model.previewWarning == nil && (warning.unattendedSince != nil || !model.isCurrentSessionUsable) {
            warningWindow?.orderOut(nil)
            model.warningWindow = nil
            displayedWarningID = nil
            warningSound?.stop()
            return
        }
        guard warning.id != displayedWarningID else { return }
        displayedWarningID = warning.id
        if warningWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 490),
                                  styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Nightfall — scheduled sleep"
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.isReleasedWhenClosed = false
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = WarningHostingView(rootView: WarningView(model: model))
            window.delegate = self
            warningWindow = window
        }
        model.warningWindow = warningWindow
        warningWindow?.center()
        // Keep the warning in view while the user continues in another app.
        // Its hosting view accepts the cancellation click without stealing focus.
        warningWindow?.orderFrontRegardless()
        let chimeEnabled = model.previewWarning != nil ? model.draft.chimeEnabled : model.state?.settings.chimeEnabled == true
        if chimeEnabled {
            warningSound = NSSound(named: "Glass")
            warningSound?.volume = 0.5
            warningSound?.play()
        }
        // Window ordering can be asynchronous. The model acknowledges only if
        // visibility and cancellation checks actually pass on this or a later poll.
        model.poll()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showSettings(); return true }
}
