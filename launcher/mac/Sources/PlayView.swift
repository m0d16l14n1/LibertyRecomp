// The first page: whether everything is ready, the save that will load, a summary of the settings, Play.

import AppKit
import SwiftUI

struct PlayView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var files: GameFilesModel
    @EnvironmentObject var saves: SaveStore
    @ObservedObject private var session = SessionSummary.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                if let problem = launcher.configProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                if launcher.eflcInstalled {
                    Card(title: "Game") {
                        Picker("Game", selection: Binding(get: { launcher.edition }, set: { launcher.edition = $0 })) {
                            ForEach(Launcher.Edition.allCases) { Text($0.label).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .disabled(launcher.running != nil)
                    }
                }
                Card(title: "Ready to play?") {
                    check(launcher.programPresent, "The game's program",
                          launcher.programPresent ? launcher.paths.program.path
                              : "Not found in \(launcher.paths.programDir.path). Build the app (cmake --build out/build/macos-release).")
                    Divider()
                    gameFilesRow
                    Divider()
                    check(true, "Story save", saves.newest.map { "\($0.name), saved \(formatDate($0.saved))" }
                          ?? "No story save yet: the game starts a new game.", neutral: saves.newest == nil)
                }
                Card(title: "Settings for this run", footer: "Change them in the pages on the left; the game reads them when it starts. "
                     + "Rows marked \"also in game\" change in the pause menu too (Display > Advanced).") {
                    summaryRow("Renderer", rendererSummary)
                    summaryRow("Picture", pictureSummary)
                    summaryRow("Frame rate", fpsSummary)
                    summaryRow("Screen", screenSummary)
                    summaryRow("HDR", hdrSummary)
                    summaryRow("Input", (launcher.value("mnk_mode")?.asBool ?? true)
                               ? "Keyboard and mouse or trackpad, and controllers" : "Controllers only")
                }
                if let last = session.lastRun {
                    Text("Last played \(formatDate(last)).").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(28)
            .frame(maxWidth: 820, alignment: .leading)
        }
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: [Color(red: 0.03, green: 0.04, blue: 0.07), Color(red: 0.10, green: 0.12, blue: 0.20),
                                    Color(red: 0.55, green: 0.36, blue: 0.10)],
                           startPoint: .top, endPoint: .bottom)
            // A skyline of drawn blocks with lit windows, not an image from the game.
            Canvas { ctx, size in
                var rng = SeededRandom(seed: 4)
                var x: CGFloat = -10
                while x < size.width {
                    let w = CGFloat.random(in: 18...46, using: &rng)
                    let h = CGFloat.random(in: 30...size.height * 0.8, using: &rng)
                    ctx.fill(Path(CGRect(x: x, y: size.height - h, width: w, height: h)), with: .color(.black.opacity(0.75)))
                    var y = size.height - h + 6
                    while y < size.height - 8 {
                        var wx = x + 4
                        while wx < x + w - 5 {
                            if Int.random(in: 0..<5, using: &rng) == 0 {
                                ctx.fill(Path(CGRect(x: wx, y: y, width: 3, height: 4)),
                                         with: .color(Liberty.amber.opacity(Double.random(in: 0.35...0.9, using: &rng))))
                            }
                            wx += 7
                        }
                        y += 9
                    }
                    x += w + CGFloat.random(in: 1...5, using: &rng)
                }
            }
            .drawingGroup()
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LIBERTY RECOMPILED").font(.system(size: 32, weight: .black, design: .default))
                    Text("Grand Theft Auto IV · recompiled for Apple silicon · native Metal").font(.headline).opacity(0.85)
                }
                .foregroundStyle(.white)
                Spacer()
                playButton
            }
            .padding(22)
        }
        .frame(height: 190)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder private var playButton: some View {
        if launcher.running != nil {
            VStack(alignment: .trailing, spacing: 6) {
                Label("Running", systemImage: "circle.fill").foregroundStyle(.green).font(.headline)
                Button("Quit the Game") { launcher.stop() }
            }
        } else {
            Button {
                launcher.play()
            } label: {
                Label("Play", systemImage: "play.fill")
                    .font(.title2.weight(.bold))
                    .padding(.horizontal, 30).padding(.vertical, 10)
            }
            .buttonStyle(AmberButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(!launcher.programPresent || files.busy != nil)
            .help(files.status.looksReady ? "Start the game" : "Start the game; with no game files it opens its installer")
        }
    }

    @ViewBuilder private var gameFilesRow: some View {
        let s = files.status
        if files.busy != nil {
            HStack { ProgressView().controlSize(.small); Text(files.busy ?? "") }
        } else if launcher.playEdition == .eflc {
            check(s.eflc, "Game files", "Episodes from Liberty City · \(launcher.paths.gameEFLC.path)"
                  + (s.verified == true ? " · checked" : ""),
                  action: s.eflc ? nil : ("Install…", { launcher.section = .gameFiles }))
        } else if s.looksReady {
            check(s.verified != false, "Game files",
                  "\(launcher.paths.game.path) · \(formatSize(s.size))"
                  + (s.verified == true ? " · checked" : "")
                  + (s.tlad || s.tbogt ? " · episodes: " + [s.tlad ? "The Lost and Damned" : nil, s.tbogt ? "The Ballad of Gay Tony" : nil]
                        .compactMap { $0 }.joined(separator: ", ") : ""),
                  action: s.verified == false ? ("Details…", { launcher.section = .gameFiles }) : nil)
        } else {
            check(false, "Game files", s.baseGame ? "Title Update 8 (default.xexp) is missing." : "Not installed yet.",
                  action: ("Install…", { launcher.section = .gameFiles }))
        }
    }

    private func check(_ ok: Bool, _ title: String, _ detail: String, neutral: Bool = false,
                       action: (String, () -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: neutral ? "circle.dashed" : ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                .foregroundStyle(neutral ? Color.secondary : ok ? Color.green : Color.red)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.medium))
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if let action { Button(action.0, action: action.1) }
        }
    }

    private func summaryRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width: 110, alignment: .leading)
            Text(value)
        }
    }

    private var screen: ScreenInfo? { ScreenInfo.all().first }

    private var rendererSummary: String {
        (launcher.value("gpu_plugin")?.asString ?? "gta4-metal") == "gta4-native" ? "Vulkan (MoltenVK)" : "Metal (native)"
    }

    private var pictureSummary: String {
        let out = expectedOutput(launcher, screen: screen)
        let up = Upscaling.current(launcher)
        let size = out.map { "\(Int($0.width))×\(Int($0.height))" } ?? "the screen's size"
        return "\(size) · \(up.label(output: out))"
    }

    private var fpsSummary: String {
        let fps = Int(launcher.value("gta4_frame_limit")?.asDouble ?? 60)
        let vsync = (launcher.value("gta4_present_mode")?.asString ?? "vsync") == "vsync"
        return (fps == 0 ? "Unlocked" : "\(fps) FPS limit") + (vsync ? ", vertical sync" : ", no vertical sync")
    }

    private var screenSummary: String {
        let full = launcher.value("fullscreen")?.asBool ?? true
        return (full ? "Full screen" : "Window") + (screen.map { " on \($0.name) (\($0.summary))" } ?? "")
    }

    private var hdrSummary: String {
        switch launcher.value("gta4_native_hdr_mode")?.asString ?? "off" {
        case "scrgb": return "On (scRGB)"
        case "auto_hdr": return "Auto HDR"
        default: return "Off"
        }
    }
}

/// The same "random" skyline every time it is drawn.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed &* 0x9E3779B97F4A7C15 | 1 }
    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }
}

/// The Play button: the game's amber, the same whether or not the window is in front (the system's
/// prominent style greys out in an inactive window).
struct AmberButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.black)
            .background(RoundedRectangle(cornerRadius: 10)
                .fill(Liberty.amber.opacity(!enabled ? 0.35 : configuration.isPressed ? 0.75 : 1)))
            .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
    }
}
