// Where things are, the settings file, and the game's process.

import AppKit
import Foundation

struct Paths {
    /// The folder with the game's program: Contents/MacOS of Liberty Recompiled.app, or, for a launcher run
    /// on its own, LIBERTY_DIR (or the launcher's own folder).
    let programDir: URL
    /// ~/Library/Application Support/LibertyRecomp (LIBERTY_SUPPORT for tests): the game's files, saves,
    /// shader cache, logs and native.toml, as the game itself lays them out (gta4_app.h).
    let support: URL

    var program: URL { programDir.appendingPathComponent("Liberty Recompiled") }
    var config: URL { support.appendingPathComponent("native.toml") }
    var game: URL { support.appendingPathComponent("game", isDirectory: true) }
    /// Episodes from Liberty City, installed from its own Games-on-Demand package (it cannot share GTA IV's folder:
    /// its DLC1/DLC.rpf switches the executable into the episode menu); run with --gta4_edition=eflc.
    var gameEFLC: URL { support.appendingPathComponent("game-eflc", isDirectory: true) }
    var episodes: URL { support.appendingPathComponent("dlc", isDirectory: true) }
    var saves: URL { support.appendingPathComponent("saves", isDirectory: true) }
    var saveBackups: URL { support.appendingPathComponent("save-backups", isDirectory: true) }
    var shaderCache: URL { support.appendingPathComponent("shader_cache", isDirectory: true) }
    var logs: URL { support.appendingPathComponent("logs", isDirectory: true) }
    var errorsLog: URL { logs.appendingPathComponent("Liberty Recompiled-errors.log") }
    var perf: URL { support.appendingPathComponent("perf", isDirectory: true) }

    static func current() -> Paths {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        var dir = Bundle.main.executableURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        if let v = env["LIBERTY_DIR"], !v.isEmpty {
            dir = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        }
        var support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LibertyRecomp", isDirectory: true)
        if let v = env["LIBERTY_SUPPORT"], !v.isEmpty {
            support = URL(fileURLWithPath: (v as NSString).expandingTildeInPath, isDirectory: true)
        }
        try? fm.createDirectory(at: support, withIntermediateDirectories: true)
        return Paths(programDir: dir.standardizedFileURL, support: support)
    }
}

/// The launcher's state: native.toml, and the game when it runs.
@MainActor
final class Launcher: ObservableObject {
    let paths = Paths.current()

    @Published private(set) var config = TomlDocument(text: "")
    @Published var configProblem: String?
    @Published private(set) var running: Process?
    @Published var lastExit: GameExit?
    @Published var section: Section? = .play

    private var configDate: Date?
    /// Set by Quit the Game: the SIGTERM that ends the game is then not reported as a crash.
    private var stopRequested = false

    struct GameExit: Identifiable {
        let id = UUID()
        let status: Int32
        let crashed: Bool
        let logTail: String
    }

    enum Section: String, CaseIterable, Identifiable {
        case play, gameFiles, saves, graphics, display, gameplay, controls, advanced, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .play: return "Play"
            case .gameFiles: return "Game Files"
            case .saves: return "Saves"
            case .graphics: return "Graphics"
            case .display: return "Display & HDR"
            case .gameplay: return "Game"
            case .controls: return "Controls"
            case .advanced: return "Advanced"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .play: return "play.circle"
            case .gameFiles: return "opticaldisc"
            case .saves: return "externaldrive"
            case .graphics: return "cube.transparent"
            case .display: return "sun.max"
            case .gameplay: return "star"
            case .controls: return "gamecontroller"
            case .advanced: return "wrench.and.screwdriver"
            case .about: return "info.circle"
            }
        }
    }

    init() {
        loadConfig()
        // For screenshots and tests: LIBERTY_LAUNCHER_PAGE=graphics opens that page.
        if let page = ProcessInfo.processInfo.environment["LIBERTY_LAUNCHER_PAGE"], let s = Section(rawValue: page) {
            section = s
        }
    }

    // MARK: Settings file

    static let header = "# Liberty Recompiled settings; the launcher and the game's pause menu both write here.\n"

    func loadConfig() {
        let url = paths.config
        configDate = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        guard FileManager.default.fileExists(atPath: url.path) else {
            config = TomlDocument(text: Launcher.header)
            configProblem = nil
            return
        }
        do {
            config = TomlDocument(text: try String(contentsOf: url, encoding: .utf8))
            configProblem = nil
        } catch {
            configProblem = "Could not read \(url.path): \(error.localizedDescription)"
        }
    }

    /// The pause menu saves into the same file: read it again when it changed.
    func reloadIfChanged() {
        let date = (try? FileManager.default.attributesOfItem(atPath: paths.config.path)[.modificationDate]) as? Date
        if date != configDate { loadConfig() }
    }

    func value(_ key: String) -> TomlValue? {
        // The game writes an empty string for "the title's default" (gpu_plugin, resolution): read as unset.
        if case .string(let s)? = config.value(key), s.isEmpty { return nil }
        return config.value(key)
    }

    /// Sets (or, with nil, removes) one option and writes the file at once.
    func set(_ key: String, _ value: TomlValue?) { setMany([(key, value)]) }

    func setMany(_ changes: [(String, TomlValue?)]) {
        reloadIfChanged()
        var doc = config
        for (key, value) in changes {
            if let value { doc.set(key, value) } else { doc.remove(key) }
        }
        write(doc)
    }

    private func write(_ doc: TomlDocument) {
        do {
            try FileManager.default.createDirectory(at: paths.support, withIntermediateDirectories: true)
            try doc.text.write(to: paths.config, atomically: true, encoding: .utf8)
            config = doc
            configDate = (try? FileManager.default.attributesOfItem(atPath: paths.config.path)[.modificationDate]) as? Date
            configProblem = nil
        } catch {
            configProblem = "Could not write \(paths.config.path): \(error.localizedDescription)"
        }
    }

    // MARK: The game

    var programPresent: Bool { FileManager.default.isExecutableFile(atPath: paths.program.path) }

    enum AfterLaunch: String, CaseIterable, Identifiable {
        case stay, hide, quit
        var id: String { rawValue }
        var label: String {
            switch self {
            case .stay: return "Keep the launcher open"
            case .hide: return "Hide the launcher (it comes back when the game ends)"
            case .quit: return "Quit the launcher"
            }
        }
    }

    var afterLaunch: AfterLaunch {
        get { AfterLaunch(rawValue: UserDefaults.standard.string(forKey: "afterLaunch") ?? "") ?? .hide }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "afterLaunch"); objectWillChange.send() }
    }

    /// Which game Play starts: GTA IV, or Episodes from Liberty City when its package is installed.
    enum Edition: String, CaseIterable, Identifiable {
        case gta4, eflc
        var id: String { rawValue }
        var label: String { self == .gta4 ? "Grand Theft Auto IV" : "Episodes from Liberty City" }
    }

    var edition: Edition {
        get { Edition(rawValue: UserDefaults.standard.string(forKey: "edition") ?? "") ?? .gta4 }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "edition"); objectWillChange.send() }
    }

    var eflcInstalled: Bool {
        FileManager.default.fileExists(atPath: paths.gameEFLC.appendingPathComponent("default.xex").path)
    }

    /// The edition Play runs: the chosen one, or GTA IV when Episodes from Liberty City is not installed.
    var playEdition: Edition { edition == .eflc && eflcInstalled ? .eflc : .gta4 }

    /// Extra command-line options for the game, as typed (split on spaces; quotes keep spaces).
    var extraArguments: String {
        get { UserDefaults.standard.string(forKey: "extraArguments") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "extraArguments"); objectWillChange.send() }
    }

    static func splitArguments(_ text: String) -> [String] {
        var out: [String] = []
        var current = ""
        var quote: Character?
        var any = false
        for c in text {
            if let q = quote {
                if c == q { quote = nil } else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c; any = true
            } else if c == " " || c == "\t" || c == "\n" {
                if any || !current.isEmpty { out.append(current) }
                current = ""; any = false
            } else {
                current.append(c)
            }
        }
        if any || !current.isEmpty { out.append(current) }
        return out
    }

    /// Starts the game; `arguments` come before the extra options from the Advanced page.
    func play(_ arguments: [String] = []) {
        guard running == nil else { return }
        reloadIfChanged()
        let process = Process()
        process.executableURL = paths.program
        process.currentDirectoryURL = paths.programDir
        let editionArguments = playEdition == .eflc ? ["--gta4_edition=eflc"] : []
        process.arguments = editionArguments + arguments + Launcher.splitArguments(extraArguments)
        // The game logs to its own files (logs/, and the errors log always); what it prints goes nowhere.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = Date()
        stopRequested = false
        process.terminationHandler = { [weak self] p in
            let status = p.terminationStatus
            let crashed = p.terminationReason == .uncaughtSignal
            Task { @MainActor in
                guard let self else { return }
                self.running = nil
                self.loadConfig()
                let stopped = self.stopRequested
                self.stopRequested = false
                if !stopped && (crashed || status != 0) {
                    let tail = Launcher.tail(of: self.paths.errorsLog, lines: 40, since: started)
                    self.lastExit = GameExit(status: status, crashed: crashed, logTail: tail)
                }
                if self.afterLaunch == .hide {
                    NSApp.unhide(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
                SessionSummary.shared.refresh(self.paths)
            }
        }
        do {
            try process.run()
            running = process
            lastExit = nil
            switch afterLaunch {
            case .stay: break
            case .hide: NSApp.hide(nil)
            case .quit: NSApp.terminate(nil)
            }
        } catch {
            lastExit = GameExit(status: -1, crashed: false,
                                logTail: "Could not start \(paths.program.path): \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let running else { return }
        stopRequested = true
        running.terminate()
    }

    /// The last lines of a log; with `since`, only when the file was written after that time.
    static func tail(of url: URL, lines: Int, since: Date? = nil) -> String {
        if let since, let date = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date,
           date < since { return "" }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > 64 * 1024 ? size - 64 * 1024 : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}

/// When the game last ran (its errors log is written on every run).
@MainActor
final class SessionSummary: ObservableObject {
    static let shared = SessionSummary()
    @Published private(set) var lastRun: Date?

    func refresh(_ paths: Paths) {
        lastRun = (try? FileManager.default.attributesOfItem(atPath: paths.errorsLog.path)[.modificationDate]) as? Date
    }
}
