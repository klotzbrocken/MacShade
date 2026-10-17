import SwiftUI
import UniformTypeIdentifiers

/// First start / empty list: three steps and the two ways to add games.
struct WelcomeView: View {
    let pick: () -> Void, find: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 12) {
                Text("WELCOME").font(.system(size: 13, weight: .bold)).tracking(1.2).foregroundStyle(Theme.accent)
                Text("Better looking games.\nIn three steps.").font(.system(size: 46, weight: .heavy)).lineSpacing(0)
                Text("ReShade improves colours, sharpness and light in your games on the Mac. Your original stays untouched.").font(.system(size: 17)).foregroundStyle(Theme.muted).frame(maxWidth: 520, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: 18) {
                step(1, "Add games", "We search for them, or you choose them yourself.")
                step(2, "Choose a look", "Every game gets fitting looks. You can switch any time.")
                step(3, "Start with ReShade", "In the game, a key opens the ReShade menu.")
            }
            HStack(spacing: 12) {
                Button("Search games automatically", action: find).buttonStyle(BigButton())
                Button("Choose a game yourself …", action: pick).buttonStyle(SoftButton()).controlSize(.large)
            }
            Text("Drop a game (.app) here").font(.system(size: 13)).foregroundStyle(Theme.muted)
        }
        .padding(48).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
    private func step(_ n: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(n)").font(.system(size: 14, weight: .heavy)).foregroundStyle(Theme.accent).frame(width: 30, height: 30).background(Theme.raised, in: Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringKey(title)).font(.system(size: 16, weight: .bold))
                Text(LocalizedStringKey(text)).font(.system(size: 14)).foregroundStyle(Theme.muted)
            }
        }
    }
}

enum GameTab: String, CaseIterable { case look = "Look", start = "Start", keys = "Keys", performance = "Performance", advanced = "Advanced" }

struct UninstallButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .bold)).foregroundStyle(.white).padding(.horizontal, 16).padding(.vertical, 9)
            .background(Color(hex: 0xC93C3C).opacity(configuration.isPressed ? 0.75 : 1), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct GameDetail: View {
    @Binding var game: Game
    var onRemove: () -> Void
    @EnvironmentObject var launcher: Launcher
    @State private var tab = GameTab.look
    @State private var info: GameInfo?
    @State private var showReShadeLog = true
    @State private var presetMessage: String?
    @State private var presets: [String] = []
    @State private var activePreset = ""
    @State private var confirmReset = false
    @State private var copyUsage: Int64 = 0
    @State private var banner: NSImage?
    @State private var uninstallStep = 0
    @State private var uninstallError: String?

    private var phase: Phase { launcher.phase(of: game.id) }
    private var busy: Bool { if case .preparing = phase { return true }; return phase == .running }
    private var instance: URL { Paths.instance(for: game) }
    private var hasLog: Bool { !(launcher.log[game.id] ?? "").isEmpty || !(launcher.reshadeLog[game.id] ?? "").isEmpty }
    private var failed: Bool { if case .failed = phase { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            hero
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 4) {
                ForEach(GameTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        Text(LocalizedStringKey(t.rawValue)).font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(tab == t ? Theme.text : Theme.muted)
                            .padding(.horizontal, 16).padding(.vertical, 10)
                            .background(tab == t ? Theme.raised : .clear, in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                }
                Spacer()
            }.padding(.horizontal, 36).padding(.top, 14)
            ScrollView {
                Group {
                    switch tab {
                    case .look: lookTab
                    case .start: startTab
                    case .keys: keysTab
                    case .performance: performanceTab
                    case .advanced: advancedTab
                    }
                }.padding(.horizontal, 36).padding(.vertical, 22).frame(maxWidth: 980, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .task {
            Launcher.prepareInstance(game); refreshPresets()
            info = await Task.detached { [p = game.sourcePath] in inspectGame(p) }.value
            copyUsage = await Task.detached { [u = Paths.copy(for: game)] in Paths.diskUsage(u) }.value
        }
        .onChange(of: phase) { _ in refreshPresets(); Task { copyUsage = await Task.detached { [u = Paths.copy(for: game)] in Paths.diskUsage(u) }.value } }
        .onChange(of: failed) { if $0 { tab = .advanced } }   // the log is there
    }

    // MARK: hero

    private var hero: some View {
        HStack(spacing: 22) {
            GameTile(name: game.name, path: game.sourcePath, size: 76)
            VStack(alignment: .leading, spacing: 8) {
                Text(game.name).font(.system(size: 30, weight: .heavy)).lineLimit(1).minimumScaleFactor(0.6)
                Flow(spacing: 8) {
                    if let info {
                        Pill(text: info.api.shortLabel, color: info.api == .vulkan ? Theme.good : (info.api == .bridge ? Theme.accent : Theme.warn))
                        if !info.archs.contains("arm64") && !game.captureMode { Pill(text: L("Architecture: %@", info.archs), color: Theme.warn) }
                    }
                    if let seen = launcher.observedPath[game.id], seen != info?.api.shortLabel { Pill(text: L("Last start: %@", seen), color: seen == L("ReShade loaded, but no graphics path was hooked") ? Theme.warn : Theme.accent) }
                    if game.captureMode { Pill(text: L("Screen filter"), color: Theme.warn) }
                    if copyUsage > 0 && !game.captureMode { Pill(text: L("Game copy ready · %@", ByteCountFormatter.string(fromByteCount: copyUsage, countStyle: .file)), color: Theme.good) }
                    statusView
                }
                if let why = PortAdvice.incompatible(game.name) { Text(why).font(.caption).foregroundStyle(Theme.warn) }
                if let info, !info.archs.contains("arm64"), !game.captureMode { Text("The game has no arm64 version; ReShade is arm64 and cannot be loaded.").font(.caption).foregroundStyle(Theme.warn) }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 8) {
                if phase == .running {
                    Button { launcher.stop(game) } label: { Label("Quit game", systemImage: "stop.fill") }.buttonStyle(BigButton(stop: true))
                } else {
                    Button { launcher.start(game) } label: { Label("Start with ReShade", systemImage: "play.fill").lineLimit(1).fixedSize() }
                        .buttonStyle(BigButton()).disabled(busy || (info?.api == .staticVulkan && !game.captureMode)).keyboardShortcut(.return, modifiers: .command)
                }
                Text(L("In the game: %@ opens ReShade", game.overlayKey.label)).font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
        }.padding(.horizontal, 36).padding(.top, 28).padding(.bottom, 22)
        .frame(minHeight: banner == nil ? 0 : 210)
        .background { bannerBackground }
        .overlay(alignment: .topTrailing) { bannerMenu.padding(10) }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in   // an image dropped on the header becomes the banner
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in setBanner(from: url) } } }
            return true
        }
        .onAppear { banner = NSImage(contentsOf: Paths.banner(for: game)) }
    }

    @ViewBuilder private var bannerBackground: some View {
        if let banner {
            Image(nsImage: banner).resizable().scaledToFill().frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                .overlay(LinearGradient(colors: [Theme.bg.opacity(0.94), Theme.bg.opacity(0.55), Theme.bg.opacity(0.15)], startPoint: .leading, endPoint: .trailing))
                .overlay(LinearGradient(colors: [.clear, Theme.bg], startPoint: .center, endPoint: .bottom))
        }
    }

    private var bannerMenu: some View {
        Menu {
            Button("Choose banner image …") { chooseBanner() }
            Button("Find fan art (SteamGridDB) …") {
                var c = URLComponents(string: "https://www.steamgriddb.com/search/grids")!; c.queryItems = [URLQueryItem(name: "term", value: game.name)]
                NSWorkspace.shared.open(c.url!)
            }
            if banner != nil { Divider(); Button("Remove banner") { try? FileManager.default.removeItem(at: Paths.banner(for: game)); banner = nil } }
        } label: { Image(systemName: "photo") }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 30, height: 30)
            .background(Theme.card.opacity(0.85), in: RoundedRectangle(cornerRadius: 8)).help(L("Banner"))
    }

    private func chooseBanner() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; panel.message = L("Choose a banner image (about 3:1, e.g. 1920×620)")
        if panel.runModal() == .OK, let url = panel.url { setBanner(from: url) }
    }

    private func setBanner(from url: URL) {
        guard NSImage(contentsOf: url) != nil else { return }
        let fm = FileManager.default; try? fm.createDirectory(at: Paths.banners, withIntermediateDirectories: true)
        let dest = Paths.banner(for: game); try? fm.removeItem(at: dest)
        if (try? fm.copyItem(at: url, to: dest)) != nil { banner = NSImage(contentsOf: dest) }
    }

    @ViewBuilder private var statusView: some View {
        switch phase {
        case .idle: EmptyView()
        case .preparing(let m): HStack(spacing: 6) { ProgressView().controlSize(.small); Text(m).font(.caption) }
        case .running: Pill(text: L("Running"), color: Theme.good)
        case .failed(let m): Text(m).font(.caption).foregroundStyle(Theme.bad).lineLimit(3)
        }
    }

    // MARK: look

    private var lookTab: some View {
        let builtIn = Presets.bundledNames(for: game)
        return VStack(alignment: .leading, spacing: 20) {
            if let b = PortAdvice.better(for: game.name) {
                Card {
                    HStack(alignment: .center, spacing: 16) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(L("Better experience: %@", b.name)).font(.system(size: 15, weight: .bold))
                            Text(b.why).font(.system(size: 13)).foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Link("Open page", destination: b.url).buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                    }
                }
            }
            HStack(alignment: .bottom) {
                SectionTitle("Choose your look", "The chosen look is loaded at the next start. In the game you can change it live.")
                Spacer()
                Button("Import preset …") { importPreset() }.buttonStyle(SoftButton())
                Button("Show folder") { Launcher.prepareInstance(game); NSWorkspace.shared.open(instance) }.buttonStyle(SoftButton())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 16)], spacing: 16) {
                ForEach(presets, id: \.self) { name in
                    let on = name == activePreset
                    Button { select(name) } label: {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text(Presets.displayName(name)).font(.system(size: 16, weight: .bold)).lineLimit(1)
                                Spacer()
                                Pill(text: name == Presets.defaultName ? L("Default") : (builtIn.contains(name) ? L("Included") : L("Own")), color: on ? Theme.accent : Theme.muted)
                            }
                            let parts = Presets.explain(name, for: game)
                            VStack(alignment: .leading, spacing: 5) {
                                ForEach(Array(parts.prefix(6).enumerated()), id: \.offset) { _, part in
                                    (Text(part.title).fontWeight(.semibold).foregroundColor(Theme.text) + Text(part.detail.isEmpty ? "" : " · " + part.detail).foregroundColor(Theme.muted))
                                        .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                                }
                                if parts.count > 6 { Text("+\(parts.count - 6)").font(.system(size: 12.5)).foregroundStyle(Theme.muted) }
                            }
                        }
                        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                        .background(on ? Color(hex: 0x182034) : Theme.card, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(on ? Theme.accent : Theme.line, lineWidth: 1.5))
                    }.buttonStyle(.plain).disabled(busy)
                }
            }
            if let presetMessage { Text(presetMessage).font(.caption).foregroundStyle(Theme.good) }
            Flow {
                Button("Restore default preset") { Presets.restoreDefault(for: game); presetMessage = L("Default preset restored and selected."); refreshPresets() }.buttonStyle(SoftButton())
                Button("Delete selected preset") { Presets.delete(activePreset, for: game); presetMessage = L("Preset deleted."); refreshPresets() }
                    .buttonStyle(SoftButton(tint: Theme.bad)).disabled(activePreset.isEmpty || activePreset == Presets.defaultName)
                Button("Reset all presets …") { confirmReset = true }.buttonStyle(SoftButton(tint: Theme.bad))
            }.disabled(phase == .running)
        }
        .confirmationDialog(L("Reset all presets of “%@”?", game.name), isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { Presets.resetAll(for: game); presetMessage = L("All presets were reset to the default."); refreshPresets() }
        } message: { Text("This deletes every preset of this game, including imported ones, and restores the default preset.") }
    }

    private func select(_ name: String) { activePreset = name; if name != Presets.active(for: game) { Presets.activate(name, for: game) } }

    private func refreshPresets() {
        presets = Presets.list(for: game).sorted { $0 == Presets.defaultName ? $1 != Presets.defaultName : ($1 != Presets.defaultName && $0 < $1) }
        activePreset = Presets.active(for: game).flatMap { presets.contains($0) ? $0 : nil } ?? ""
    }

    private func importPreset() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.init(filenameExtension: "ini")!, .plainText]; panel.message = L("Choose a ReShade preset (.ini)")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try PackageManager.importPreset(url, for: game); presetMessage = L("Preset “%@” imported and selected.", url.lastPathComponent); refreshPresets() }
        catch { presetMessage = L("Import failed: %@", "\(error)") }
    }

    // MARK: start

    private var startTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            LaunchOptionsBox(game: $game)
            Card {
                Toggle(isOn: $game.autoStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start this game automatically when the app opens").font(.system(size: 15, weight: .bold))
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
        }
    }

    // MARK: keys

    private var keysTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle("Hotkeys in the game", "Click a key, then press the combination you want.")
            Card {
                KeyRecorder(title: "Open overlay", binding: $game.overlayKey)
                Divider().overlay(Theme.line)
                KeyRecorder(title: "Screenshot", binding: $game.screenshotKey)
                Divider().overlay(Theme.line)
                KeyRecorder(title: "Effects on/off", binding: $game.effectsKey)
            }
            HStack(spacing: 8) {
                Text("Suggestions for the overlay key").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Button("Home (Fn + ←)") { game.overlayKey = .home }.buttonStyle(SoftButton())
                Button("F10") { game.overlayKey = KeyBinding(vk: 0x79) }.buttonStyle(SoftButton())
                Button("Ctrl + Shift + O") { game.overlayKey = KeyBinding(vk: 0x4F, ctrl: true, shift: true) }.buttonStyle(SoftButton())
            }
            Text("Applied at the next start. Changes made later inside ReShade (Settings) are kept as long as you change nothing here.").font(.caption).foregroundStyle(Theme.muted)
            Button("Screenshots") { NSWorkspace.shared.open(instance.appendingPathComponent("Screenshots")) }.buttonStyle(SoftButton())
        }
    }

    // MARK: performance

    private var performanceTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle("Performance")
            Card {
                Text("Frame rate limit").font(.system(size: 15, weight: .bold))
                Text("Holds the game to this frame rate (also saves power and heat). Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                HStack(spacing: 4) {
                    ForEach([0, 30, 60, 120, 144], id: \.self) { v in
                        Button { game.fpsLimit = v } label: {
                            Text(v == 0 ? L("No limit") : "\(v)").font(.system(size: 13, weight: .bold))
                                .foregroundStyle(game.fpsLimit == v ? Theme.onAccent : Theme.muted)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(game.fpsLimit == v ? Theme.accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                        }.buttonStyle(.plain)
                    }
                    if ![0, 30, 60, 120, 144].contains(game.fpsLimit) { Pill(text: "\(game.fpsLimit) FPS", color: Theme.accent) }
                }.padding(4).background(Theme.bg, in: RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
            }
            Card {
                Toggle(isOn: $game.pipeline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smooth frame rate for OpenGL and Metal games (about 2 frames more input delay)").font(.system(size: 15, weight: .bold))
                        Text("Hands frames to ReShade two frames late, so the game never waits for it. Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
        }
    }

    // MARK: advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 20) {
            Card {
                Text("Name").font(.system(size: 15, weight: .bold))
                TextField("Name", text: $game.name).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            HStack(alignment: .top, spacing: 16) {
                Card {
                    Text("Game copy").font(.system(size: 15, weight: .bold))
                    Text(copyUsage == 0 ? L("There is no copy yet.") : L("Frees %@. It is made again at the next start.", ByteCountFormatter.string(fromByteCount: copyUsage, countStyle: .file))).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Flow {
                        Button("Recreate the game copy") { launcher.start(game, force: true) }.buttonStyle(SoftButton()).disabled(busy)
                        Button("Delete the game copy") { Paths.deleteCopy(of: game); copyUsage = 0 }.buttonStyle(SoftButton(tint: Theme.bad)).disabled(busy || copyUsage == 0)
                    }
                    Divider().overlay(Theme.line)
                    Toggle("Suppress the macOS restore-windows dialog (-ApplePersistenceIgnoreState)", isOn: $game.suppressRestoreDialog).toggleStyle(.switch).tint(Theme.accent).font(.system(size: 13))
                }
                Card {
                    Text("Folders").font(.system(size: 15, weight: .bold))
                    Text("Add your own effects (.fx) as a folder with “Shaders” and “Textures” to the collections.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Flow {
                        Button("Effect collections") { NSWorkspace.shared.open(Paths.collections) }.buttonStyle(SoftButton())
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: game.sourcePath)]) }.buttonStyle(SoftButton())
                    }
                    Divider().overlay(Theme.line)
                    Button("Remove from list", role: .destructive, action: onRemove).buttonStyle(SoftButton(tint: Theme.bad)).disabled(busy)
                }
            }
            Card {
                Text("Screen filter mode (experimental)").font(.system(size: 15, weight: .bold))
                Text("The game starts unchanged: no copy, nothing injected. MacShade captures the game window and shows it with ReShade on top. This works for games MacShade cannot hook (Metal, Mac App Store, copy protection, Intel-only games). Costs one or two frames of delay, no depth effects. Needs the Screen Recording permission; works best in a window or borderless.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Toggle("Use the screen filter for this game", isOn: $game.captureMode).toggleStyle(.switch).tint(Theme.accent).disabled(busy)
                if game.captureMode { Text(L("In the game: %@ opens ReShade, %@ switches the effects.", game.overlayKey.label, game.effectsKey.label)).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Card {
                Text("Uninstall game").font(.system(size: 15, weight: .bold))
                Text("Moves the game, its data folders from the start parameters, the game copy and the MacShade settings for it to the Trash.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Button { uninstallStep = 1 } label: { Label("Uninstall game …", systemImage: "trash") }
                    .buttonStyle(UninstallButtonStyle()).disabled(busy)
                if let e = uninstallError { Text(e).font(.caption).foregroundStyle(Theme.bad) }
            }
            if hasLog { logBox }
        }
        .alert(L("Uninstall “%@”?", game.name), isPresented: Binding(get: { uninstallStep == 1 }, set: { if !$0 && uninstallStep == 1 { uninstallStep = 0 } })) {
            Button(L("Cancel"), role: .cancel) { uninstallStep = 0 }
            Button(L("Continue …"), role: .destructive) { uninstallStep = 2 }
        } message: { Text(uninstallTargets.map(\.path).joined(separator: "\n")) }
        .alert(L("Really uninstall “%@”?", game.name), isPresented: Binding(get: { uninstallStep == 2 }, set: { if !$0 && uninstallStep == 2 { uninstallStep = 0 } })) {
            Button(L("Cancel"), role: .cancel) { uninstallStep = 0 }
            Button(L("Move to Trash"), role: .destructive) { uninstall() }
        } message: { Text(L("The items above go to the Trash and the game leaves your list. You can still restore them from the Trash.")) }
    }

    /// The game itself plus every existing folder named in its start parameters (e.g. `+set fs_basepath /path/to/data`), with symlinks resolved.
    private var uninstallTargets: [URL] {
        let fm = FileManager.default
        var out = [URL(fileURLWithPath: game.sourcePath)]
        for token in game.arguments.split(separator: " ").map(String.init) where token.hasPrefix("/") {
            let u = URL(fileURLWithPath: token).resolvingSymlinksInPath()
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue, u.pathComponents.count > 2, !["/Applications", "/Users", "/Volumes", "/System", "/Library"].contains(u.path), u.path != fm.homeDirectoryForCurrentUser.path else { continue }
            if !out.contains(u) { out.append(u) }
        }
        return out
    }

    private func uninstall() {
        uninstallStep = 0; uninstallError = nil
        var failed: [String] = []
        for u in uninstallTargets + [Paths.copy(for: game), Paths.instance(for: game), Paths.banner(for: game)] where FileManager.default.fileExists(atPath: u.path) {
            do { try FileManager.default.trashItem(at: u, resultingItemURL: nil) } catch { failed.append("\(u.lastPathComponent): \(error.localizedDescription)") }
        }
        if failed.isEmpty { onRemove() } else { uninstallError = failed.joined(separator: "\n") }
    }

    private var logBox: some View {
        Card {
            HStack {
                Text("Log").font(.system(size: 15, weight: .bold))
                Spacer()
                Picker("", selection: $showReShadeLog) { Text("ReShade").tag(true); Text("Game").tag(false) }.pickerStyle(.segmented).frame(width: 200).labelsHidden()
            }
            ScrollView { Text((showReShadeLog ? launcher.reshadeLog[game.id] : launcher.log[game.id]) ?? "").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(hex: 0xB9C1D0)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                .frame(height: 180).padding(10).background(Color(hex: 0x0B0D11), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}
