import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var store: Store
    @EnvironmentObject var launcher: Launcher
    @State private var selection: UUID?
    @State private var showPackages = false
    @State private var showDiscover = false
    @State private var showSettings = false
    @State private var renaming: Game?
    @AppStorage("sidebarWidth") private var sidebarWidth = 264.0
    @State private var dragStartWidth: Double?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            ZStack { Rectangle().fill(Theme.line).frame(width: 1) }   // the sidebar's edge: draggable, 9 pt wide hit area
                .frame(width: 9).background(Theme.bg).contentShape(Rectangle())
                .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if dragStartWidth == nil { dragStartWidth = sidebarWidth }
                        sidebarWidth = min(max((dragStartWidth ?? 264) + Double(v.translation.width), 200), 420)
                    }
                    .onEnded { _ in dragStartWidth = nil })
            VStack(spacing: 0) {
                if let error = store.storageError {
                    HStack { Image(systemName: "exclamationmark.triangle.fill"); Text(error).font(.callout); Spacer(); Button("Dismiss") { store.storageError = nil } }
                        .padding(8).background(.orange.opacity(0.25))
                }
                if showSettings {
                    ScrollView { SettingsView(embedded: true, showPackages: { showPackages = true }) }
                } else if store.games.isEmpty {
                    WelcomeView(pick: pickApp, find: { showDiscover = true })
                } else if let i = store.games.firstIndex(where: { $0.id == selection }) {
                    GameDetail(game: $store.games[i], onRemove: { remove(store.games[i].id) }).id(store.games[i].id)
                } else {
                    Text("Select a game").foregroundStyle(Theme.muted).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }.frame(maxWidth: .infinity)
        }
        .background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .onAppear { if selection == nil { selection = store.games.first?.id } }
        .task {
            // `MacShade --start "<Spielname>"` selects and launches a game right away (handy for scripts).
            if let i = CommandLine.arguments.firstIndex(of: "--install-package"), i + 1 < CommandLine.arguments.count {   // headless check of the package download
                let name = CommandLine.arguments[i + 1]
                do {
                    guard let p = try await PackageManager.fetchList().first(where: { $0.name == name }) else { print("package not found"); return }
                    try await PackageManager.install(name: p.name, from: p.downloadURL); print("installed \(p.name)")
                } catch { print("failed: \(error)") }
            }
            if CommandLine.arguments.contains("--scan-games") {   // headless check of the game search: prints what the "Find games" sheet would list
                let known = Set(store.games.map(\.sourcePath))
                for c in await Task.detached(operation: { GameDiscovery.scan(GameDiscovery.defaultFolders(), excluding: known) }).value { print("\(c.name) | \(c.path) | \(c.info.archs) | \(c.info.api.label)") }
                print("scan done"); exit(0)
            }
            for g in store.games where g.autoStart { launcher.start(g) }
            let a = CommandLine.arguments
            if let i = a.firstIndex(of: "--select"), i + 1 < a.count, let g = store.games.first(where: { $0.name == a[i + 1] }) { selection = g.id }
            if let i = a.firstIndex(of: "--start"), i + 1 < a.count, let g = store.games.first(where: { $0.name == a[i + 1] }) { selection = g.id; launcher.start(g) }
        }
        .sheet(isPresented: $showPackages) { PackagesView() }
        .sheet(item: $renaming) { g in RenameSheet(game: g) { name in if let i = store.games.firstIndex(where: { $0.id == g.id }) { store.games[i].name = name } } }
        .sheet(isPresented: $showDiscover) { DiscoverView { id in if let id { selection = id } } }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in if let id = store.add(appURL: url) { selection = id } }
                }
            }
            return true
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage).resizable().frame(width: 32, height: 32)
                Text("MacShade").font(.system(size: 17, weight: .heavy))
            }.padding(.horizontal, 6)
            Text("MY GAMES").font(.system(size: 11, weight: .bold)).tracking(1).foregroundStyle(Theme.muted).padding(.horizontal, 10)
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(store.games) { g in
                        let on = g.id == selection && !showSettings
                        Button { selection = g.id; showSettings = false } label: {
                            HStack(spacing: 12) {
                                GameTile(name: g.name, path: g.sourcePath, size: 36)
                                Text(g.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Circle().fill(launcher.phase(of: g.id) == .running ? Theme.good : Theme.lineStrong).frame(width: 8, height: 8)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 8).contentShape(Rectangle())
                            .background(on ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                        .contextMenu {
                            if launcher.phase(of: g.id) == .running { Button("Quit game") { launcher.stop(g) } } else { Button("Start with ReShade") { launcher.start(g) } }
                            Button("Rename game …") { renaming = g }
                            Divider()
                            Button("Remove from list", role: .destructive) { remove(g.id) }.disabled(launcher.isBusy(g.id))
                        }
                    }
                }
            }
            VStack(spacing: 8) {
                Button { pickApp() } label: { Label("Add game", systemImage: "plus").frame(maxWidth: .infinity) }.buttonStyle(SoftButton())
                HStack(spacing: 8) {
                    Button { showDiscover = true } label: { Label("Find games", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }.buttonStyle(SoftButton())
                    Button { showSettings.toggle() } label: { Image(systemName: "gearshape") }.buttonStyle(SoftButton(tint: showSettings ? Theme.accent : Theme.text)).help(L("Settings"))
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 18).frame(width: CGFloat(sidebarWidth)).background(Theme.rail)
    }

    private func remove(_ id: UUID) {
        if let game = store.games.first(where: { $0.id == id }) { launcher.stop(game); Paths.deleteCopy(of: game) }   // the game copy is of no use without the list entry
        store.games.removeAll { $0.id == id }; if selection == id { selection = nil }
    }

    private func pickApp() {
        let panel = NSOpenPanel()
        panel.message = L("Choose a game (.app)"); panel.allowedContentTypes = [.applicationBundle]; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        if panel.runModal() == .OK, let url = panel.url, let id = store.add(appURL: url) { selection = id }
    }
}

@MainActor private var iconCache: [String: NSImage] = [:]
@MainActor func gameIcon(_ path: String) -> NSImage {
    if let i = iconCache[path] { return i }
    let i = NSWorkspace.shared.icon(forFile: path); iconCache[path] = i; return i
}

struct RenameSheet: View {
    let game: Game
    var done: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename game").font(.system(size: 18, weight: .heavy))
            TextField("Name", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack { Spacer(); Button("Cancel") { dismiss() }.buttonStyle(SoftButton()); Button("Save", action: save).buttonStyle(SoftButton(tint: Theme.accent)).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
        }
        .padding(22).frame(width: 380).background(Theme.bg).preferredColorScheme(.dark).onAppear { name = game.name }
    }
    private func save() { let n = name.trimmingCharacters(in: .whitespaces); guard !n.isEmpty else { return }; done(n); dismiss() }
}
