import AppKit
import CryptoKit
import Foundation

enum Phase: Equatable { case idle, preparing(String), running, failed(String) }
/// How ReShade reaches the game's frames.
enum GraphicsAPI {
    case vulkan   // MoltenVK: hooked directly, with depth buffer access
    case bridge   // OpenGL or Metal: processed through the IOSurface bridge (no depth buffer)
    case staticVulkan   // Vulkan driver linked into the game: ReShade cannot hook it
    case unknown
    var shortLabel: String {
        switch self { case .vulkan: return "Vulkan"; case .bridge: return L("OpenGL/Metal bridge"); case .staticVulkan: return L("Not supported"); case .unknown: return L("Unknown") }
    }
    var label: String {
        switch self {
        case .vulkan: return L("Vulkan (MoltenVK) – fully supported, including depth buffer")
        case .bridge: return L("OpenGL/Metal – via the ReShade bridge (depth buffer with “Smooth frame rate”)")
        case .staticVulkan: return L("Vulkan is built into the game – ReShade cannot be loaded.")
        case .unknown: return L("Graphics API unknown – ReShade will try anyway")
        }
    }
}

struct GameInfo {
    var executable: String?
    var archs: String
    var api: GraphicsAPI
}

@discardableResult
func shell(_ exe: String, _ args: [String]) -> (status: Int32, output: String) {
    let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
    do { try p.run() } catch { return (-1, "\(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
    return (p.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// Splits a command line into arguments, honouring simple "double" and 'single' quotes.
func splitArguments(_ s: String) -> [String] {
    var out: [String] = [], cur = "", quote: Character? = nil, has = false
    for c in s {
        if let q = quote { if c == q { quote = nil } else { cur.append(c) } }
        else if c == "\"" || c == "'" { quote = c; has = true }
        else if c == " " || c == "\t" { if has || !cur.isEmpty { out.append(cur); cur = ""; has = false } }
        else { cur.append(c) }
    }
    if has || !cur.isEmpty { out.append(cur) }
    return out
}

func inspectGame(_ path: String) -> GameInfo {
    let url = URL(fileURLWithPath: path)
    let exe = Bundle(url: url)?.executableURL
    let archs = exe.map { e -> String in
        let r = shell("/usr/bin/lipo", ["-archs", e.path])
        let out = r.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return r.status == 0 && !out.isEmpty ? out : "?"   // e.g. a launcher script instead of a program
    } ?? "?"
    var api = GraphicsAPI.unknown
    let fm = FileManager.default
    if let exe, shell("/usr/bin/nm", ["-gU", exe.path]).output.contains(" _vkCreateInstance") { return GameInfo(executable: exe.path, archs: archs, api: .staticVulkan) }   // e.g. Raze: MoltenVK is part of the program
    if let en = fm.enumerator(atPath: url.appendingPathComponent("Contents").path) {
        for case let f as String in en where f.lowercased().contains("moltenvk") || f.lowercased().contains("libvulkan") { api = .vulkan; break }
    }
    if api == .unknown, let exe {
        // look at what the executable and the SDL/engine libraries next to it link against
        var candidates = [exe.path]
        if let en = fm.enumerator(atPath: url.appendingPathComponent("Contents").path) {
            for case let f as String in en where f.hasSuffix(".dylib") && (f.contains("SDL") || f.contains("GLFW") || f.contains("glfw")) { candidates.append(url.appendingPathComponent("Contents/\(f)").path) }
        }
        for c in candidates {
            let out = shell("/usr/bin/otool", ["-L", c]).output
            if out.contains("OpenGL.framework") || out.contains("Metal.framework") { api = .bridge; break }
        }
    }
    return GameInfo(executable: exe?.path, archs: archs, api: api)
}

/// Fingerprint of a bundle: relative path, size and modification time of every file (a few thousand `stat`s, no file is read). Changes to any file inside
/// the game, not only to Info.plist or the executable, make the signed copy get rebuilt.
func bundleFingerprint(_ bundle: URL) -> String {
    var hasher = SHA256()
    let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
    guard let en = FileManager.default.enumerator(at: bundle, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else { return "v2:" }
    var entries: [String] = []
    for case let url as URL in en {
        guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { continue }
        entries.append("\(url.path.dropFirst(bundle.path.count))|\(v.fileSize ?? 0)|\(v.contentModificationDate?.timeIntervalSince1970 ?? 0)")
    }
    for e in entries.sorted() { hasher.update(data: Data(e.utf8)) }
    return "v2:" + hasher.finalize().map { String(format: "%02x", $0) }.joined()
}

@MainActor
final class Launcher: ObservableObject {
    @Published var phase: [UUID: Phase] = [:]
    @Published var log: [UUID: String] = [:]
    @Published var reshadeLog: [UUID: String] = [:]
    /// What ReShade really hooked in the last start, read from its log (nil: not started yet).
    @Published var observedPath: [UUID: String] = [:]
    private var processes: [UUID: Process] = [:]
    private var gamePIDs: [UUID: pid_t] = [:]   // screen filter mode: the game runs on its own, only the helper is our process
    private var preparing: [UUID: Task<Void, Never>] = [:]   // start in progress (copy being prepared)
    /// True from the click on Start until the game has quit: a second start, removing or moving the copies must wait.
    func isBusy(_ id: UUID) -> Bool { processes[id] != nil || preparing[id] != nil }
    private var timers: [UUID: Timer] = [:]

    func phase(of id: UUID) -> Phase { phase[id] ?? .idle }

    // MARK: copy + sign
    /// Quetoo (and maybe others) replaces its own files when it finds a newer version, which brings back the original hardened signature and loses ReShade. A `.managed`
    /// marker tells its updater that the installation is managed from outside, so it leaves the copy alone.
    nonisolated static func markManaged(_ bundle: URL) {
        for sub in ["Contents/MacOS", "Contents/Resources"] { FileManager.default.createFile(atPath: bundle.appendingPathComponent(sub).appendingPathComponent(".managed").path, contents: Data()) }
    }

    /// True when the bundle's main executable carries an ad-hoc signature without hardened runtime (the state the launcher creates).
    nonisolated static func isAdHocSigned(_ bundle: URL) -> Bool {
        guard let exe = Bundle(url: bundle)?.executableURL else { return false }
        let out = shell("/usr/bin/codesign", ["-dv", exe.path]).output
        return out.contains("Signature=adhoc") && !out.contains("(runtime)")
    }

    /// Creates (or reuses) a re-signed copy of the game without hardened runtime, so the layer can be injected.
    nonisolated static func prepareCopy(_ game: Game, force: Bool, status: @escaping @Sendable (String) -> Void) throws -> URL {
        let fm = FileManager.default
        let src = URL(fileURLWithPath: game.sourcePath)
        // an external drive may not be mounted: do not create "/Volumes/<name>" by accident
        guard fm.fileExists(atPath: Paths.copies.deletingLastPathComponent().path) else { throw PackageError.failed(L("The folder for game copies is not available: %@", Paths.copies.path)) }
        try fm.createDirectory(at: Paths.copies, withIntermediateDirectories: true)
        let dir = Paths.copies.appendingPathComponent(game.id.uuidString)
        let dst = dir.appendingPathComponent(src.lastPathComponent)
        let stampFile = dir.appendingPathComponent("stamp.txt")
        let stamp = bundleFingerprint(src)
        if !force, fm.fileExists(atPath: dst.path), (try? String(contentsOf: stampFile, encoding: .utf8)) == stamp {
            // Some games update themselves in place (Quetoo): that brings back the original, hardened-runtime signature, which blocks injecting ReShade. Sign again when needed.
            if !isAdHocSigned(dst) {
                status(L("Signing the copy (ad-hoc) …"))
                _ = shell("/bin/chmod", ["-R", "u+w", dst.path]); _ = shell("/usr/bin/xattr", ["-cr", dst.path]); markManaged(dst)
                let r = shell("/usr/bin/codesign", ["--force", "--deep", "-s", "-", dst.path])
                guard r.status == 0 else { throw LaunchError.step("codesign", r.output) }
            }
            return dst
        }

        status(L("Copying %@ …", src.lastPathComponent))
        try? fm.removeItem(at: dir); try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var r = shell("/usr/bin/ditto", [src.path, dst.path])
        guard r.status == 0 else { throw LaunchError.step("ditto", r.output) }
        _ = shell("/bin/chmod", ["-R", "u+w", dst.path]) // frameworks of some games are read-only
        _ = shell("/usr/bin/xattr", ["-cr", dst.path])
        markManaged(dst)
        status(L("Signing the copy (ad-hoc) …"))
        r = shell("/usr/bin/codesign", ["--force", "--deep", "-s", "-", dst.path])
        guard r.status == 0 else { throw LaunchError.step("codesign", r.output) }
        try stamp.write(to: stampFile, atomically: true, encoding: .utf8)
        return dst
    }

    // MARK: ReShade instance (per game configuration folder)

    /// Sets `key` in `[section]` of an INI file, creating section/key when needed. Other content (e.g. written by ReShade itself) is kept.
    static func iniSet(_ url: URL, section: String, key: String, value: String, onlyIfMissing: Bool = false) {
        var lines = ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var sectionStart: Int? = nil, sectionEnd = lines.count, keyIndex: Int? = nil
        for (i, line) in lines.enumerated() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") {
                if sectionStart != nil { sectionEnd = i; break }
                if t == "[\(section)]" { sectionStart = i }
            } else if sectionStart != nil, t.hasPrefix(key + "=") { keyIndex = i }
        }
        if let k = keyIndex { if !onlyIfMissing { lines[k] = "\(key)=\(value)" } }
        else if sectionStart != nil { lines.insert("\(key)=\(value)", at: sectionEnd) }
        else { lines.append("[\(section)]"); lines.append("\(key)=\(value)") }
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }

    /// Value of `key` in `[section]` of an INI file (nil when absent).
    static func iniGet(_ url: URL, section: String, key: String) -> String? {
        var inSection = false
        for line in ((try? String(contentsOf: url, encoding: .utf8)) ?? "").components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("[") { inSection = t == "[\(section)]" }
            else if inSection, t.hasPrefix(key + "=") { return String(t.dropFirst(key.count + 1)) }
        }
        return nil
    }

    /// Creates the instance folder and (re)writes the settings the launcher owns. Everything the user changes inside ReShade stays untouched.
    @discardableResult
    static func prepareInstance(_ game: Game) -> URL {
        let fm = FileManager.default
        let dir = Paths.instance(for: game)
        let screenshots = dir.appendingPathComponent("Screenshots")
        for d in [dir, screenshots, dir.appendingPathComponent("cache")] { try? fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let ini = dir.appendingPathComponent("ReShade.ini")
        let collections = Paths.collectionDirs()
        let shaders = collections.map { $0.appendingPathComponent("Shaders").path + "/**" }.joined(separator: ",")
        let textures = collections.filter { fm.fileExists(atPath: $0.appendingPathComponent("Textures").path) }
            .map { $0.appendingPathComponent("Textures").path + "/**" }.joined(separator: ",")
        iniSet(ini, section: "GENERAL", key: "EffectSearchPaths", value: shaders)
        iniSet(ini, section: "GENERAL", key: "TextureSearchPaths", value: textures)
        iniSet(ini, section: "GENERAL", key: "IntermediateCachePath", value: dir.appendingPathComponent("cache").path)
        iniSet(ini, section: "GENERAL", key: "SkipLoadingDisabledEffects", value: "1", onlyIfMissing: true)
        Presets.writeDefault(for: game)
        iniSet(ini, section: "GENERAL", key: "PresetPath", value: Presets.url(Presets.defaultName, for: game).path, onlyIfMissing: true)
        iniSet(ini, section: "SCREENSHOT", key: "SavePath", value: screenshots.path, onlyIfMissing: true)
        iniSet(ini, section: "OVERLAY", key: "ShowFPS", value: "1", onlyIfMissing: true)
        // Shortcuts chosen in the launcher are applied when they change; later changes made inside ReShade stay untouched
        let applied = dir.appendingPathComponent(".keys")
        let wanted = "\(game.overlayKey.iniValue);\(game.screenshotKey.iniValue);\(game.effectsKey.iniValue)"
        if (try? String(contentsOf: applied, encoding: .utf8)) != wanted {
            iniSet(ini, section: "INPUT", key: "KeyOverlay", value: game.overlayKey.iniValue)
            iniSet(ini, section: "INPUT", key: "KeyScreenshot", value: game.screenshotKey.iniValue)
            iniSet(ini, section: "INPUT", key: "KeyEffects", value: game.effectsKey.iniValue)
            try? wanted.write(to: applied, atomically: true, encoding: .utf8)
        }
        // once per instance, for games on the OpenGL/Metal bridge: the depth buffer it supplies is not reversed (ReShade assumes reversed depth by default)
        let depthDefs = dir.appendingPathComponent(".depthdefs")
        if !fm.fileExists(atPath: depthDefs.path) {
            if inspectGame(game.sourcePath).api == .bridge, (iniGet(ini, section: "GENERAL", key: "PreprocessorDefinitions") ?? "").isEmpty {
                iniSet(ini, section: "GENERAL", key: "PreprocessorDefinitions", value: "RESHADE_DEPTH_INPUT_IS_REVERSED=0")
            }
            fm.createFile(atPath: depthDefs.path, contents: Data())
        }
        // the before/after screenshot view was removed again: switch "save before and after images" back off once
        let shots = dir.appendingPathComponent(".shots")
        if fm.fileExists(atPath: shots.path) { iniSet(ini, section: "SCREENSHOT", key: "SaveBeforeShot", value: "0"); try? fm.removeItem(at: shots) }
        return dir
    }

    // MARK: run
    func start(_ game: Game, force: Bool = false) {
        guard !isBusy(game.id) else { return }
        if game.captureMode { startFiltered(game); return }
        guard FileManager.default.fileExists(atPath: Paths.dylib.path) else { phase[game.id] = .failed(L("libmacshade.dylib is missing from the app bundle.")); return }
        phase[game.id] = .preparing(L("Preparing …")); log[game.id] = ""; reshadeLog[game.id] = ""
        let id = game.id
        preparing[id] = Task.detached {
            do {
                let copy = try Launcher.prepareCopy(game, force: force) { msg in Task { @MainActor in if self.preparing[id] != nil { self.phase[id] = .preparing(msg) } } }
                await MainActor.run { if !Task.isCancelled { self.launch(game, copy: copy) } }   // stopped meanwhile: do not start
            } catch { await MainActor.run { if !Task.isCancelled { self.phase[id] = .failed("\(error)") } } }
            await MainActor.run { self.preparing[id] = nil }
        }
    }

    private func launch(_ game: Game, copy: URL) {
        guard let exe = Bundle(url: copy)?.executableURL else { phase[game.id] = .failed(L("No executable found in the app package.")); return }
        let instance = Launcher.prepareInstance(game)
        let logURL = Paths.logs.appendingPathComponent("\(game.id.uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        guard let out = try? FileHandle(forWritingTo: logURL) else { phase[game.id] = .failed(L("Log file is not writable.")); return }

        var arguments = splitArguments(game.arguments)
        if game.suppressRestoreDialog {
            // Quake-style engines (Q3, Quake3e ...) join everything after a "+command" into that command: put the flag in front of the first "+" or it ends up in the last value
            let flag = ["-ApplePersistenceIgnoreState", "YES"]
            if let i = arguments.firstIndex(where: { $0.hasPrefix("+") }) { arguments.insert(contentsOf: flag, at: i) } else { arguments += flag }
        }
        let p = Process(); p.executableURL = exe; p.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["DYLD_INSERT_LIBRARIES"] = Paths.dylib.path
        // prefer the MoltenVK the game ships: the game was built and tested against that version
        let bundle = exe.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let own = FileManager.default.enumerator(atPath: bundle.path)?.compactMap { $0 as? String }.first { $0.hasSuffix("/libMoltenVK.dylib") || $0 == "libMoltenVK.dylib" }
        env["MACSHADE_MOLTENVK"] = own.map { bundle.appendingPathComponent($0).path } ?? Paths.dylib.deletingLastPathComponent().appendingPathComponent("libMoltenVK.dylib").path
        env["MACSHADE_BASE"] = instance.path
        if game.pipeline { env["MACSHADE_PIPELINE"] = "1" }
        if game.fpsLimit > 0 { env["MACSHADE_FPS_LIMIT"] = String(game.fpsLimit) }
        p.environment = env
        p.standardOutput = out; p.standardError = out
        let id = game.id, started = Date()
        p.terminationHandler = { proc in
            Task { @MainActor in
                self.timers[id]?.invalidate(); self.timers[id] = nil; self.processes[id] = nil
                self.readLog(id, logURL)
                let stoppedByUs = proc.terminationReason == .exit && proc.terminationStatus == 15
                if !stoppedByUs, Date().timeIntervalSince(started) < 10 {   // gone within seconds: typical for games that insist on their own launcher (Steam, EA app, …)
                    self.phase[id] = .failed(L("The game quit within seconds (status %d). Some games only run through their own launcher (Steam, EA app …) and refuse a copy.", Int(proc.terminationStatus)))
                    return
                }
                self.phase[id] = proc.terminationStatus == 0 || stoppedByUs ? .idle
                    : .failed(L("Exited (status %d). See the log.", Int(proc.terminationStatus)))
            }
        }
        try? FileManager.default.removeItem(at: Paths.instances.appendingPathComponent(id.uuidString).appendingPathComponent("ReShade.log"))   // a failed injection must not show the previous start's path
        observedPath[id] = nil; reshadeLog[id] = nil
        do { try p.run() } catch { phase[id] = .failed(L("Launch failed: %@", error.localizedDescription)); return }
        processes[id] = p; phase[id] = .running
        timers[id] = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in Task { @MainActor in self.readLog(id, logURL) } }
    }

    // MARK: screen filter mode
    /// Starts the game normally (no copy, no injection) and the helper that filters its window.
    private func startFiltered(_ game: Game) {
        let id = game.id
        guard let helper = Bundle.main.url(forAuxiliaryExecutable: "MacShadeFilter"), FileManager.default.fileExists(atPath: Paths.dylib.path) else { phase[id] = .failed(L("The screen filter helper is missing from the app bundle.")); return }
        // without the Screen Recording permission nothing works: ask now and do not start the game unfiltered
        if !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess(); phase[id] = .failed(L("Screen filter mode needs permission: allow MacShade under System Settings > Privacy & Security > Screen & System Audio Recording, then start again.")); return }
        phase[id] = .preparing(L("Starting the game …")); log[id] = ""; reshadeLog[id] = ""
        let instance = Launcher.prepareInstance(game)
        let logURL = Paths.logs.appendingPathComponent("\(id.uuidString).log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        try? FileManager.default.removeItem(at: instance.appendingPathComponent("ReShade.log")); observedPath[id] = nil
        let appURL = URL(fileURLWithPath: game.sourcePath)
        let begin: (pid_t) -> Void = { pid in self.runHelper(game, helper: helper, pid: pid, instance: instance, logURL: logURL) }
        if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleURL?.standardizedFileURL == appURL.standardizedFileURL && !$0.isTerminated }) { begin(running.processIdentifier); return }
        var arguments = splitArguments(game.arguments)
        if game.suppressRestoreDialog { arguments += ["-ApplePersistenceIgnoreState", "YES"] }
        let config = NSWorkspace.OpenConfiguration(); config.arguments = arguments; config.activates = true
        NSWorkspace.shared.openApplication(at: appURL, configuration: config) { app, error in
            Task { @MainActor in
                if let app { begin(app.processIdentifier) } else { self.phase[id] = .failed(L("Launch failed: %@", error?.localizedDescription ?? "?")) }
            }
        }
    }

    private func runHelper(_ game: Game, helper: URL, pid: pid_t, instance: URL, logURL: URL) {
        let id = game.id
        func mac(_ k: KeyBinding) -> String {
            let code = KeyNames.macToVK.filter { $0.value == k.vk }.keys.min() ?? 0xFFFF
            return "\(code == 0xFFFF ? -1 : Int(code)):\((k.ctrl ? 1 : 0) | (k.shift ? 2 : 0) | (k.alt ? 4 : 0))"
        }
        guard let out = try? FileHandle(forWritingTo: logURL) else { phase[id] = .failed(L("Log file is not writable.")); return }
        let p = Process(); p.executableURL = helper
        p.arguments = ["--pid", String(pid), "--overlay", mac(game.overlayKey), "--effects", mac(game.effectsKey)] + (game.captureHalfResolution ? ["--scale", "0.5"] : [])
        var env = ProcessInfo.processInfo.environment
        env["MACSHADE_LIB"] = Paths.dylib.path
        env["MACSHADE_MOLTENVK"] = Paths.dylib.deletingLastPathComponent().appendingPathComponent("libMoltenVK.dylib").path
        env["MACSHADE_BASE"] = instance.path
        if game.fpsLimit > 0 { env["MACSHADE_FPS_LIMIT"] = String(game.fpsLimit) }
        p.environment = env; p.standardOutput = out; p.standardError = out
        p.terminationHandler = { proc in
            Task { @MainActor in
                self.timers[id]?.invalidate(); self.timers[id] = nil; self.processes[id] = nil; self.gamePIDs[id] = nil
                self.readLog(id, logURL)
                if proc.terminationStatus == 3 { self.phase[id] = .failed(L("Screen filter mode needs permission: allow MacShade under System Settings > Privacy & Security > Screen & System Audio Recording, then start again.")); return }
                self.phase[id] = proc.terminationReason == .exit && (proc.terminationStatus == 0 || proc.terminationStatus == 15) ? .idle : .failed(L("Exited (status %d). See the log.", Int(proc.terminationStatus)))
            }
        }
        do { try p.run() } catch { phase[id] = .failed(L("Launch failed: %@", error.localizedDescription)); return }
        processes[id] = p; gamePIDs[id] = pid; phase[id] = .running
        timers[id] = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in Task { @MainActor in self.readLog(id, logURL) } }
    }

    private func readLog(_ id: UUID, _ url: URL) {
        if let data = try? Data(contentsOf: url) {
            let text = String(decoding: data.suffix(24_000), as: UTF8.self)
            if log[id] != text { log[id] = text }
        }
        let reshade = Paths.instances.appendingPathComponent(id.uuidString).appendingPathComponent("ReShade.log")
        if let data = try? Data(contentsOf: reshade) {
            let text = String(decoding: data.suffix(24_000), as: UTF8.self)
            if reshadeLog[id] != text { reshadeLog[id] = text }
            let full = String(decoding: data, as: UTF8.self)
            let seen: String? = full.contains("Initializing ReShade")
                ? (full.contains("Screen filter: processing") ? L("Screen filter") : full.contains("Bridge: pipelined processing") || full.contains("Bridge: processing") ? L("OpenGL/Metal bridge")
                    : full.contains("Running on") ? L("Vulkan (direct)") : L("ReShade loaded, but no graphics path was hooked")) : nil
            if observedPath[id] != seen { observedPath[id] = seen }
        }
    }

    func stop(_ game: Game) {
        if let t = preparing[game.id] { t.cancel(); phase[game.id] = .idle }   // ponytail: the copy step itself finishes, only the launch is skipped
        processes[game.id]?.terminate()
        if let pid = gamePIDs[game.id] { NSRunningApplication(processIdentifier: pid)?.terminate() }   // screen filter mode: the game is a separate process
    }
}

enum LaunchError: Error, CustomStringConvertible {
    case step(String, String)
    var description: String { switch self { case .step(let s, let o): return L("%@ failed: %@", s, o) } }
}
