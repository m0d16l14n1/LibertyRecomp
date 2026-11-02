// The launcher: a window with a sidebar (Play, Game Files, Saves, the settings pages, About).

import AppKit
import SwiftUI

@main
struct LibertyLauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var launcher = Launcher()
    @StateObject private var files = GameFilesModel()

    var body: some Scene {
        WindowGroup("Liberty Recompiled") {
            RootView()
                .environmentObject(launcher)
                .environmentObject(files)
                .environmentObject(SaveStoreHolder.shared(launcher))
                .frame(minWidth: 860, minHeight: 600)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                    launcher.reloadIfChanged()
                    SaveStoreHolder.shared(launcher).refresh()
                    files.quickCheck(launcher.paths)
                }
        }
        .defaultSize(width: 1040, height: 800)
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Game") {
                Button("Play") { launcher.play() }
                    .keyboardShortcut("p", modifiers: [.command])
                    .disabled(launcher.running != nil || !launcher.programPresent)
                Button("Open Settings File") { NSWorkspace.shared.open(launcher.paths.config) }
                Button("Open Errors Log") { NSWorkspace.shared.open(launcher.paths.errorsLog) }
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// One save store for the app.
@MainActor
enum SaveStoreHolder {
    private static var store: SaveStore?
    static func shared(_ launcher: Launcher) -> SaveStore {
        if let store { return store }
        let s = SaveStore(paths: launcher.paths)
        store = s
        return s
    }
}

struct RootView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var files: GameFilesModel

    var body: some View {
        NavigationSplitView {
            List(selection: $launcher.section) {
                Section {
                    row(.play)
                    row(.gameFiles)
                    row(.saves)
                }
                Section("Settings") {
                    row(.graphics)
                    row(.display)
                    row(.gameplay)
                    row(.controls)
                    row(.advanced)
                }
                Section {
                    row(.about)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 200)
        } detail: {
            Group {
                switch launcher.section ?? .play {
                case .play: PlayView()
                case .gameFiles: GameFilesView()
                case .saves: SavesView()
                case .graphics: GraphicsView()
                case .display: DisplayView()
                case .gameplay: GameView()
                case .controls: ControlsView()
                case .advanced: AdvancedView()
                case .about: AboutView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .tint(Liberty.amber)
        .onAppear {
            files.quickCheck(launcher.paths)
            SessionSummary.shared.refresh(launcher.paths)
            // For tests: LIBERTY_LAUNCHER_PLAY=1 presses Play once the window is up.
            if ProcessInfo.processInfo.environment["LIBERTY_LAUNCHER_PLAY"] == "1" { launcher.play() }
        }
        .alert(item: $launcher.lastExit) { exit in
            Alert(title: Text(exit.crashed ? "The game crashed" : "The game ended with an error (\(exit.status))"),
                  message: Text(exit.logTail.isEmpty ? "The errors log has nothing from this run."
                                : "The end of the errors log:\n\n" + exit.logTail.suffix(1500)),
                  primaryButton: .default(Text("Open the Log")) { NSWorkspace.shared.open(launcher.paths.errorsLog) },
                  secondaryButton: .cancel(Text("Close")))
        }
    }

    private func row(_ s: Launcher.Section) -> some View {
        Label(s.title, systemImage: s.symbol).tag(s)
    }
}

/// The game's own UI colours (gta4_ui_theme: black panels, amber accent).
enum Liberty {
    static let amber = Color(red: 0.98, green: 0.68, blue: 0.10)
}

// MARK: Shared pieces

/// A page: a title, a line under it, and its content in a scroll view.
struct Page<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle.weight(.semibold))
                    if !subtitle.isEmpty {
                        Text(subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }
}

/// A group of rows on a rounded background.
struct Card<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title { Text(title).font(.headline) }
            VStack(alignment: .leading, spacing: 12) { content }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The badge of a setting that the game also changes during play.
struct LiveBadge: View {
    var body: some View {
        Text("also in game")
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(Liberty.amber.opacity(0.15)))
            .foregroundStyle(Liberty.amber)
            .help("The pause menu (Display > Advanced) changes this during play too.")
    }
}

/// One option of mcla.toml, shown as its kind asks.
struct SettingRow: View {
    @EnvironmentObject var launcher: Launcher
    let setting: Setting
    var disabled = false

    private var current: TomlValue { launcher.value(setting.key) ?? setting.defaultValue }
    private var isSet: Bool { launcher.config.contains(setting.key) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(setting.title)
                if setting.live { LiveBadge() }
                Spacer(minLength: 16)
                control.disabled(disabled)
            }
            Text(setting.info).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .contextMenu {
            Button("Back to the Default") { launcher.set(setting.key, nil) }.disabled(!isSet)
        }
    }

    @ViewBuilder private var control: some View {
        switch setting.kind {
        case .choice(let choices):
            let selected = choices.first { $0.value.key == current.key }
            Picker("", selection: Binding<Choice?>(
                get: { selected },
                set: { if let c = $0 { save(c.value) } })) {
                ForEach(choices) { c in Text(c.label).tag(Optional(c)) }
                if selected == nil {
                    Text("Other (\(current.literal))").tag(Optional<Choice>.none)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 300)
        case .toggle:
            Toggle("", isOn: Binding(get: { current.asBool ?? false }, set: { save(.bool($0)) }))
                .labelsHidden().toggleStyle(.switch)
        case .level(let lo, let hi, let step, let unit):
            LevelControl(value: current.asDouble ?? 0, lo: lo, hi: hi, step: step, unit: unit, autoLabel: nil, start: lo) { save(.double($0)) }
        case .text(let placeholder):
            TextControl(value: current.asString ?? "", placeholder: placeholder) { save(.string($0)) }
        }
    }

    /// The game's default is written as no line at all, so a later change of default reaches the player.
    private func save(_ value: TomlValue) {
        launcher.set(setting.key, value.key == setting.defaultValue.key ? nil : value)
    }
}

struct LevelControl: View {
    let value: Double
    let lo: Double, hi: Double, step: Double
    let unit: String
    let autoLabel: String?
    let start: Double
    let commit: (Double) -> Void
    @State private var editing: Double?

    var body: some View {
        let isAuto = autoLabel != nil && value == 0
        HStack(spacing: 10) {
            if let autoLabel {
                Toggle(autoLabel, isOn: Binding(get: { isAuto }, set: { commit($0 ? 0 : start) }))
                    .toggleStyle(.checkbox)
            }
            if !isAuto {
                Slider(value: Binding(get: { editing ?? min(max(value, lo), hi) }, set: { editing = $0 }),
                       in: lo...hi, step: step) { e in
                    if !e, let v = editing { commit(v); editing = nil }
                }
                .frame(width: 160)
                Text("\(Int(editing ?? value)) \(unit)").monospacedDigit().frame(width: 80, alignment: .trailing)
            }
        }
    }
}

struct TextControl: View {
    let value: String
    let placeholder: String
    let commit: (String) -> Void
    @State private var text = ""

    var body: some View {
        TextField(placeholder, text: $text)
            .frame(width: 200)
            .onAppear { text = value }
            .onChange(of: value) { _, v in text = v }
            .onSubmit { commit(text) }
    }
}

/// A row of settings with a reset for all of them.
struct SettingsCard: View {
    @EnvironmentObject var launcher: Launcher
    let title: String
    let settings: [Setting]
    var footer: String? = nil

    var body: some View {
        Card(title: title, footer: footer) {
            ForEach(Array(settings.enumerated()), id: \.element.id) { i, s in
                if i > 0 { Divider() }
                SettingRow(setting: s)
            }
        }
    }
}

func formatSize(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

func formatDate(_ date: Date?) -> String {
    guard let date else { return "—" }
    let f = DateFormatter()
    f.dateStyle = .medium
    f.timeStyle = .short
    return f.string(from: date)
}
