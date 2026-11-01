import SwiftUI
import UniformTypeIdentifiers

/// The banner across the whole window: the selected game's picture (never stretched or cropped), its icon and name.
struct GameBanner: View {
    let game: Game?
    let title: String?          // shown instead of a game (hub, settings)
    @State private var image: NSImage?

    /// Follows the picture's own proportions as far as the window allows (width / aspect), between 120 and 140 pt (hub and settings: 96 pt).
    @State private var width: CGFloat = 900
    private var height: CGFloat {
        let aspect = image.map { $0.size.width / max($0.size.height, 1) } ?? 3.1
        return game == nil ? 96 : min(max(width / aspect, 120), 140)
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .bottomLeading) {
                Theme.rail
                if image == nil, let game { LinearGradient(colors: [Theme.tint(game.name).opacity(0.28), .clear], startPoint: .topLeading, endPoint: .trailing) }
                if let image {
                    // the whole picture, never cropped: fitted to the banner's height, at the right, fading into the background on its left
                    Image(nsImage: image).resizable().scaledToFit()
                        .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.3)], startPoint: .leading, endPoint: .trailing))
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                }
                HStack(spacing: 20) {
                    if let game { GameTile(name: game.name, path: game.sourcePath, size: 64) }
                    else { Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 56, height: 56) }
                    Text(game?.name ?? title ?? "MacShade").font(.system(size: 28, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                }.padding(.horizontal, 28).padding(.bottom, 16)
            }
            .overlay(alignment: .topTrailing) { if game != nil { menu.padding(12) } }
            .onAppear { width = geo.size.width }.onChange(of: geo.size.width) { width = $0 }
        }
        .frame(height: height)
        .clipped()
        .onAppear(perform: load)
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in   // an image dropped on the banner becomes the game's banner
            guard game != nil, let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in set(from: url) } } }
            return true
        }
    }

    private func load() { image = game.flatMap { NSImage(contentsOf: Paths.banner(for: $0)) } }

    private var menu: some View {
        Menu {
            Button("Choose banner image …") { choose() }
            Button("Find fan art (SteamGridDB) …") {
                var c = URLComponents(string: "https://www.steamgriddb.com/search/grids")!; c.queryItems = [URLQueryItem(name: "term", value: game?.name ?? "")]
                NSWorkspace.shared.open(c.url!)
            }
            if image != nil, let game { Divider(); Button("Remove banner") { try? FileManager.default.removeItem(at: Paths.banner(for: game)); image = nil } }
        } label: { Image(systemName: "photo") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 30)
            .background(Theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).help(L("Banner"))
    }

    private func choose() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.message = L("Choose a banner image (about 3:1, e.g. 1920×620)")
        if panel.runModal() == .OK, let url = panel.url { set(from: url) }
    }

    private func set(from url: URL) {
        guard let game, NSImage(contentsOf: url) != nil else { return }
        let fm = FileManager.default; try? fm.createDirectory(at: Paths.banners, withIntermediateDirectories: true)
        let dest = Paths.banner(for: game); try? fm.removeItem(at: dest)
        if (try? fm.copyItem(at: url, to: dest)) != nil { image = NSImage(contentsOf: dest) }
    }
}
