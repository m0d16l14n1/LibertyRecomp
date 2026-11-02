// The game's files: what is installed, and installing or checking them through the game itself
// (`--install_only`, which runs the installer and its integrity check without a window and prints lines the
// launcher reads). The release table, hashes and extraction live in the game (src/install/), not here.

import Foundation

struct InstallStatus {
    var baseGame = false        // default.xex
    var titleUpdate = false     // default.xexp
    var size: Int64 = 0
    var tlad = false
    var tbogt = false
    var verified: Bool?         // the game's own check, when it has run
    var problem: String?

    var looksReady: Bool { baseGame && titleUpdate }
}

@MainActor
final class GameFilesModel: ObservableObject {
    @Published private(set) var status = InstallStatus()
    @Published private(set) var busy: String?          // what is running ("Checking…", "Installing…")
    @Published private(set) var progress: Double?       // 0...1 while copying
    @Published private(set) var output: [String] = []   // the tool's lines, for the details box

    private var process: Process?

    /// The quick look: the two executables and the episodes' folders (no hashing).
    func quickCheck(_ paths: Paths) {
        let fm = FileManager.default
        var s = InstallStatus()
        s.baseGame = fm.fileExists(atPath: paths.game.appendingPathComponent("default.xex").path)
        s.titleUpdate = fm.fileExists(atPath: paths.game.appendingPathComponent("default.xexp").path)
        s.tlad = fm.fileExists(atPath: paths.episodes.appendingPathComponent("TLAD").path)
        s.tbogt = fm.fileExists(atPath: paths.episodes.appendingPathComponent("TBOGT").path)
        s.verified = status.verified
        s.problem = status.problem
        status = s
        let game = paths.game
        Task.detached(priority: .utility) {
            let size = GameFilesModel.folderSize(game)
            await MainActor.run { self.status.size = size }
        }
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                                                     options: [], errorHandler: nil) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in e {
            total += Int64((try? f.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
        }
        return total
    }

    /// The game's integrity check (the same as --install_check): the executables against the supported
    /// releases' hashes, and the episodes' layouts.
    func verify(_ paths: Paths) {
        run(paths, title: "Checking the game files…", arguments: ["--install_only=true"])
    }

    /// Installs from a Games-on-Demand package header or a USA disc image / folder, with its Title Update 8.
    func install(_ paths: Paths, game: URL, update: URL?) {
        var args = ["--install_only=true", "--install_game_source=\(game.path)"]
        if let update { args.append("--install_update_source=\(update.path)") }
        run(paths, title: "Installing…", arguments: args)
    }

    func cancel() { process?.terminate() }

    private func run(_ paths: Paths, title: String, arguments: [String]) {
        guard process == nil else { return }
        let p = Process()
        p.executableURL = paths.program
        p.currentDirectoryURL = paths.programDir
        p.arguments = arguments
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        busy = title
        progress = nil
        output = []
        let splitter = LineSplitter()
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let chunk = h.availableData
            guard !chunk.isEmpty else { return }
            let lines = splitter.feed(chunk)
            Task { @MainActor in lines.forEach { self?.take($0) } }
        }
        p.terminationHandler = { [weak self] proc in
            pipe.fileHandleForReading.readabilityHandler = nil
            let status = proc.terminationStatus
            Task { @MainActor in
                guard let self else { return }
                self.process = nil
                self.busy = nil
                self.progress = nil
                if self.status.verified == nil && status != 0 && self.status.problem == nil {
                    self.status.problem = "The game's installer stopped (status \(status))."
                }
                self.quickCheck(paths)
            }
        }
        do {
            try p.run()
            process = p
            status.verified = nil
            status.problem = nil
        } catch {
            busy = nil
            status.problem = "Could not start \(paths.program.path): \(error.localizedDescription)"
        }
    }

    private func take(_ line: String) {
        if line.hasPrefix("[install] progress ") {
            let parts = line.split(separator: " ")
            if parts.count == 4, let copied = Double(parts[2]), let total = Double(parts[3]), total > 0 {
                progress = copied / total
            }
            return
        }
        guard line.hasPrefix("[") else { return }
        output.append(line)
        if line == "[verify] ok" {
            status.verified = true
        } else if line.hasPrefix("[verify] failed: ") {
            status.verified = false
            status.problem = String(line.dropFirst("[verify] failed: ".count))
        } else if line.hasPrefix("[install] failed: ") {
            status.problem = String(line.dropFirst("[install] failed: ".count))
        }
    }
}

/// Cuts a byte stream into lines; used from the pipe's reading queue only.
final class LineSplitter: @unchecked Sendable {
    private var pending = Data()

    func feed(_ chunk: Data) -> [String] {
        pending.append(chunk)
        var lines: [String] = []
        while let nl = pending.firstIndex(of: 0x0A) {
            lines.append(String(decoding: pending[pending.startIndex..<nl], as: UTF8.self))
            pending.removeSubrange(pending.startIndex...nl)
        }
        return lines
    }
}
