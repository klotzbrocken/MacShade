import Foundation

struct Game: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var sourcePath: String
    var arguments = ""
    /// Adds `-ApplePersistenceIgnoreState YES`, which stops macOS from asking to restore windows after the game was killed.
    var suppressRestoreDialog = true
    /// Shortcuts the launcher manages; they are written to ReShade.ini whenever they changed here (otherwise ReShade's own settings stay).
    var overlayKey = KeyBinding.home
    var screenshotKey = KeyBinding.f12
    /// Turns all effects off and on again without opening the overlay (ReShade's own "Effect toggle key").
    var effectsKey = KeyBinding.end
    /// Start this game when the launcher opens.
    var autoStart = false
    /// OpenGL games: hand the frames to ReShade two frames late instead of waiting for it every frame (more FPS, about 2 frames of extra input delay).
    var pipeline = true
    /// Frames per second the game is held to (0 = no limit).
    var fpsLimit = 0
    /// Opt-in "screen filter" mode: the game runs untouched and ReShade filters a capture of its window (see capture_filter_mac.mm). Off by default.
    var captureMode = false
    /// Screen filter mode: capture the window at half the pixel size (faster, softer). Off by default.
    var captureHalfResolution = false

    enum CodingKeys: String, CodingKey { case id, name, sourcePath, arguments, suppressRestoreDialog, overlayKey, screenshotKey, effectsKey, autoStart, pipeline, fpsLimit, captureMode, captureHalfResolution }
    init(name: String, sourcePath: String) {
        self.name = name; self.sourcePath = sourcePath
        let d = GlobalKeys.load(); overlayKey = d.overlay; screenshotKey = d.screenshot; effectsKey = d.effects   // new games always start from the global shortcuts
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        sourcePath = try c.decode(String.self, forKey: .sourcePath)
        arguments = try c.decodeIfPresent(String.self, forKey: .arguments) ?? ""
        suppressRestoreDialog = try c.decodeIfPresent(Bool.self, forKey: .suppressRestoreDialog) ?? true
        if let key = try? c.decode(KeyBinding.self, forKey: .overlayKey) { overlayKey = key }
        else if let old = try? c.decode(String.self, forKey: .overlayKey) {   // earlier versions stored a preset name
            overlayKey = ["f10": KeyBinding(vk: 0x79), "ctrlShiftO": KeyBinding(vk: 0x4F, ctrl: true, shift: true), "insert": KeyBinding(vk: 0x2D)][old] ?? .home
        }
        screenshotKey = (try? c.decode(KeyBinding.self, forKey: .screenshotKey)) ?? GlobalKeys.load().screenshot
        effectsKey = (try? c.decode(KeyBinding.self, forKey: .effectsKey)) ?? GlobalKeys.load().effects
        autoStart = try c.decodeIfPresent(Bool.self, forKey: .autoStart) ?? false
        pipeline = try c.decodeIfPresent(Bool.self, forKey: .pipeline) ?? true
        fpsLimit = try c.decodeIfPresent(Int.self, forKey: .fpsLimit) ?? 0
        captureMode = try c.decodeIfPresent(Bool.self, forKey: .captureMode) ?? false
        captureHalfResolution = try c.decodeIfPresent(Bool.self, forKey: .captureHalfResolution) ?? false
    }
}

enum Paths {
    static let support: URL = {
        let fm = FileManager.default, base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let new = base.appendingPathComponent("MacShade"), old = base.appendingPathComponent("ReShadeMac")   // the app was called ReShadeMac before: take over its data
        if !fm.fileExists(atPath: new.path), fm.fileExists(atPath: old.path), (try? fm.moveItem(at: old, to: new)) != nil {
            let oldCollection = new.appendingPathComponent("Collections/ReShadeMac")
            if fm.fileExists(atPath: oldCollection.path) { try? fm.removeItem(at: oldCollection) }   // MacLook now ships in "MacShade"; the app copies it again
            // ReShade.ini and presets of every game contain absolute paths of the old folder
            for dir in (try? fm.contentsOfDirectory(at: new.appendingPathComponent("Instances"), includingPropertiesForKeys: nil)) ?? [] {
                for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "ini" {
                    if let s = try? String(contentsOf: f, encoding: .utf8), s.contains(old.path) { try? s.replacingOccurrences(of: old.path, with: new.path).write(to: f, atomically: true, encoding: .utf8) }
                }
            }
            if let c = UserDefaults.standard.string(forKey: "copiesFolder"), c.hasPrefix(old.path) { UserDefaults.standard.set(new.path + c.dropFirst(old.path.count), forKey: "copiesFolder") }
        }
        return new
    }()
    static let gamesJSON = support.appendingPathComponent("games.json")
    static let defaultCopies = support.appendingPathComponent("Games")
    /// Where the signed game copies live: the internal disk by default, or a folder chosen in the settings (e.g. an external drive).
    static var copies: URL {
        if let path = UserDefaults.standard.string(forKey: "copiesFolder"), !path.isEmpty { return URL(fileURLWithPath: path) }
        return defaultCopies
    }
    static var usesCustomCopies: Bool { copies.path != defaultCopies.path }

    /// Disk space used by a folder in bytes (0 if it does not exist).
    nonisolated static func diskUsage(_ url: URL) -> Int64 {
        guard FileManager.default.fileExists(atPath: url.path) else { return 0 }
        let kb = Int64(shell("/usr/bin/du", ["-sk", url.path]).output.split(whereSeparator: { $0 == "\t" || $0 == " " }).first ?? "") ?? 0
        return kb * 1024
    }
    static func copy(for game: Game) -> URL { copies.appendingPathComponent(game.id.uuidString) }

    /// Deletes the signed copy of one game (it is made again at the next start).
    static func deleteCopy(of game: Game) { try? FileManager.default.removeItem(at: copy(for: game)) }
    /// Deletes all copies of the current location.
    static func deleteAllCopies() {
        let fm = FileManager.default
        for name in (try? fm.contentsOfDirectory(atPath: copies.path)) ?? [] where UUID(uuidString: name) != nil { try? fm.removeItem(at: copies.appendingPathComponent(name)) }
    }
    /// Moves the existing copies to a new location and makes it the current one. Copies of games that are running stay where they are.
    nonisolated static func moveCopies(from old: URL, to new: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: new, withIntermediateDirectories: true)
        for name in (try? fm.contentsOfDirectory(atPath: old.path)) ?? [] where UUID(uuidString: name) != nil {
            let dst = new.appendingPathComponent(name)
            if fm.fileExists(atPath: dst.path) { try fm.removeItem(at: dst) }
            try fm.moveItem(at: old.appendingPathComponent(name), to: dst)   // across volumes this copies and then deletes
        }
    }
    static let instances = support.appendingPathComponent("Instances")
    static let logs = support.appendingPathComponent("Logs")
    /// Effect collections: `Collections/<name>/Shaders` and `Collections/<name>/Textures`. Users can add their own folders here.
    static let collections = support.appendingPathComponent("Collections")
    static var dylib: URL { Bundle.main.resourceURL!.appendingPathComponent("libmacshade.dylib") }

    static func instance(for game: Game) -> URL { instances.appendingPathComponent(game.id.uuidString) }
    static let banners = support.appendingPathComponent("Banners")
    static func banner(for game: Game) -> URL { banners.appendingPathComponent(game.id.uuidString + ".img") }

    /// Copies the bundled effect collections to Application Support on first run, so users can add their own .fx files.
    static func seed() {
        let fm = FileManager.default
        for d in [instances, logs, collections] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        if !usesCustomCopies { try? fm.createDirectory(at: copies, withIntermediateDirectories: true) }
        guard let res = Bundle.main.resourceURL?.appendingPathComponent("Collections"),
              let items = try? fm.contentsOfDirectory(atPath: res.path) else { return }
        for name in items where name == "MacShade" || !fm.fileExists(atPath: collections.appendingPathComponent(name).path) {   // our own collection is always refreshed
            try? fm.removeItem(at: collections.appendingPathComponent(name))
            try? fm.copyItem(at: res.appendingPathComponent(name), to: collections.appendingPathComponent(name))
        }
    }

    /// All collection folders that contain a `Shaders` directory.
    static func collectionDirs() -> [URL] {
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: collections.path)) ?? []).sorted()
        return names.map { collections.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.appendingPathComponent("Shaders").path) }
    }
}

@MainActor
final class Store: ObservableObject {
    @Published var games: [Game] = [] { didSet { save() } }

    /// Set when the game list could not be read or written; the UI shows it so settings are never lost silently.
    @Published var storageError: String?

    init() {
        Paths.seed()
        guard FileManager.default.fileExists(atPath: Paths.gamesJSON.path) else { return }
        do { games = try JSONDecoder().decode([Game].self, from: Data(contentsOf: Paths.gamesJSON)) }
        catch {   // keep the unreadable file instead of overwriting it with an empty list at the next save
            let backup = Paths.gamesJSON.deletingLastPathComponent().appendingPathComponent("games.corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: Paths.gamesJSON, to: backup)
            storageError = L("The game list could not be read (%@). The old file was kept as “%@”.", error.localizedDescription, backup.lastPathComponent)
        }
    }
    private func save() {
        do {
            try FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try JSONEncoder().encode(games).write(to: Paths.gamesJSON, options: .atomic)
        } catch { storageError = L("Settings could not be saved: %@", error.localizedDescription) }
    }
    func add(appURL: URL) -> UUID? {
        guard appURL.pathExtension == "app" else { return nil }
        if let existing = games.first(where: { $0.sourcePath == appURL.path }) { return existing.id }
        var g = Game(name: appURL.deletingPathExtension().lastPathComponent, sourcePath: appURL.path)
        let d = GlobalKeys.load(); g.overlayKey = d.overlay; g.screenshotKey = d.screenshot; g.effectsKey = d.effects
        games.append(g); return g.id
    }
}

/// Default shortcuts for new games; "apply to all games" copies them into every game.
enum GlobalKeys {
    struct Set: Codable, Equatable { var overlay = KeyBinding.home, screenshot = KeyBinding.f12, effects = KeyBinding.end }
    static func load() -> Set { UserDefaults.standard.data(forKey: "globalKeys").flatMap { try? JSONDecoder().decode(Set.self, from: $0) } ?? Set() }
    static func save(_ s: Set) { UserDefaults.standard.set(try? JSONEncoder().encode(s), forKey: "globalKeys") }
}
