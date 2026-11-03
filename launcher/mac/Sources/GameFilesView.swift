// The Game Files page: what is installed, installing from a Games-on-Demand package or a USA disc with
// Title Update 8, the game's integrity check, and the episodes (through the game's own installer).

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct GameFilesView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var files: GameFilesModel
    @State private var gameSource: URL?
    @State private var updateSource: URL?

    var body: some View {
        Page(title: "Game Files", subtitle: "Liberty Recompiled runs your own copy of GTA IV for Xbox 360: the Games on Demand "
             + "package or the USA disc, each with its Title Update 8, and Episodes from Liberty City from its own Games on Demand package. "
             + "The installer checks the release by its media ID and "
             + "hashes; other releases (PAL disc, other updates) are refused.") {
            statusCard
            installCard
            episodesCard
        }
        .onAppear { files.quickCheck(launcher.paths) }
    }

    private var statusCard: some View {
        let s = files.status
        return Card(title: "Installed") {
            row(s.baseGame, "Game (default.xex)", s.baseGame ? launcher.paths.game.path : "Not installed")
            Divider()
            row(s.titleUpdate, "Title Update 8 (default.xexp)", s.titleUpdate ? "Present" : "Missing")
            Divider()
            HStack {
                Text("Size").foregroundStyle(.secondary)
                Text(s.size > 0 ? formatSize(s.size) : "—")
                Spacer()
                if let v = s.verified {
                    Label(v ? "Checked: launch-ready" : "Check failed", systemImage: v ? "checkmark.seal.fill" : "xmark.seal.fill")
                        .foregroundStyle(v ? .green : .red)
                }
                Button("Check Files") { files.verify(launcher.paths, edition: launcher.playEdition) }
                    .disabled(files.busy != nil || !launcher.programPresent || launcher.running != nil)
                    .help("The game's own integrity check: the executables against the supported releases' hashes, "
                          + "and the episodes' layout. Takes about a second.")
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([launcher.paths.game]) }
                    .disabled(!s.baseGame)
            }
            if let problem = s.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let busy = files.busy {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(busy)
                        Spacer()
                        Button("Cancel") { files.cancel() }
                    }
                    if let p = files.progress { ProgressView(value: p) } else { ProgressView().progressViewStyle(.linear) }
                }
            }
        }
    }

    private var installCard: some View {
        Card(title: files.status.looksReady ? "Install again" : "Install",
             footer: "Games on Demand: choose the package's header file (545407F2/00007000/<id>, with its <id>.data folder "
             + "beside it) and the TU from Content/0000000000000000/545407F2/000B0000/ (tu00000006_00000000; tu0000000A_00000000 for Episodes from Liberty City, which installs into game-eflc beside GTA IV). USA disc: "
             + "an .iso or the extracted disc folder, and its TU8 package or a bare default.xexp. About 6.6 GB is copied "
             + "into Application Support.") {
            sourceRow("Game", gameSource, prompt: "Choose the GOD header file, a disc image or a disc folder") { gameSource = $0 }
            Divider()
            sourceRow("Title Update 8", updateSource, prompt: "Choose the TU package or default.xexp") { updateSource = $0 }
            Divider()
            HStack {
                Text("The game window doesn't open; this page shows the progress.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Install") {
                    if let g = gameSource { files.install(launcher.paths, game: g, update: updateSource) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(gameSource == nil || files.busy != nil || !launcher.programPresent || launcher.running != nil)
            }
            Divider()
            HStack {
                Text("Or use the installer inside the game (it opens on its own when nothing is installed).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Open the Game's Installer") { launcher.play(["--install=true"]) }
                    .disabled(launcher.running != nil || !launcher.programPresent)
            }
        }
    }

    private var episodesCard: some View {
        let s = files.status
        return Card(title: "Episodes from Liberty City") {
            row(s.eflc, "Episodes from Liberty City (disc package, both episodes)",
                s.eflc ? launcher.paths.gameEFLC.path + " · choose it on the Play page" : "Not installed: install its package above")
            Divider()
            row(s.tlad, "The Lost and Damned", s.tlad ? launcher.paths.episodes.appendingPathComponent("TLAD").path : "Not installed")
            Divider()
            row(s.tbogt, "The Ballad of Gay Tony", s.tbogt ? launcher.paths.episodes.appendingPathComponent("TBOGT").path : "Not installed")
            Divider()
            HStack {
                Text("Downloadable episodes for GTA IV are installed from their Xbox 360 content packages by the game's episode installer.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Install Episodes…") { launcher.play(["--install_dlc=true"]) }
                    .disabled(launcher.running != nil || !launcher.programPresent || !s.looksReady)
            }
        }
    }

    private func row(_ ok: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(ok ? Color.green : Color.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
    }

    private func sourceRow(_ title: String, _ url: URL?, prompt: String, set: @escaping (URL?) -> Void) -> some View {
        HStack {
            Text(title).frame(width: 120, alignment: .leading)
            Text(url?.path ?? "Not chosen").font(.caption).foregroundStyle(url == nil ? .secondary : .primary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.message = prompt
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK { set(panel.url) }
            }
            if url != nil { Button("Clear") { set(nil) }.buttonStyle(.borderless) }
        }
    }
}
