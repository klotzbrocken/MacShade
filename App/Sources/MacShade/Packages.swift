import Foundation

/// An effect package as listed in ReShade's own installer (EffectPackages.ini of the reshade-shaders "list" branch).
struct EffectPackage: Identifiable, Hashable {
    var id: String { name }
    var name: String
    var summary: String
    var downloadURL: URL
    var repositoryURL: URL?
}

enum PackageError: Error, CustomStringConvertible {
    case failed(String)
    var description: String { if case .failed(let m) = self { return m }; return "" }
}

enum PackageManager {
    static let listURL = URL(string: "https://raw.githubusercontent.com/crosire/reshade-shaders/list/EffectPackages.ini")!

    /// Folder name of an installed package inside `Collections/`.
    static func folderName(_ name: String) -> String {
        let bad = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let n = name.components(separatedBy: bad).joined(separator: "-").trimmingCharacters(in: .whitespaces)
        return n.allSatisfy({ $0 == "." }) ? "package" : n   // "", "." and ".." must never become a path
    }
    static func isInstalled(_ p: EffectPackage) -> Bool {
        FileManager.default.fileExists(atPath: Paths.collections.appendingPathComponent(folderName(p.name)).path)
    }

    /// Downloads and parses the same package list the ReShade installer offers.
    static func fetchList() async throws -> [EffectPackage] {
        let (data, response) = try await URLSession.shared.data(from: listURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let text = String(data: data, encoding: .utf8) else { throw PackageError.failed(L("Could not fetch the package list.")) }
        var packages: [EffectPackage] = [], current: [String: String] = [:]
        func flush() {
            if let n = current["PackageName"], let d = current["DownloadUrl"], let u = URL(string: d) {
                packages.append(EffectPackage(name: n, summary: current["PackageDescription"] ?? "", downloadURL: u, repositoryURL: current["RepositoryUrl"].flatMap(URL.init)))
            }
            current = [:]
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { flush(); continue }
            if let eq = line.firstIndex(of: "=") { current[String(line[..<eq])] = String(line[line.index(after: eq)...]) }
        }
        flush()
        return packages
    }

    /// Downloads a zip (or takes a local file/folder) and installs it as a collection with `Shaders` and `Textures` folders.
    static func install(name: String, from source: URL) async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("macshade-\(UUID().uuidString)")
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }

        var root = work.appendingPathComponent("content")
        if source.isFileURL {
            var isDir: ObjCBool = false
            fm.fileExists(atPath: source.path, isDirectory: &isDir)
            if isDir.boolValue { try fm.copyItem(at: source, to: root) } else { try unzip(source, to: root) }
        } else {
            var head = URLRequest(url: source); head.httpMethod = "HEAD"   // refuse a huge archive before downloading it (if the server tells the size)
            if let (_, r) = try? await URLSession.shared.data(for: head), r.expectedContentLength > maxPacked { throw PackageError.failed(L("The archive is too large.")) }
            let (tmp, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw PackageError.failed(L("Download failed (%d).", (response as? HTTPURLResponse)?.statusCode ?? 0)) }
            let zip = work.appendingPathComponent("package.zip")
            try fm.moveItem(at: tmp, to: zip)
            try unzip(zip, to: root)
        }
        // GitHub archives contain a single top-level folder
        let items = try fm.contentsOfDirectory(atPath: root.path).filter { !$0.hasPrefix(".") && !$0.hasPrefix("__MACOSX") }
        if items.count == 1, (try? root.appendingPathComponent(items[0]).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { root = root.appendingPathComponent(items[0]) }

        // Build the new collection next to the old one and swap it in only when it is complete and contains effects: a bad archive must not destroy what is installed
        let target = Paths.collections.appendingPathComponent(folderName(name))
        let staged = Paths.collections.appendingPathComponent(".\(folderName(name)).staging-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: staged) }
        try fm.createDirectory(at: staged, withIntermediateDirectories: true)
        let shaders = findDirectory("Shaders", in: root), textures = findDirectory("Textures", in: root)
        try fm.copyItem(at: shaders ?? root, to: staged.appendingPathComponent("Shaders"))      // without a "Shaders" folder: loose .fx files
        if let textures { try fm.copyItem(at: textures, to: staged.appendingPathComponent("Textures")) }
        guard containsEffects(staged.appendingPathComponent("Shaders")) else { throw PackageError.failed(L("The package contains no effects (.fx files).")) }
        if fm.fileExists(atPath: target.path) { _ = try fm.replaceItemAt(target, withItemAt: staged) } else { try fm.moveItem(at: staged, to: target) }
    }

    private static func containsEffects(_ dir: URL) -> Bool {
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return false }
        for case let f as URL in en where f.pathExtension.lowercased() == "fx" { return true }
        return false
    }

    /// Archives larger than this (packed 300 MB / unpacked 1.5 GB) are refused: effect packages are a few MB.
    private static let maxPacked: Int64 = 300 << 20, maxUnpacked: Int64 = 1500 << 20

    private static func unzip(_ zip: URL, to dir: URL) throws {
        let packed = ((try? FileManager.default.attributesOfItem(atPath: zip.path)[.size]) as? NSNumber)?.int64Value ?? 0
        let listing = shell("/usr/bin/unzip", ["-l", zip.path]).output.split(separator: "\n").last.map(String.init) ?? ""   // "  12345  678 files"
        let unpacked = Int64(listing.split(separator: " ").first ?? "") ?? 0
        guard packed <= maxPacked, unpacked <= maxUnpacked else { throw PackageError.failed(L("The archive is too large.")) }
        let r = shell("/usr/bin/unzip", ["-q", "-o", zip.path, "-d", dir.path])
        guard r.status == 0 else { throw PackageError.failed(L("Unzipping failed: %@", r.output)) }
    }

    /// First directory named `name` (case-insensitive) within two levels of `root`.
    private static func findDirectory(_ name: String, in root: URL) -> URL? {
        let fm = FileManager.default
        for depth in 0..<2 {
            var level = [root]
            for _ in 0..<depth { level = level.flatMap { (try? fm.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [] } }
            for dir in level { if let hit = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).first(where: { $0.lastPathComponent.lowercased() == name.lowercased() && (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }) { return hit } }
        }
        return nil
    }

    /// Imports a preset file into a game's instance and makes it the active preset.
    @MainActor static func importPreset(_ file: URL, for game: Game) throws {
        let dir = Paths.instance(for: game)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var target = dir.appendingPathComponent(file.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) && target.path != file.path {
            target = dir.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(4)) + ".ini")
        }
        if target.path != file.path { try FileManager.default.copyItem(at: file, to: target) }
        Presets.activate(target.lastPathComponent, for: game)
    }
}
