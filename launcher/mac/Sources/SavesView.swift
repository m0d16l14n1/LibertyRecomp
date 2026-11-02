// The Saves page: the story saves on this Mac, and backups of the saves folder.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SavesView: View {
    @EnvironmentObject var launcher: Launcher
    @EnvironmentObject var store: SaveStore
    @State private var restoring: SaveBackup?

    var body: some View {
        Page(title: "Saves", subtitle: "Story saves and the profile (the game's own settings and stats) live in "
             + "\(launcher.paths.saves.path). Back them up before trying something risky.") {
            if let problem = store.problem {
                Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            }
            savesCard
            backupsCard
        }
        .onAppear { store.refresh() }
        .alert("Restore \(restoring?.name ?? "")?", isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } })) {
            Button("Restore") { if let b = restoring { store.restore(b) }; restoring = nil }
            Button("Cancel", role: .cancel) { restoring = nil }
        } message: {
            Text("The saves there now are backed up first (\"before restore\"), so nothing is lost.")
        }
    }

    private var savesCard: some View {
        Card(title: "Story saves") {
            if store.saves.isEmpty {
                Text("None yet. The game saves in a safehouse bed, or from the phone with Quick save on.")
                    .foregroundStyle(.secondary)
            }
            ForEach(store.saves) { save in
                HStack {
                    Image(systemName: "doc.fill").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(save.name)
                        Text("Saved \(formatDate(save.saved)) · \(formatSize(save.size))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([save.url]) }.buttonStyle(.borderless)
                }
            }
            Divider()
            HStack {
                Button("Back Up Now") { store.backUp() }
                    .disabled(launcher.running != nil)
                    .help(launcher.running != nil ? "Quit the game first, so no save is half written." : "Copy the whole saves folder")
                Spacer()
                Button("Show the Saves Folder") { NSWorkspace.shared.activateFileViewerSelecting([launcher.paths.saves]) }
            }
        }
    }

    private var backupsCard: some View {
        Card(title: "Backups", footer: "Backups are copies of the whole saves folder in \(launcher.paths.saveBackups.path). "
             + "Restoring one replaces the saves folder; the game must be closed.") {
            if store.backups.isEmpty {
                Text("No backups yet.").foregroundStyle(.secondary)
            }
            ForEach(store.backups) { b in
                HStack {
                    Image(systemName: "archivebox").foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(b.name)
                        Text("\(b.saves) story save\(b.saves == 1 ? "" : "s") · \(formatSize(b.size))").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore…") { restoring = b }.disabled(launcher.running != nil)
                    Button("Export…") { export(b) }
                    Button { store.trash(b) } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless).help("Move this backup to the Trash")
                }
            }
        }
    }

    private func export(_ b: SaveBackup) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Liberty Recompiled saves \(b.name).zip"
        panel.allowedContentTypes = [.zip]
        if panel.runModal() == .OK, let url = panel.url { store.export(b, to: url) }
    }
}
