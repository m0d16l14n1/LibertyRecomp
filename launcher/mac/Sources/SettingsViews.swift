// The settings pages: Graphics, Display & HDR, Game, Controls, Advanced, and About.

import AppKit
import SwiftUI

// MARK: Graphics

struct GraphicsView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var screens = ScreenInfo.all()

    private var metal: Bool { (launcher.value("gpu_plugin")?.asString ?? "gta4-metal") != "gta4-native" }
    private var screen: ScreenInfo? { screens.first }
    private var output: CGSize? { expectedOutput(launcher, screen: screen) }

    var body: some View {
        Page(title: "Graphics", subtitle: "Take effect the next time the game starts, except those marked \"also in game\", "
             + "which the pause menu (Display > Advanced) changes during play too.") {
            suggestionCard
            Card(title: "Renderer") {
                SettingRow(setting: Catalogue.renderer)
                Divider()
                SettingRow(setting: Catalogue.resolution)
                Divider()
                upscalingRow
                Divider()
                SettingRow(setting: Catalogue.antiAliasing)
                Divider()
                SettingRow(setting: Catalogue.frameGeneration, disabled: !metal)
            }
            SettingsCard(title: "Quality", settings: Catalogue.quality)
            SettingsCard(title: "Effects", settings: Catalogue.effects)
            SettingsCard(title: "World", settings: Catalogue.world,
                         footer: "The defaults are the Xbox 360's. Upstream's raised values (draw distance 3x, shadows 2x, "
                         + "population 1.25x) ran slower and, starving the streamer, showed less traffic on an M4.")
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenInfo.all()
        }
    }

    private var suggestionCard: some View {
        let mac = MacInfo.current
        let s = Suggestion.make(mac: mac, screen: screen)
        let up = Upscaling(upscaler: s.upscaler, quality: s.quality)
        let matches = metal && Upscaling.current(launcher) == up
            && Int(launcher.value("gta4_frame_limit")?.asDouble ?? 60) == s.fps
        return Card(title: "For this Mac") {
            HStack(alignment: .top) {
                Image(systemName: mac.isAir ? "laptopcomputer" : "desktopcomputer").font(.title).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(mac.chip)\(mac.gpuCores.map { ", \($0)-core GPU" } ?? ""), \(mac.memoryGB) GB").font(.headline)
                    Text("Suggested: Metal, \(up.label(output: output)), \(s.fps) FPS limit.")
                    Text(s.why).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button(matches ? "In Use" : "Use These") {
                    launcher.set("gpu_plugin", nil)
                    up.apply(launcher)
                    launcher.set("gta4_frame_limit", s.fps == 60 ? nil : .int(s.fps))
                }
                .disabled(matches)
            }
        }
    }

    private var upscalingRow: some View {
        let current = Upscaling.current(launcher)
        let choices = Upscaling.all.filter { metal || $0.upscaler != "metalfx" }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Upscaling")
                Spacer()
                Picker("", selection: Binding(get: { current }, set: { $0.apply(launcher) })) {
                    ForEach(choices) { Text($0.label(output: output)).tag($0) }
                    if !choices.contains(current) { Text(current.label(output: output)).tag(current) }
                }
                .labelsHidden().frame(maxWidth: 360)
            }
            Text("MetalFX (Apple's temporal upscaler) draws the 3D scene smaller and rebuilds the full picture, smoothing "
                 + "edges as it goes; the HUD stays sharp. On an M5 Air, MetalFX Quality held 61 fps with 10.4 ms of GPU a "
                 + "frame, against about 11.5 ms and some slow frames for native-size SMAA. FSR 1 is a simpler spatial "
                 + "upscaler. The pause menu shows this as Upscaling and FSR quality (restart).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: Display

struct DisplayView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var screens = ScreenInfo.all()

    var body: some View {
        Page(title: "Display & HDR", subtitle: "Full screen or a window, the size the game draws at, frame rate and HDR.") {
            Card(title: "Screen", footer: "The game opens on the screen with the menu bar.") {
                ForEach(screens) { s in
                    HStack(spacing: 8) {
                        Image(systemName: s.builtIn ? "laptopcomputer" : "display").frame(width: 22)
                        Text("\(s.index). \(s.name)").fontWeight(s.index == 1 ? .semibold : .regular)
                        Text(s.summary + (s.native.width < s.pixels.width
                                          ? " (scaled mode, backing store \(Int(s.pixels.width))×\(Int(s.pixels.height)))" : ""))
                            .foregroundStyle(.secondary).monospacedDigit()
                        Spacer()
                    }
                    .font(.callout)
                }
                Divider()
                SettingRow(setting: Catalogue.fullscreen)
                Divider()
                SettingRow(setting: Catalogue.aspect)
                Divider()
                SettingRow(setting: Catalogue.airCap)
                Divider()
                SettingRow(setting: Catalogue.panelCap)
                Divider()
                outputRow
            }
            SettingsCard(title: "Frame rate", settings: [Catalogue.frameLimit, Catalogue.vsync, Catalogue.pacing, Catalogue.hud])
            Card(title: "HDR") {
                hdrStatus
                Divider()
                SettingRow(setting: Catalogue.hdrMode)
                Divider()
                SettingRow(setting: Catalogue.paperWhite, disabled: hdrOff)
                Divider()
                SettingRow(setting: Catalogue.peak, disabled: hdrOff)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            screens = ScreenInfo.all()
        }
    }

    private var hdrOff: Bool { (launcher.value("gta4_native_hdr_mode")?.asString ?? "off") == "off" }

    private var outputRow: some View {
        let out = expectedOutput(launcher, screen: screens.first)
        let up = Upscaling.current(launcher)
        return HStack {
            Text("The game will draw")
            Spacer()
            Text(verbatim: out.map { "\(Int($0.width))×\(Int($0.height)) · \(up.label(output: $0))" } ?? "—")
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private var hdrStatus: some View {
        let s = screens.first
        let canHdr = (s?.edr ?? 1) > 1.01
        return HStack(alignment: .top) {
            Image(systemName: canHdr ? "sun.max.fill" : "sun.min").foregroundStyle(canHdr ? .yellow : .secondary).font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(canHdr ? "\(s?.name ?? "This screen") can show HDR" : "\(s?.name ?? "This screen") shows SDR only right now")
                    .font(.headline)
                Text(canHdr
                     ? "It can go \(String(format: "%.1f", s?.edr ?? 1))x above white right now (macOS lowers this as the screen gets brighter)."
                     : "An external HDR monitor shows HDR when \"High Dynamic Range\" is on for it in System Settings > Displays.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: Game

struct GameView: View {
    var body: some View {
        Page(title: "Game", subtitle: "The start, saving, and multiplayer.") {
            SettingsCard(title: "Start-up", settings: [Catalogue.skipIntro, Catalogue.episodePrompt])
            SettingsCard(title: "Saving", settings: [Catalogue.quicksave])
            SettingsCard(title: "Multiplayer", settings: [Catalogue.playerName],
                         footer: "Multiplayer uses a community server and is untested on this fork.")
        }
    }
}

// MARK: Controls

struct ControlsView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var capturing: Keybind?

    var body: some View {
        Page(title: "Controls", subtitle: "A controller (Xbox, DualSense, others macOS knows) works as it is. The keyboard and "
             + "mouse or trackpad play natively when they are on below.") {
            SettingsCard(title: "Keyboard and mouse", settings: Catalogue.mouse)
            SettingsCard(title: "Trackpad", settings: Catalogue.trackpad)
            SettingsCard(title: "Controller", settings: Catalogue.controller)
            keysCard
        }
        .sheet(item: $capturing) { bind in
            KeyCaptureSheet(bind: bind) { name in
                guard let name else { return }
                var keys = keys(of: bind)
                if !keys.contains(name) { keys.append(name) }
                write(bind, keys)
            }
        }
    }

    private func keys(of bind: Keybind) -> [String] {
        let raw = launcher.value(bind.key)?.asString ?? bind.defaultKeys
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private func write(_ bind: Keybind, _ keys: [String]) {
        let joined = keys.joined(separator: ",")
        launcher.set(bind.key, joined == bind.defaultKeys ? nil : .string(joined))
    }

    private var keysCard: some View {
        let all = Keybinds.all
        let changed = all.filter { launcher.config.contains($0.key) }.count
        let enabled = launcher.value("mnk_mode")?.asBool ?? true
        return Card(title: "Controller buttons on the keyboard",
                    footer: "These keys press the controller's buttons in menus and in game modes that read the controller. "
                    + "Click + and press a key to add it; click a key to take it away. LMB, RMB and MMB are the mouse buttons.") {
            HStack {
                Text(changed == 0 ? "All keys are the game's defaults." : "\(changed) changed from the defaults.")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset All Keys") { launcher.setMany(all.map { ($0.key, nil) }) }.disabled(changed == 0)
            }
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                ForEach(all) { bind in
                    GridRow {
                        VStack(alignment: .leading, spacing: 0) {
                            Text(bind.button)
                            if !bind.action.isEmpty { Text(bind.action).font(.caption).foregroundStyle(.secondary) }
                        }
                        .frame(width: 170, alignment: .leading)
                        HStack(spacing: 6) {
                            ForEach(keys(of: bind), id: \.self) { k in
                                Button {
                                    write(bind, keys(of: bind).filter { $0 != k })
                                } label: {
                                    Text(k).font(.system(.callout, design: .rounded).weight(.medium))
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(RoundedRectangle(cornerRadius: 5).fill(Color.primary.opacity(0.08)))
                                        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.18)))
                                }
                                .buttonStyle(.plain)
                                .help("Take \(k) away")
                            }
                            Button { capturing = bind } label: { Image(systemName: "plus") }
                                .buttonStyle(.borderless).help("Add a key")
                        }
                        Button("Reset") { launcher.set(bind.key, nil) }
                            .buttonStyle(.borderless)
                            .opacity(launcher.config.contains(bind.key) ? 1 : 0)
                    }
                }
            }
        }
        .disabled(!enabled)
    }
}

/// Waits for one key press and names it as the game does.
private struct KeyCaptureSheet: View {
    @Environment(\.dismiss) private var dismiss
    let bind: Keybind
    let done: (String?) -> Void
    @State private var monitor: Any?
    @State private var unknown = false

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "keyboard").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Press a key for \(bind.button)").font(.headline)
            Text(unknown ? "That key can't be used by the game; try another." : "Hold Shift, Control or Option with it for a combination.")
                .font(.caption).foregroundStyle(unknown ? .orange : .secondary)
            Button("Cancel") { finish(nil) }
        }
        .padding(28)
        .frame(width: 340)
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
                let f = e.modifierFlags
                if let name = Keybinds.name(keyCode: e.keyCode, shift: f.contains(.shift), control: f.contains(.control),
                                            option: f.contains(.option)) {
                    finish(name)
                } else {
                    unknown = true
                }
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) } }
    }

    private func finish(_ name: String?) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        done(name)
        dismiss()
    }
}

// MARK: Advanced

struct AdvancedView: View {
    @EnvironmentObject var launcher: Launcher
    @State private var args = ""
    @State private var confirmReset = false
    @State private var confirmCache = false
    @State private var cacheNote: String?

    var body: some View {
        Page(title: "Advanced", subtitle: "Files, logs, the shader cache, and options for testing.") {
            Card(title: "When the game starts") {
                Picker("", selection: Binding(get: { launcher.afterLaunch }, set: { launcher.afterLaunch = $0 })) {
                    ForEach(Launcher.AfterLaunch.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }
            Card(title: "Files") {
                pathRow("Settings", launcher.paths.config, open: true)
                Divider()
                pathRow("Errors log", launcher.paths.errorsLog, open: true)
                Divider()
                pathRow("Logs", launcher.paths.logs, open: false)
                Divider()
                pathRow("Saves", launcher.paths.saves, open: false)
                Divider()
                pathRow("Game files", launcher.paths.game, open: false)
                Divider()
                pathRow("Benchmarks", launcher.paths.perf, open: false)
            }
            Card(title: "Metal pipeline cache", footer: "The game records every pipeline it builds and compiles them behind the "
                 + "loading screen next time. Clearing the cache makes the next start rebuild it (about 5 s for the bundled "
                 + "set on an M5) and is only worth doing if the game crashes or shows a black screen at the loading screen.") {
                HStack {
                    Text(cacheNote ?? launcher.paths.shaderCache.path).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                    Spacer()
                    Button("Clear the Cache…") { confirmCache = true }.disabled(launcher.running != nil)
                }
            }
            SettingsCard(title: "Logging", settings: [Setting("log_level", "Log detail", .choice([
                Choice(label: "Errors only", value: .string("error")), Choice(label: "Warnings", value: .string("warn")),
                Choice(label: "Information (default)", value: .string("info")), Choice(label: "Debug (large)", value: .string("debug")),
            ]), .string("info"), "How much the game writes to its log. Warnings and errors always go to the errors log.")])
            SettingsCard(title: "Native audio mixer (testing)", settings: Catalogue.nativeAudio)
            Card(title: "More options for the game", footer: "Command-line options the game gets when it starts from the launcher, "
                 + "for example --diagnostics=true or --gta4_metal_frame_log=/tmp/frames.csv. Separate them with spaces. "
                 + "Options given here are not saved into the settings file.") {
                TextField("--option=value", text: $args)
                    .font(.system(.body, design: .monospaced))
                    .onAppear { args = launcher.extraArguments }
                    .onSubmit { launcher.extraArguments = args }
                    .onChange(of: args) { _, v in launcher.extraArguments = v }
            }
            Card(title: "Start over") {
                HStack {
                    Text("Every setting back to the game's defaults. A copy of the old settings is kept beside them "
                         + "(native.toml.bak). Saves aren't touched.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Reset All Settings…", role: .destructive) { confirmReset = true }
                }
            }
        }
        .alert("Reset all settings?", isPresented: $confirmReset) {
            Button("Reset", role: .destructive, action: resetAll)
            Button("Cancel", role: .cancel) {}
        } message: { Text("Your saves aren't touched.") }
        .alert("Clear the Metal pipeline cache?", isPresented: $confirmCache) {
            Button("Move to Trash", role: .destructive, action: clearCache)
            Button("Cancel", role: .cancel) {}
        } message: { Text("The game's pipeline archive and Apple's shader cache for the app go to the Trash. The next start rebuilds them.") }
    }

    private func pathRow(_ title: String, _ url: URL, open: Bool) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Text(url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            if open { Button("Open") { NSWorkspace.shared.open(url) }.disabled(!FileManager.default.fileExists(atPath: url.path)) }
            Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                .disabled(!FileManager.default.fileExists(atPath: url.path))
        }
    }

    /// The game's own archive (shader_cache/gta4-metal) and Apple's per-app cache
    /// (<DARWIN_USER_CACHE_DIR>/<bundle id>/com.apple.metal), to the Trash.
    private func clearCache() {
        var targets = [launcher.paths.shaderCache.appendingPathComponent("gta4-metal")]
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, buffer.count) > 0 {
            let bundle = Bundle.main.bundleIdentifier ?? "OZORDI.LibertyRecomp"
            targets.append(URL(fileURLWithPath: String(cString: buffer)).appendingPathComponent(bundle)
                .appendingPathComponent("com.apple.metal"))
        }
        let present = targets.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !present.isEmpty else { cacheNote = "Nothing to clear."; return }
        NSWorkspace.shared.recycle(present) { _, error in
            Task { @MainActor in
                cacheNote = error.map { "Could not clear: \($0.localizedDescription)" }
                    ?? "Cleared \(present.count) folder\(present.count == 1 ? "" : "s"); the next start rebuilds the cache."
            }
        }
    }

    private func resetAll() {
        let fm = FileManager.default
        let backup = launcher.paths.config.appendingPathExtension("bak")
        try? fm.removeItem(at: backup)
        try? fm.copyItem(at: launcher.paths.config, to: backup)
        try? Launcher.header.write(to: launcher.paths.config, atomically: true, encoding: .utf8)
        launcher.loadConfig()
    }
}

// MARK: About

struct AboutView: View {
    var body: some View {
        Page(title: "About", subtitle: "Grand Theft Auto IV, statically recompiled from the Xbox 360 to run natively on Apple silicon.") {
            Card(title: "This launcher") {
                Text("Installs and checks the game's files, keeps your saves, and holds the settings that need the game to start "
                     + "again. What can change during play is in the game itself: the pause menu's Display > Advanced page.")
                Text("It is the Midnight Club: Los Angeles port's launcher (mcla-recomp, launcher/mac), carried over to this game.")
                    .foregroundStyle(.secondary)
            }
            Card(title: "Credits") {
                credit("LibertyRecomp", "by OZORDI and contributors: the recompilation this fork builds on; the PAL fork by hamishakl.")
                credit("ReXGlue SDK", "by Tom Clay and contributors; Xenia by Ben Vanik and contributors; XenonRecomp by hedge-dev.")
                credit("FusionFix", "by ThirteenAG and contributors, whose fixes and overlays the mod support follows.")
                credit("mcla-recomp", "the Midnight Club: LA port: this launcher, the dev pad, and several SDK fixes.")
            }
            Text("Grand Theft Auto IV is Rockstar Games' (Take-Two Interactive). This project has no game data in it; you need "
                 + "your own copy.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func credit(_ name: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).font(.body.weight(.medium))
            Text(text).font(.caption).foregroundStyle(.secondary)
        }
    }
}
