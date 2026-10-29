import AppKit
import ApplicationServices
import EventKit
import SwiftUI

extension Notification.Name {
    static let notchHotkeyChanged = Notification.Name("NotchIsland.hotkeyChanged")
    static let notchModulesChanged = Notification.Name("NotchIsland.modulesChanged")
}

final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 600),
                             styleMask: [.titled, .closable, .miniaturizable],
                             backing: .buffered, defer: false)
            w.title = "NotchIsland Settings"
            w.contentView = NSHostingView(rootView: SettingsView())
            w.isReleasedWhenClosed = false
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var launchAtLogin = LaunchAtLogin.isEnabled
    @State private var recording = false
    @State private var accent: Color = Theme.accent

    var body: some View {
        TabView {
            general.tabItem { Label("General", systemImage: "gearshape") }
            modules.tabItem { Label("Modules", systemImage: "square.grid.2x2") }
            visibility.tabItem { Label("Visibility", systemImage: "eye") }
            permissions.tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 540, height: 600)
    }

    // MARK: General

    private var general: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { launchAtLogin = $0; LaunchAtLogin.set($0) }))
                Toggle("Show menu bar icon", isOn: $settings.showMenuBarIcon)
            }
            Section("Hotkey") {
                HStack {
                    Text("Open app search")
                    Spacer()
                    Text(settings.hotkeyDescription)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 6))
                    Button(recording ? "Press keys…" : "Change…") { recording.toggle() }
                        .background(KeyRecorder(active: $recording) { code, flags in
                            settings.hotkeyKeyCode = code
                            settings.hotkeyModifiers = Int(flags.rawValue)
                            NotificationCenter.default.post(name: .notchHotkeyChanged, object: nil)
                        })
                }
                Text("With Accessibility granted the key is swallowed (CGEvent tap); otherwise it is only observed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Feel") {
                HStack {
                    Text("Hover delay")
                    Slider(value: $settings.hoverDelay, in: 0...0.6, step: 0.05)
                    Text(String(format: "%.2fs", settings.hoverDelay)).monospacedDigit().frame(width: 44)
                }
                Toggle("Haptic feedback (Force Touch trackpads)", isOn: $settings.haptics)
                Toggle("Sound feedback", isOn: $settings.sounds)
                Text("Animations follow System Settings → Accessibility → Reduce Motion.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Theme") {
                ColorPicker("Accent colour", selection: $accent, supportsOpacity: false)
                    .onChange(of: accent) { newValue in settings.accentHex = NSColor(newValue).hexString }
                Button("Reset to white") { accent = .white; settings.accentHex = "#FFFFFF" }
                Toggle("Slightly translucent shade cards", isOn: $settings.translucentShade)
                Text("The island itself stays true black so it blends with the bezel.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Modules

    private var modules: some View {
        Form {
            Section("Live activities") {
                Toggle("Now Playing (Music, Spotify, VLC, Chrome/Brave/Edge)", isOn: $settings.mediaEnabled)
                Toggle("Notifications (banner + shade)", isOn: $settings.notificationsEnabled)
                Toggle("Volume HUD", isOn: $settings.volumeHUDEnabled)
                Toggle("Battery: charger and low-battery alerts", isOn: $settings.batteryAlertsEnabled)
                Toggle("Bluetooth / AirPods connect (with battery)", isOn: $settings.bluetoothEnabled)
                Toggle("Downloads progress (~/Downloads)", isOn: $settings.downloadsEnabled)
                Toggle("Mic / camera / Focus indicators", isOn: $settings.indicatorsEnabled)
            }
            Section("Shade") {
                Toggle("Next calendar event", isOn: $settings.calendarEnabled)
                Toggle("Timer / Pomodoro", isOn: $settings.timerEnabled)
                Toggle("Clipboard history", isOn: $settings.clipboardEnabled)
                Toggle("Shelf (drag files onto the notch)", isOn: $settings.shelfEnabled)
                Toggle("Quick toggles (dark mode, keep awake, Wi-Fi, mirror, Focus)", isOn: $settings.quickTogglesEnabled)
            }
            Text("Changes apply immediately.").font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .onChange(of: settings.mediaEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.notificationsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.clipboardEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.downloadsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.bluetoothEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.batteryAlertsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.calendarEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
        .onChange(of: settings.indicatorsEnabled) { _ in NotificationCenter.default.post(name: .notchModulesChanged, object: nil) }
    }

    // MARK: Visibility

    private var visibility: some View {
        Form {
            Section("Hide the island") {
                Toggle("When the frontmost app is full screen", isOn: $settings.hideInFullscreen)
                VStack(alignment: .leading, spacing: 4) {
                    Text("For these apps (bundle identifiers, comma-separated)")
                    TextField("com.apple.keynote, com.company.game", text: $settings.hiddenApps)
                        .textFieldStyle(.roundedBorder)
                }
            }
            Section("Displays") {
                Text("The island lives on the display with a notch. On a Mac without one it draws a 200 pt stand-in at the top of the main display.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Permissions

    private var permissions: some View {
        Form {
            Section("Status") {
                row("Accessibility (hotkey swallow, browser ⏮⏭)", ok: AXIsProcessTrusted(),
                    pane: "com.apple.preference.security?Privacy_Accessibility")
                row("Calendar", ok: {
                    let s = EKEventStore.authorizationStatus(for: .event)
                    if #available(macOS 14, *) { return s == .fullAccess }
                    return s == .authorized
                }(), pane: "com.apple.preference.security?Privacy_Calendars")
                row("Full Disk Access (notification store)", ok: FileManager.default.isReadableFile(atPath: NotificationWatcher.databaseURL.path),
                    pane: "com.apple.preference.security?Privacy_AllFiles")
            }
            Section("Browser Now Playing") {
                Text("Chrome / Brave / Edge: View ▸ Developer ▸ Allow JavaScript from Apple Events (once per browser).")
                    .font(.caption)
            }
            Section("Shortcuts integration") {
                Text("Push a custom live activity by writing JSON to:")
                Text(CustomActivityWatcher.fileURL.path).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text(#"{"title":"Build done","subtitle":"main · 42s","symbol":"hammer.fill","progress":1,"seconds":5}"#)
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            Section("About") {
                Text("NotchIsland \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") · bundle id \(Bundle.main.bundleIdentifier ?? "none")")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func row(_ title: String, ok: Bool, pane: String) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(ok ? .green : .red)
            Text(title)
            Spacer()
            if !ok {
                Button("Open Settings") {
                    if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
                }
            }
        }
    }
}

/// Invisible view that grabs the next key press while `active` is true.
struct KeyRecorder: NSViewRepresentable {
    @Binding var active: Bool
    var onKey: (Int, NSEvent.ModifierFlags) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        if active, context.coordinator.monitor == nil {
            context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                    .intersection([.command, .option, .control, .shift])
                if event.keyCode == 53 && flags.isEmpty {   // Esc cancels
                    DispatchQueue.main.async { active = false }
                    return nil
                }
                guard !flags.isEmpty || event.keyCode >= 96 else { return event }   // need a modifier unless F-key
                onKey(Int(event.keyCode), flags)
                DispatchQueue.main.async { active = false }
                return nil
            }
        } else if !active, let m = context.coordinator.monitor {
            NSEvent.removeMonitor(m)
            context.coordinator.monitor = nil
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator { var monitor: Any? }
}
