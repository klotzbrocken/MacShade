import SwiftUI

/// An app that looks like a game and is not in the list yet.
struct GameCandidate: Identifiable, Hashable {
    var id: String { path }
    var name: String
    var path: String
    var info: GameInfo
    var supported: Bool { info.archs.contains("arm64") && info.api != .staticVulkan }
    static func == (a: GameCandidate, b: GameCandidate) -> Bool { a.path == b.path }
    func hash(into h: inout Hasher) { h.combine(path) }
}

enum GameDiscovery {
    /// Names of engines and games that are known to work with (or are likely candidates for) MacShade.
    static let knownNames = ["quake", "doom", "unreal", "quetoo", "openarena", "xonotic", "tremulous", "sauerbraten", "cube", "duke", "eduke", "raze", "heretic", "hexen",
                             "wolfenstein", "wolf3d", "ecwolf", "etlegacy", "darkplaces", "xash", "supertux", "luanti", "minetest", "openttd", "freeciv", "0 a.d", "warzone", "ioquake", "yamagi", "ut2004", "urbanterror"]

    static func defaultFolders() -> [URL] {
        let fm = FileManager.default
        var folders = [URL(fileURLWithPath: "/Applications"), fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        for volume in (try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [] {   // external drives, e.g. "/Volumes/Daten/Games"
            let games = URL(fileURLWithPath: "/Volumes/\(volume)/Games")
            if fm.fileExists(atPath: games.path) { folders.append(games) }
        }
        folders += steamLibraries()
        return folders
    }

    /// Steam game folders (`<library>/steamapps/common`) from Steam's own list of libraries.
    static func steamLibraries() -> [URL] {
        let fm = FileManager.default
        let steam = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Steam")
        var roots = [steam.path]
        if let text = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8) {
            for line in text.split(whereSeparator: \.isNewline) where line.contains("\"path\"") {   // "path"		"/Volumes/Games/SteamLibrary"
                let parts = line.split(separator: "\"").map(String.init)
                if let i = parts.firstIndex(of: "path"), parts.count > i + 2 { roots.append(parts[i + 2]) }
            }
        }
        return Set(roots).map { URL(fileURLWithPath: $0).appendingPathComponent("steamapps/common") }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// Looks for .app bundles up to two levels deep that are tagged as games or have a well-known name.
    nonisolated static func scan(_ folders: [URL], excluding known: Set<String>) -> [GameCandidate] {
        let fm = FileManager.default
        var found: [GameCandidate] = []
        var seen = Set<String>()
        for folder in folders {
            guard let en = fm.enumerator(at: folder, includingPropertiesForKeys: nil, options: [.skipsPackageDescendants, .skipsHiddenFiles]) else { continue }
            for case let url as URL in en {
                if url.pathComponents.count - folder.pathComponents.count > 3 { en.skipDescendants(); continue }
                guard url.pathExtension == "app", !known.contains(url.path), seen.insert(url.path).inserted else { continue }
                let name = url.deletingPathExtension().lastPathComponent
                let plist = NSDictionary(contentsOf: url.appendingPathComponent("Contents/Info.plist"))
                let category = (plist?["LSApplicationCategoryType"] as? String)?.lowercased() ?? ""
                let lower = name.lowercased()
                guard category.contains("games") || knownNames.contains(where: { lower.contains($0) }) else { continue }
                found.append(GameCandidate(name: name, path: url.path, info: inspectGame(url.path)))
            }
        }
        return found.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

struct DiscoverView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) private var dismiss
    var onAdded: (UUID?) -> Void
    @State private var candidates: [GameCandidate] = []
    @State private var chosen = Set<String>()
    @State private var scanning = true
    @State private var extraFolders: [URL] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text("Find games").font(.title2.bold()); Spacer(); Button("Cancel") { dismiss() } }
            Text("Apps in /Applications, ~/Applications and “Games” folders on external drives that look like games. Choose the ones to add.").font(.callout).foregroundStyle(.secondary)
            GroupBox {
                if scanning { HStack { ProgressView().controlSize(.small); Text("Searching …") }.padding() }
                else if candidates.isEmpty { Text("No new games found. You can add a game with “+” or by dropping its .app here.").padding() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(candidates) { c in
                                HStack(alignment: .top) {
                                    Toggle("", isOn: Binding(get: { chosen.contains(c.id) }, set: { if $0 { chosen.insert(c.id) } else { chosen.remove(c.id) } })).labelsHidden().disabled(!c.supported)
                                    Image(nsImage: gameIcon(c.path)).resizable().frame(width: 32, height: 32)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(c.name).font(.headline)
                                        Text(c.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                        Text(c.supported ? c.info.api.label : (c.info.api == .staticVulkan ? c.info.api.label : c.info.archs == "?" ? L("Cannot read the program (a launcher script?) – ReShade cannot be loaded.") : L("No arm64 version – ReShade cannot be loaded."))).font(.caption).foregroundStyle(c.supported ? Color.secondary : Color.orange)
                                    }
                                    Spacer()
                                }
                            }
                        }.padding(8)
                    }.frame(minHeight: 240)
                }
            }
            HStack {
                Button("Search another folder …") { pickFolder() }
                Spacer()
                Button("Add selected") {
                    var last: UUID?
                    for c in candidates where chosen.contains(c.id) { last = store.add(appURL: URL(fileURLWithPath: c.path)) ?? last }
                    onAdded(last); dismiss()
                }.buttonStyle(.borderedProminent).disabled(chosen.isEmpty)
            }
        }
        .padding(20).frame(width: 640, height: 520)
        .task { await scan() }
    }

    private func scan() async {
        scanning = true
        let folders = GameDiscovery.defaultFolders() + extraFolders, known = Set(store.games.map(\.sourcePath))
        let result = await Task.detached { GameDiscovery.scan(folders, excluding: known) }.value
        candidates = result; chosen = Set(result.filter { $0.supported && $0.info.api != .unknown }.map(\.id))   // only games whose graphics API was recognised are preselected; scanning = false
    }

    private func pickFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.message = L("Choose a folder to search for games")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        extraFolders.append(url); Task { await scan() }
    }
}
