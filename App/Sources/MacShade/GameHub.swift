import SwiftUI

/// The 25 ports the Game Hub offers. Only the port (engine) is downloaded, never game data.
struct HubPort: Identifiable {
    enum Status { case tested, likely, untested }
    let id: String
    let game: String, port: String, note: String
    let page: String                       // official project or MacSourcePorts page
    var repo: String? = nil                // GitHub "owner/name": offers a direct download of the latest macOS release
    var asset: [String] = []               // substrings (lowercase) the release asset name must contain
    var status: Status = .untested
    var keys: [String] = []                // names that identify an installed copy ("=" prefix: exact match)
}

enum HubCatalog {
    private static let msp = "https://www.macsourceports.com"
    static let ports: [HubPort] = all.filter { $0.repo != nil }   // only ports that can be downloaded from here
    private static let all: [HubPort] = [
        .init(id: "quake", game: "Quake", port: "vkQuake", note: "Vulkan engine, best Quake path for MacShade", page: "https://github.com/Novum/vkQuake/releases", status: .tested),
        .init(id: "quake2", game: "Quake II", port: "Yamagi Quake II", note: "Use the Vulkan renderer (ref_vk) for ReShade", page: "\(msp)/game/quake2", status: .tested),
        .init(id: "quake3", game: "Quake III Arena", port: "Quake3e", note: "Zip with executables; wrap or run it yourself", page: "\(msp)/game/quake3arena", repo: "ec-/Quake3e", asset: ["macos-aarch64"], status: .tested, keys: ["quake3e","quake iii","quake3"]),
        .init(id: "ut99", game: "Unreal Tournament 99", port: "OldUnreal patch 469", note: "Official OldUnreal macOS patch", page: "\(msp)/sourceport/unrealtournament", repo: "OldUnreal/UnrealTournamentPatches", asset: ["macos.dmg"], status: .tested, keys: ["ut99","unreal tournament 99","unrealtournament"]),
        .init(id: "ut2004", game: "Unreal Tournament 2004", port: "OldUnreal patch", note: "Official OldUnreal macOS patch", page: "\(msp)/game/unrealtournament2004", repo: "OldUnreal/UT2004Patches", asset: ["macos.dmg"], status: .tested, keys: ["ut2004","unreal tournament 2004"]),
        .init(id: "doom", game: "Doom / Doom II", port: "UZDoom", note: "Apple Silicon build", page: "\(msp)/game/doom", repo: "UZDoom/UZDoom", asset: ["arm64.dmg"], status: .tested, keys: ["uzdoom","gzdoom","doom"]),
        .init(id: "quetoo", game: "Quetoo", port: "Quetoo", note: "Free arena shooter with its own data", page: "\(msp)/game/quetoo", status: .tested),
        .init(id: "unreal", game: "Unreal", port: "OldUnreal patch 227", note: "Same engine family as UT99", page: "\(msp)/game/unreal", repo: "OldUnreal/Unreal-testing", asset: ["macos.dmg"], status: .likely, keys: ["=unreal","unreal gold"]),
        .init(id: "halflife", game: "Half-Life", port: "Xash3D FWGS", note: "Small engine, simple graphics path", page: "\(msp)/game/halflife"),
        .init(id: "serioussam", game: "Serious Sam TFE / TSE", port: "Serious Engine", note: "Classic Serious Sam", page: "\(msp)/game/serioussamfe"),
        .init(id: "prey", game: "Prey (2006)", port: "Prey 2006 port", note: "Doom 3 engine based", page: "\(msp)/game/prey"),
        .init(id: "et", game: "Wolfenstein: Enemy Territory", port: "ET: Legacy", note: "Free multiplayer shooter", page: "\(msp)/game/wolfet"),
        .init(id: "mohaa", game: "Medal of Honor: Allied Assault", port: "OpenMoHAA", note: "Universal build", page: "\(msp)/game/mohaa", repo: "openmoh/openmohaa", asset: ["macos-multiarch"], keys: ["openmohaa","allied assault"]),
        .init(id: "duke3d", game: "Duke Nukem 3D", port: "EDuke32", note: "Build engine port", page: "\(msp)/game/duke3d"),
        .init(id: "morrowind", game: "Morrowind", port: "OpenMW", note: "Apple Silicon build", page: "\(msp)/game/morrowind", repo: "OpenMW/openmw", asset: ["macos-arm64.dmg"], keys: ["openmw","morrowind"]),
        .init(id: "gothic2", game: "Gothic II", port: "OpenGothic", note: "Vulkan based", page: "\(msp)/game/gothic2"),
        .init(id: "warzone", game: "Warzone 2100", port: "Warzone 2100", note: "Free game, data included (1.1 GB; a build without videos exists on the project page)", page: "https://github.com/Warzone2100/warzone2100/releases", repo: "Warzone2100/warzone2100", asset: ["macos_universal.zip"], keys: ["warzone"]),
        .init(id: "selaco", game: "Selaco", port: "GZSelaco", note: "Commercial game, port ships with it", page: "\(msp)/game/selaco"),
        .init(id: "revolt", game: "Re-Volt", port: "RVGL", note: "Racing, lots of reflections", page: "https://rvgl.org"),
        .init(id: "heretic2", game: "Heretic II", port: "Heretic2R", note: "Quake II engine roots", page: "\(msp)/game/heretic2"),
        .init(id: "arx", game: "Arx Fatalis", port: "Arx Libertatis", note: "Dark RPG", page: "\(msp)/game/arxfatalis"),
        .init(id: "avp", game: "Aliens versus Predator", port: "NakedAVP", note: "Classic 3D shooter", page: "\(msp)/game/avp"),
        .init(id: "jkdf2", game: "Jedi Knight / Dark Forces II", port: "OpenJKDF2", note: "OpenGL output", page: "\(msp)/game/swjkdf2"),
        .init(id: "oni", game: "Oni", port: "OniARM64", note: "Apple Silicon only", page: "\(msp)/game/oni"),
        .init(id: "freespace2", game: "FreeSpace 2", port: "FS2 Open", note: "Apple Silicon build, has its own post effects", page: "\(msp)/game/freespace2", repo: "scp-fs2open/fs2open.github.com", asset: ["mac-arm64"], keys: ["freespace","fs2"]),
    ]
}

/// Download state for one port's direct install.
struct HubOffer: Identifiable {
    let id = UUID()
    let port: HubPort, name: String, size: Int, url: URL
}

@MainActor final class HubInstaller: ObservableObject {
    @Published var offer: HubOffer?
    @Published var busy: String?           // port id being looked up or downloaded
    @Published var message: String?

    static var folder: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/MacShade Ports") }

    /// Looks up the latest release; the user confirms the file before anything is downloaded.
    func prepare(_ p: HubPort) async {
        guard let repo = p.repo, let api = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=1") else { return }
        busy = p.id; defer { busy = nil }
        do {
            var req = URLRequest(url: api); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Rel: Decodable { struct A: Decodable { let name: String; let size: Int; let browser_download_url: URL }; let assets: [A] }
            guard let a = try JSONDecoder().decode([Rel].self, from: data).first?.assets.first(where: { a in p.asset.allSatisfy { a.name.lowercased().contains($0) } })
            else { message = L("No matching macOS download found. Opening the project page."); NSWorkspace.shared.open(URL(string: p.page)!); return }
            offer = HubOffer(port: p, name: a.name, size: a.size, url: a.browser_download_url)
        } catch { message = L("Lookup failed: ") + error.localizedDescription }
    }

    func download(_ o: HubOffer) async {
        busy = o.port.id; defer { busy = nil }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            let (tmp, _) = try await URLSession.shared.download(from: o.url)
            let dest = Self.folder.appendingPathComponent(o.name)
            try? fm.removeItem(at: dest); try fm.moveItem(at: tmp, to: dest)
            if o.name.hasSuffix(".zip") {   // unpack next to the archive and show the result
                let out = Self.folder.appendingPathComponent(dest.deletingPathExtension().lastPathComponent)
                try? fm.removeItem(at: out)
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); t.arguments = ["-xk", dest.path, out.path]; try t.run(); t.waitUntilExit()
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } else if o.name.hasSuffix(".dmg") { NSWorkspace.shared.open(dest) }   // mounts it: drag the app to Applications
            else { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            message = L("Downloaded to ") + Self.folder.path
        } catch { message = L("Download failed: ") + error.localizedDescription }
    }
}

struct GameHubView: View {
    @EnvironmentObject var store: Store
    var addGame: () -> Void
    @State private var apps: [String] = []

    private func norm(_ s: String) -> String { s.lowercased().replacingOccurrences(of: ".app", with: "") }
    private func hit(_ p: HubPort, _ names: [String]) -> Bool {
        names.contains { n in let n = norm(n); return p.keys.contains { $0.hasPrefix("=") ? n == String($0.dropFirst()) : n.contains($0) } }
    }
    private func inList(_ p: HubPort) -> Bool { hit(p, store.games.map(\.name)) }
    private func onDisk(_ p: HubPort) -> Bool { hit(p, apps) }
    private func scanApps() {
        let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser.path
        apps = ["/Applications", home + "/Applications", HubInstaller.folder.path].flatMap { d in
            ((try? fm.contentsOfDirectory(atPath: d)) ?? []).filter { $0.hasSuffix(".app") } + ((try? fm.contentsOfDirectory(atPath: d + "/Games")) ?? []).filter { $0.hasSuffix(".app") }
        }
    }
    @StateObject private var installer = HubInstaller()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle("Game Hub", "Source ports that work well with MacShade and can be downloaded here. Only the port is downloaded. You need your own copy of the game and its data.")
                if let m = installer.message { Text(m).font(.callout).foregroundStyle(Theme.muted) }
                ForEach(HubCatalog.ports) { p in
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.game).font(.system(size: 16, weight: .heavy))
                                Text(p.port).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                Text(LocalizedStringKey(p.note)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                HStack(spacing: 6) {
                                    Pill(text: label(p.status), color: p.status == .tested ? Theme.good : p.status == .likely ? Theme.warn : Theme.muted)
                                    if inList(p) { Pill(text: L("In MacShade"), color: Theme.accent) } else if onDisk(p) { Pill(text: L("Installed"), color: Theme.accent) }
                                }
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 8) {
                                if !inList(p) && !onDisk(p) {
                                    Button { Task { await installer.prepare(p) } } label: {
                                        if installer.busy == p.id { ProgressView().controlSize(.small) } else { Label("Download", systemImage: "arrow.down.circle") }
                                    }.buttonStyle(SoftButton(tint: Theme.accent)).disabled(installer.busy != nil)
                                }
                                Button { NSWorkspace.shared.open(URL(string: p.page)!) } label: { Label("Project page", systemImage: "safari") }.buttonStyle(SoftButton())
                            }
                        }
                    }
                }
                Text("Installed ports appear here too: add them to MacShade with Add game.").font(.callout).foregroundStyle(Theme.muted)
                Button { addGame() } label: { Label("Add game", systemImage: "plus") }.buttonStyle(SoftButton())
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }
        .onAppear(perform: scanApps).onChange(of: installer.busy) { _ in scanApps() }
        .alert(item: $installer.offer) { o in
            Alert(title: Text(L("Download this file?")),
                  message: Text("\(o.name)\n\(ByteCountFormatter.string(fromByteCount: Int64(o.size), countStyle: .file))\n\(o.url.host ?? "")"),
                  primaryButton: .default(Text(L("Download"))) { Task { await installer.download(o) } }, secondaryButton: .cancel())
        }
    }

    private func label(_ s: HubPort.Status) -> String { s == .tested ? L("Tested") : s == .likely ? L("Probably works") : L("Not tested") }
}
