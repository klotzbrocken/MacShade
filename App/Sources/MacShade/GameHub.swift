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
}

enum HubCatalog {
    static let ports: [HubPort] = [
        .init(id: "quake", game: "Quake", port: "vkQuake", note: "Vulkan engine, best Quake path for MacShade", page: "https://github.com/Novum/vkQuake", status: .tested),
        .init(id: "quake2", game: "Quake II", port: "Yamagi Quake II", note: "Use the Vulkan renderer (ref_vk) for ReShade; build from source", page: "https://github.com/yquake2/yquake2", status: .tested),
        .init(id: "quake3", game: "Quake III Arena", port: "Quake3e", note: "Zip with executables; wrap or run it yourself", page: "https://github.com/ec-/Quake3e", repo: "ec-/Quake3e", asset: ["macos-aarch64"], status: .tested),
        .init(id: "ut99", game: "Unreal Tournament 99", port: "OldUnreal patch 469", note: "Official OldUnreal macOS patch", page: "https://github.com/OldUnreal/UnrealTournamentPatches", repo: "OldUnreal/UnrealTournamentPatches", asset: ["macos.dmg"], status: .tested),
        .init(id: "ut2004", game: "Unreal Tournament 2004", port: "OldUnreal patch", note: "Official OldUnreal macOS patch", page: "https://github.com/OldUnreal/UT2004Patches", repo: "OldUnreal/UT2004Patches", asset: ["macos.dmg"], status: .tested),
        .init(id: "doom", game: "Doom / Doom II", port: "UZDoom", note: "Apple Silicon build", page: "https://github.com/UZDoom/UZDoom", repo: "UZDoom/UZDoom", asset: ["arm64.dmg"], status: .tested),
        .init(id: "quetoo", game: "Quetoo", port: "Quetoo", note: "Free arena shooter with its own data", page: "https://github.com/jdolan/quetoo", repo: "jdolan/quetoo", asset: ["arm64-apple-darwin.dmg"], status: .tested),
        .init(id: "unreal", game: "Unreal", port: "OldUnreal patch 227", note: "Same engine family as UT99", page: "https://github.com/OldUnreal/Unreal-testing", repo: "OldUnreal/Unreal-testing", asset: ["macos.dmg"], status: .likely),
        .init(id: "halflife", game: "Half-Life", port: "Xash3D FWGS", note: "Small engine, simple graphics path (development build)", page: "https://github.com/FWGS/xash3d-fwgs", repo: "FWGS/xash3d-fwgs", asset: ["apple-arm64"]),
        .init(id: "serioussam", game: "Serious Sam TFE / TSE", port: "Serious Engine", note: "Classic Serious Sam; build from source", page: "https://github.com/ptitSeb/Serious-Engine"),
        .init(id: "prey", game: "Prey (2006)", port: "Prey2006", note: "Doom 3 engine based; build from source", page: "https://github.com/FriskTheFallenHuman/Prey2006"),
        .init(id: "et", game: "Wolfenstein: Enemy Territory", port: "ET: Legacy", note: "Free multiplayer shooter", page: "https://github.com/etlegacy/etlegacy"),
        .init(id: "mohaa", game: "Medal of Honor: Allied Assault", port: "OpenMoHAA", note: "Universal build", page: "https://github.com/openmoh/openmohaa", repo: "openmoh/openmohaa", asset: ["macos-multiarch"]),
        .init(id: "duke3d", game: "Duke Nukem 3D", port: "Raze", note: "Build engine games, GZDoom based", page: "https://github.com/ZDoom/Raze", repo: "ZDoom/Raze", asset: ["macos", "zip"]),
        .init(id: "morrowind", game: "Morrowind", port: "OpenMW", note: "Apple Silicon build", page: "https://github.com/OpenMW/openmw", repo: "OpenMW/openmw", asset: ["macos-arm64.dmg"]),
        .init(id: "gothic2", game: "Gothic II", port: "OpenGothic", note: "Vulkan based (pre-release build)", page: "https://github.com/Try/OpenGothic", repo: "Try/OpenGothic", asset: ["osx_arm64"]),
        .init(id: "warzone", game: "Warzone 2100", port: "Warzone 2100", note: "Free game, data included (1.1 GB)", page: "https://github.com/Warzone2100/warzone2100", repo: "Warzone2100/warzone2100", asset: ["macos_universal.zip"]),
        .init(id: "selaco", game: "Selaco", port: "GZSelaco", note: "Commercial game; see macsourceports.com", page: "https://www.macsourceports.com/game/selaco"),
        .init(id: "revolt", game: "Re-Volt", port: "RVGL", note: "Racing, lots of reflections; see rvgl.org", page: "https://rvgl.org"),
        .init(id: "heretic2", game: "Heretic II", port: "Heretic2R", note: "Quake II engine roots", page: "https://github.com/m-x-d/Heretic2R", repo: "m-x-d/Heretic2R", asset: ["heretic2r_"]),
        .init(id: "arx", game: "Arx Fatalis", port: "Arx Libertatis", note: "Dark RPG; build from source", page: "https://github.com/arx/ArxLibertatis"),
        .init(id: "avp", game: "Aliens versus Predator", port: "NakedAVP", note: "Classic 3D shooter; build from source", page: "https://github.com/atsb/NakedAVP"),
        .init(id: "jkdf2", game: "Jedi Knight / Dark Forces II", port: "OpenJKDF2", note: "OpenGL output (debug build)", page: "https://github.com/shinyquagsire23/OpenJKDF2", repo: "shinyquagsire23/OpenJKDF2", asset: ["macos-debug"]),
        .init(id: "oni", game: "Oni", port: "OniARM64", note: "Apple Silicon only", page: "https://github.com/andiyar/OniARM64", repo: "andiyar/OniARM64", asset: ["dmg"]),
        .init(id: "freespace2", game: "FreeSpace 2", port: "FS2 Open", note: "Apple Silicon build, has its own post effects", page: "https://github.com/scp-fs2open/fs2open.github.com", repo: "scp-fs2open/fs2open.github.com", asset: ["mac-arm64"]),
        .init(id: "openrct2", game: "RollerCoaster Tycoon 2", port: "OpenRCT2", note: "Management game, needs RCT2 data", page: "https://github.com/OpenRCT2/OpenRCT2", repo: "OpenRCT2/OpenRCT2", asset: ["macos-universal"]),
        .init(id: "openra", game: "Red Alert / C&C", port: "OpenRA", note: "Free real-time strategy, includes free game content", page: "https://github.com/OpenRA/OpenRA", repo: "OpenRA/OpenRA", asset: ["release", "dmg"]),
        .init(id: "stk", game: "SuperTuxKart", port: "SuperTuxKart", note: "Free kart racer with Vulkan and OpenGL (750 MB)", page: "https://github.com/supertuxkart/stk-code", repo: "supertuxkart/stk-code", asset: ["mac-signed"]),
        .init(id: "luanti", game: "Luanti (Minetest)", port: "Luanti", note: "Free voxel sandbox with shader support", page: "https://github.com/luanti-org/luanti", repo: "luanti-org/luanti", asset: ["arm64.zip"]),
        .init(id: "srb2", game: "Sonic Robo Blast 2", port: "SRB2", note: "Free 3D Sonic fangame, OpenGL renderer", page: "https://github.com/STJr/SRB2", repo: "STJr/SRB2", asset: ["macos-installer.dmg"]),
        .init(id: "redeclipse", game: "Red Eclipse", port: "Red Eclipse", note: "Free fast arena shooter (950 MB)", page: "https://github.com/redeclipse/base", repo: "redeclipse/base", asset: ["mac.tar.bz2"]),
        .init(id: "soh", game: "Zelda: Ocarina of Time", port: "Ship of Harkinian", note: "PC port, needs your own ROM", page: "https://github.com/HarbourMasters/Shipwright", repo: "HarbourMasters/Shipwright", asset: ["mac.zip"]),
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
        guard let repo = p.repo, let api = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=10") else { return }
        busy = p.id; defer { busy = nil }
        do {
            var req = URLRequest(url: api); req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, _) = try await URLSession.shared.data(for: req)
            struct Rel: Decodable { struct A: Decodable { let name: String; let size: Int; let browser_download_url: URL }; let assets: [A] }
            guard let a = try JSONDecoder().decode([Rel].self, from: data).lazy.compactMap({ $0.assets.first(where: { a in let n = a.name.lowercased(); return !n.hasSuffix(".torrent") && !n.hasSuffix(".md5") && !n.hasSuffix(".sig") && p.asset.allSatisfy { n.contains($0) } }) }).first
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
            } else if o.name.contains(".tar.") {
                let out = Self.folder.appendingPathComponent(o.name.components(separatedBy: ".tar.")[0])
                try fm.createDirectory(at: out, withIntermediateDirectories: true)
                let t = Process(); t.executableURL = URL(fileURLWithPath: "/usr/bin/tar"); t.arguments = ["-xf", dest.path, "-C", out.path]; try t.run(); t.waitUntilExit()
                NSWorkspace.shared.activateFileViewerSelecting([out])
            } else if o.name.hasSuffix(".dmg") { NSWorkspace.shared.open(dest) }   // mounts it: drag the app to Applications
            else { NSWorkspace.shared.activateFileViewerSelecting([dest]) }
            message = L("Downloaded to ") + Self.folder.path
        } catch { message = L("Download failed: ") + error.localizedDescription }
    }
}

struct GameHubView: View {
    var addGame: () -> Void
    @StateObject private var installer = HubInstaller()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                SectionTitle("Game Hub", "Source ports that work well with MacShade. Only the port is downloaded. You need your own copy of the game and its data.")
                if let m = installer.message { Text(m).font(.callout).foregroundStyle(Theme.muted) }
                ForEach(HubCatalog.ports) { p in
                    Card {
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(p.game).font(.system(size: 16, weight: .heavy))
                                Text(p.port).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                                Text(LocalizedStringKey(p.note)).font(.system(size: 13)).foregroundStyle(Theme.muted)
                                Pill(text: label(p.status), color: p.status == .tested ? Theme.good : p.status == .likely ? Theme.warn : Theme.muted)
                            }
                            Spacer(minLength: 12)
                            VStack(alignment: .trailing, spacing: 8) {
                                if p.repo != nil {
                                    Button { Task { await installer.prepare(p) } } label: {
                                        if installer.busy == p.id { ProgressView().controlSize(.small) } else { Label("Download", systemImage: "arrow.down.circle") }
                                    }.buttonStyle(SoftButton(tint: Theme.accent)).disabled(installer.busy != nil)
                                }
                                Button { NSWorkspace.shared.open(URL(string: p.page)!) } label: { Label("Project page", systemImage: "safari") }.buttonStyle(SoftButton())
                            }
                        }
                    }
                }
                Button { addGame() } label: { Label("Add game", systemImage: "plus") }.buttonStyle(SoftButton())
            }.padding(28).frame(maxWidth: 760, alignment: .leading)
        }
        .alert(item: $installer.offer) { o in
            Alert(title: Text(L("Download this file?")),
                  message: Text("\(o.name)\n\(ByteCountFormatter.string(fromByteCount: Int64(o.size), countStyle: .file))\n\(o.url.host ?? "")"),
                  primaryButton: .default(Text(L("Download"))) { Task { await installer.download(o) } }, secondaryButton: .cancel())
        }
    }

    private func label(_ s: HubPort.Status) -> String { s == .tested ? L("Tested") : s == .likely ? L("Probably works") : L("Not tested") }
}
