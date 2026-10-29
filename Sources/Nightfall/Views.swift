import SwiftUI

private let ink = Color(red: 0.09, green: 0.12, blue: 0.20)
private let accent = Color(red: 0.32, green: 0.38, blue: 0.78)
private let secondaryInk = Color(red: 0.43, green: 0.46, blue: 0.55)

struct NightfallView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 17).fill(ink).frame(width: 62, height: 62)
                    Image(systemName: "moon.stars.fill").font(.system(size: 29)).foregroundStyle(Color(red: 0.94, green: 0.85, blue: 0.64))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Nightfall").font(.system(size: 30, weight: .semibold, design: .rounded)).foregroundStyle(ink)
                    Text("A softer end to the day.").font(.system(size: 13)).foregroundStyle(secondaryInk)
                }
                Spacer()
                Text("THIS MAC").font(.system(size: 9, weight: .bold)).tracking(1.4).foregroundStyle(secondaryInk)
            }

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Label(model.connected ? "Daily sleep" : "Your daily rhythm", systemImage: "moon.zzz.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(accent)
                    Spacer()
                    Toggle("Daily sleep", isOn: Binding(get: { model.draft.enabled }, set: { model.draft.enabled = $0; model.isDirty = true }))
                        .labelsHidden().toggleStyle(.switch).tint(accent).disabled(!model.connected)
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(model.scheduleText).font(.system(size: 45, weight: .light, design: .rounded)).foregroundStyle(ink)
                    Text("every day").font(.system(size: 14)).foregroundStyle(secondaryInk)
                    Spacer()
                }
                HStack(spacing: 7) {
                    Circle().fill(model.connected ? Color.green.opacity(0.8) : Color.orange).frame(width: 6, height: 6)
                    Text(model.statusText).font(.system(size: 12)).foregroundStyle(secondaryInk)
                }
            }
            .padding(22).background(.white, in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(accent.opacity(0.09)))

            if model.connected {
                VStack(spacing: 16) {
                    HStack {
                        settingTitle("Sleep time", detail: "Follows this Mac’s local time zone")
                        Spacer()
                        DatePicker("Sleep time", selection: Binding(get: { model.time }, set: { model.time = $0 }), displayedComponents: [.hourAndMinute])
                            .labelsHidden().datePickerStyle(.field).frame(width: 110)
                    }
                    Divider()
                    HStack {
                        settingTitle("A little notice", detail: "Time to finish up or skip tonight")
                        Spacer()
                        Picker("Warning", selection: Binding(get: { model.draft.warningSeconds }, set: { model.draft.warningSeconds = $0; model.isDirty = true })) {
                            Text("30 seconds").tag(30)
                            Text("1 minute").tag(60)
                            Text("2 minutes").tag(120)
                            Text("5 minutes").tag(300)
                            Text("10 minutes").tag(600)
                        }.labelsHidden().frame(width: 130)
                    }
                    Divider()
                    HStack {
                        settingTitle("Gentle chime", detail: "A soft sound when the warning appears")
                        Spacer()
                        Toggle("Gentle chime", isOn: Binding(get: { model.draft.chimeEnabled }, set: { model.draft.chimeEnabled = $0; model.isDirty = true }))
                            .labelsHidden().toggleStyle(.switch).tint(accent)
                    }
                }.padding(.horizontal, 4)
                HStack(spacing: 10) {
                    Button("Skip next sleep") { model.skipNextSleep() }.disabled(!model.canSkipNextSleep)
                    Button("Preview warning") { model.preview() }
                    Spacer()
                    Button(model.saving ? "Saving…" : "Save changes") { model.save() }
                        .buttonStyle(.borderedProminent).tint(accent).disabled(!model.isDirty || model.saving)
                }.controlSize(.large)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    Text(model.installed ? "Waiting for the background service" : "One setup. Courtesy for everyone.")
                        .font(.system(size: 16, weight: .semibold)).foregroundStyle(ink)
                    Text(model.installed
                         ? "If the connection does not recover, reinstall to repair the background service. Your saved schedule is kept."
                         : "Install once with an administrator password. Nightfall starts at login for every user and shows a cancellable warning before putting this Mac to sleep.")
                        .font(.system(size: 13)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true).lineSpacing(4)
                    HStack {
                        Button(model.installing ? "Installing…" : (model.installed ? "Repair installation…" : "Install for all users…")) { model.install() }
                            .buttonStyle(.borderedProminent).tint(accent).controlSize(.large).disabled(model.installing)
                        Button("Preview warning") { model.preview() }.controlSize(.large)
                        Spacer()
                    }.padding(.top, 4)
                }.padding(.horizontal, 4)
            }

            if let message = model.message {
                Text(message).font(.system(size: 12)).foregroundStyle(accent).fixedSize(horizontal: false, vertical: true)
            } else if let outcome = model.state?.lastOutcome {
                Text(outcome.message).font(.system(size: 12)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "person.2.fill").font(.system(size: 14)).foregroundStyle(accent)
                Text("Everyone gets a say. A new active user gets a fresh countdown. Before sleeping unattended, Nightfall checks that all screens stay asleep and the Mac stays idle.")
                    .font(.system(size: 11)).foregroundStyle(secondaryInk).fixedSize(horizontal: false, vertical: true).lineSpacing(3)
            }
            if model.installed {
                HStack {
                    Spacer()
                    Button(model.uninstalling ? "Uninstalling…" : "Uninstall Nightfall…") { model.uninstall() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(secondaryInk)
                }
            }
        }
        .padding(30).frame(width: 590, height: 650)
        .background(Color(red: 0.96, green: 0.965, blue: 0.98))
        .preferredColorScheme(.light)
        .disabled(model.performingMaintenance)
    }

    private func settingTitle(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(ink)
            Text(detail).font(.system(size: 11)).foregroundStyle(secondaryInk)
        }
    }
}

/// Displays countdowns without initiating sleep. For live warnings, the service
/// owns the deadline and the model reports presentation; previews use local state.
struct WarningView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { context in
            let pending = model.warning
            let remaining = max(0, Int(ceil((pending?.deadline ?? context.date).timeIntervalSince(context.date))))
            let isPreview = model.previewWarning != nil
            let waiting = pending?.presented == false
            VStack(spacing: 0) {
                HStack {
                    Label("NIGHTFALL", systemImage: "moon.stars.fill").font(.system(size: 10, weight: .bold)).tracking(2)
                    Spacer()
                    Text(isPreview ? "PREVIEW" : "DAILY SLEEP").font(.system(size: 9, weight: .semibold)).tracking(1.5)
                        .padding(.horizontal, 10).padding(.vertical, 6).background(.white.opacity(0.09), in: Capsule())
                }.foregroundStyle(.white.opacity(0.55))
                Spacer(minLength: 20)
                Image(systemName: "moon.zzz.fill").font(.system(size: 38, weight: .light)).foregroundStyle(Color(red: 0.94, green: 0.85, blue: 0.64))
                    .padding(.bottom, 20)
                Text(isPreview && remaining == 0 ? "That’s the warning." : "Time to wind down.")
                    .font(.system(size: 28, weight: .medium, design: .rounded)).foregroundStyle(.white)
                Text(isPreview ? "Just a preview. Your Mac will stay awake." : "This Mac will go to sleep when the timer ends.")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.6)).padding(.top, 9)
                Text(String(format: "%d:%02d", remaining / 60, remaining % 60))
                    .font(.system(size: 69, weight: .ultraLight, design: .rounded)).monospacedDigit().foregroundStyle(.white)
                    .padding(.top, 13).padding(.bottom, 18)
                Text(waiting && !isPreview ? "Starting your full countdown…" : "Still in the middle of something?")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55)).padding(.bottom, 13)
                Button { model.cancelWarning() } label: {
                    Text(isPreview ? "Close preview" : "Skip tonight — keep Mac awake")
                        .font(.system(size: 14, weight: .semibold)).foregroundStyle(ink)
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(red: 0.94, green: 0.85, blue: 0.64), in: RoundedRectangle(cornerRadius: 11))
                }.buttonStyle(.plain).keyboardShortcut(.cancelAction).disabled(model.cancellingWarning)
                    .accessibilityHint(isPreview ? "Closes this harmless preview" : "Cancels only this occurrence; tomorrow’s schedule stays on")
                Text("Tomorrow’s schedule stays the same.").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4)).padding(.top, 13)
                Spacer(minLength: 10)
            }
            .padding(30).frame(width: 500, height: 490)
            .background(LinearGradient(colors: [Color(red: 0.11, green: 0.15, blue: 0.26), Color(red: 0.055, green: 0.07, blue: 0.13)], startPoint: .topLeading, endPoint: .bottomTrailing))
        }.preferredColorScheme(.dark)
    }
}
