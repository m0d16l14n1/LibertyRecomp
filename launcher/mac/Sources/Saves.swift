// The saves: the story saves the game keeps (saves/<player>/545407F2/00000001/<save>, as the SDK's content
// manager lays out saved-game packages), and dated copies of the whole saves folder the launcher makes.

import AppKit
import Foundation

struct StorySave: Identifiable {
    let url: URL
    let player: String
    let saved: Date?
    let size: Int64
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

struct SaveBackup: Identifiable {
    let url: URL
    let made: Date?
    let size: Int64
    let saves: Int
    var id: String { url.path }
    var name: String { url.lastPathComponent }
}

@MainActor
final class SaveStore: ObservableObject {
    @Published private(set) var saves: [StorySave] = []
    @Published private(set) var backups: [SaveBackup] = []
    @Published var problem: String?

    let paths: Paths
    init(paths: Paths) { self.paths = paths; refresh() }

    static let titleId = "545407F2"
    static let savedGameType = "00000001"

    var newest: StorySave? { saves.max { ($0.saved ?? .distantPast) < ($1.saved ?? .distantPast) } }

    func refresh() {
        saves = SaveStore.storySaves(in: paths.saves)
        let fm = FileManager.default
        let dirs = (try? fm.contentsOfDirectory(at: paths.saveBackups, includingPropertiesForKeys: [.creationDateKey],
                                               options: [.skipsHiddenFiles])) ?? []
        backups = dirs.filter { $0.hasDirectoryPath }.map { url in
            SaveBackup(url: url, made: (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? nil,
                       size: GameFilesModel.folderSize(url), saves: SaveStore.storySaves(in: url).count)
        }
        .sorted { ($0.made ?? .distantPast) > ($1.made ?? .distantPast) }
    }

    static func storySaves(in root: URL) -> [StorySave] {
        let fm = FileManager.default
        var out: [StorySave] = []
        let players = (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        for player in players where player.hasDirectoryPath {
            let folder = player.appendingPathComponent(titleId).appendingPathComponent(savedGameType)
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                                                     options: [.skipsHiddenFiles])) ?? []
            for item in items {
                // A package is a folder; its newest file is when it was saved.
                var newest: Date?
                if let e = fm.enumerator(at: item, includingPropertiesForKeys: [.contentModificationDateKey]) {
                    for case let f as URL in e {
                        if let d = try? f.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                           d > (newest ?? .distantPast) { newest = d }
                    }
                }
                out.append(StorySave(url: item, player: player.lastPathComponent,
                                     saved: newest ?? (try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil,
                                     size: GameFilesModel.folderSize(item)))
            }
        }
        return out.sorted { ($0.saved ?? .distantPast) > ($1.saved ?? .distantPast) }
    }

    private static func stamp() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: Date())
    }

    /// Copies the whole saves folder (story saves, the profile with the game's settings and stats).
    @discardableResult
    func backUp(note: String = "") -> URL? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: paths.saves.path) else { problem = "There is no saves folder yet."; return nil }
        let target = paths.saveBackups.appendingPathComponent(SaveStore.stamp() + (note.isEmpty ? "" : " " + note))
        do {
            try fm.createDirectory(at: paths.saveBackups, withIntermediateDirectories: true)
            try fm.copyItem(at: paths.saves, to: target)
            problem = nil
            refresh()
            return target
        } catch {
            problem = "Could not back up the saves: \(error.localizedDescription)"
            return nil
        }
    }

    /// Puts a backup back. What is there now is backed up first, so nothing is lost.
    func restore(_ backup: SaveBackup) {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.saves.path) {
            guard backUp(note: "before restore") != nil else { return }
        }
        do {
            let staging = paths.support.appendingPathComponent("saves.restoring")
            try? fm.removeItem(at: staging)
            try fm.copyItem(at: backup.url, to: staging)
            if fm.fileExists(atPath: paths.saves.path) {
                _ = try fm.replaceItemAt(paths.saves, withItemAt: staging)
            } else {
                try fm.moveItem(at: staging, to: paths.saves)
            }
            problem = nil
        } catch {
            problem = "Could not restore \(backup.name): \(error.localizedDescription)"
        }
        refresh()
    }

    /// Moves a backup to the Trash (it can be put back from there).
    func trash(_ backup: SaveBackup) {
        NSWorkspace.shared.recycle([backup.url]) { [weak self] _, error in
            Task { @MainActor in
                if let error { self?.problem = "Could not move \(backup.name) to the Trash: \(error.localizedDescription)" }
                self?.refresh()
            }
        }
    }

    /// A .zip of a backup, made with ditto (keeps everything as Finder's Compress does).
    func export(_ backup: SaveBackup, to zip: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-c", "-k", "--keepParent", backup.url.path, zip.path]
        do {
            try p.run()
            p.waitUntilExit()
            problem = p.terminationStatus == 0 ? nil : "ditto could not write \(zip.path)."
        } catch {
            problem = "Could not export: \(error.localizedDescription)"
        }
    }
}
