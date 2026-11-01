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
                step(3, "Start ReShade", "In the game, a key opens the ReShade menu.")
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
    @State private var open: Set<String> = ["Start"]   // the open sections of the inspector
    @State private var info: GameInfo?
    @State private var showReShadeLog = true
    @State private var presetMessage: String?
    @State private var presets: [String] = []
    @State private var activePreset = ""
    @State private var confirmReset = false
    @State private var expandedLook: String?
    @State private var copyUsage: Int64 = 0
    @State private var captureAllowed = CGPreflightScreenCaptureAccess()
    @State private var uninstallStep = 0
    @State private var uninstallError: String?

    private var phase: Phase { launcher.phase(of: game.id) }
    private var busy: Bool { if case .preparing = phase { return true }; return phase == .running }
    private var instance: URL { Paths.instance(for: game) }
    private var hasLog: Bool { !(launcher.log[game.id] ?? "").isEmpty || !(launcher.reshadeLog[game.id] ?? "").isEmpty }
    private var failed: Bool { if case .failed = phase { return true }; return false }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                VStack(spacing: 0) {   // the looks
                    statusRow
                    ScrollView { lookTab.padding(.horizontal, 28).padding(.vertical, 18).frame(maxWidth: .infinity, alignment: .leading) }
                }
                Rectangle().fill(Theme.line).frame(width: 1)
                inspector.frame(width: 340)
            }
            Rectangle().fill(Theme.line).frame(height: 1)
            actionBar
        }
        .onAppear { captureAllowed = CGPreflightScreenCaptureAccess() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in captureAllowed = CGPreflightScreenCaptureAccess() }
        .task {
            Launcher.prepareInstance(game); refreshPresets()
            info = await Task.detached { [p = game.sourcePath] in inspectGame(p) }.value
            copyUsage = await Task.detached { [u = Paths.copy(for: game)] in Paths.diskUsage(u) }.value
        }
        .onChange(of: phase) { _ in refreshPresets(); Task { copyUsage = await Task.detached { [u = Paths.copy(for: game)] in Paths.diskUsage(u) }.value } }
        .onChange(of: failed) { if $0 { open.insert("Advanced") } }   // the log is there
    }

    // MARK: hero

    /// API, copy, mode and status below the banner line.
    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 8) {
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
            if !game.captureMode, let why = PortAdvice.incompatible(game.name) {
                Text(why).font(.caption).foregroundStyle(Theme.warn)
                Button("Use the screen filter mode") { setCapture(true) }.buttonStyle(SoftButton(tint: Theme.accent))
            }
            if let info, !info.archs.contains("arm64"), !game.captureMode { Text("The game has no arm64 version; ReShade is arm64 and cannot be loaded.").font(.caption).foregroundStyle(Theme.warn) }
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.top, 14)
    }

    /// Fixed bar at the bottom: status on the left, the two start buttons on the right.
    private var actionBar: some View {
        HStack(spacing: 10) {
            statusView
            if let seen = launcher.observedPath[game.id], seen != info?.api.shortLabel {
                Pill(text: L("Last start: %@", seen), color: seen == L("ReShade loaded, but no graphics path was hooked") ? Theme.warn : Theme.accent)
            }
            Spacer()
            if phase == .running {
                Button { launcher.stop(game) } label: { Label("Quit game", systemImage: "stop.fill").lineLimit(1).fixedSize() }.buttonStyle(BigButton(stop: true, small: true))
            } else {
                Button { launcher.startPlain(game) } label: { Text("Normal start").lineLimit(1).fixedSize() }
                    .buttonStyle(QuietButton()).disabled(busy).help(L("Starts the game without ReShade, as if you had opened it yourself."))
                Button { launcher.start(game) } label: { Label("Start ReShade", systemImage: "play.fill").lineLimit(1).fixedSize() }
                    .buttonStyle(BigButton(small: true)).disabled(busy || (info?.api == .staticVulkan && !game.captureMode)).keyboardShortcut(.return, modifiers: .command)
            }
        }.padding(.horizontal, 28).padding(.vertical, 12).background(Theme.rail)
    }

    /// Everything but the looks, in folding sections beside the look list.
    private var inspector: some View {
        ScrollView {
            VStack(spacing: 10) {
                section("Start") { startTab }
                section("Performance") { performanceSection }
                section("Hotkeys in the game") { keysSection }
                section("Advanced") { advancedTab }
            }.padding(16)
        }.background(Theme.rail.opacity(0.5))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        let isOpen = open.contains(title)
        return VStack(alignment: .leading, spacing: 12) {
            Button { if isOpen { open.remove(title) } else { open.insert(title) } } label: {
                HStack {
                    Text(LocalizedStringKey(title)).font(.system(size: 14, weight: .bold))
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 11, weight: .bold)).rotationEffect(.degrees(isOpen ? 90 : 0)).foregroundStyle(Theme.muted)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            if isOpen { content().fixedSize(horizontal: false, vertical: true) }
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14)).overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.line))
    }

    /// Turns the screen filter mode on or off; switching it on asks for the Screen Recording permission right away, not at the first start.
    private func setCapture(_ on: Bool) {
        game.captureMode = on
        if on && !CGPreflightScreenCaptureAccess() { _ = CGRequestScreenCaptureAccess() }
        captureAllowed = CGPreflightScreenCaptureAccess()
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
        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Choose your look").font(.system(size: 18, weight: .heavy)).lineLimit(1).fixedSize()
                    Text("Only one look is active per game. It is loaded at the next start; in the game you can change it live.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Label(L("In the game: %@ opens ReShade", game.overlayKey.label), systemImage: "keyboard").font(.system(size: 12)).foregroundStyle(Theme.muted)
                }
                Spacer(minLength: 12)
                Menu {
                    Button("Import preset …") { importPreset() }
                    Button("Show folder") { Launcher.prepareInstance(game); NSWorkspace.shared.open(instance) }
                    Button("Restore default preset") { Presets.restoreDefault(for: game); presetMessage = L("Default preset restored and selected."); refreshPresets() }
                    Divider()
                    Button("Delete selected preset") { Presets.delete(activePreset, for: game); presetMessage = L("Preset deleted."); refreshPresets() }
                        .disabled(activePreset.isEmpty || activePreset == Presets.defaultName)
                    Button("Reset all presets …") { confirmReset = true }
                } label: { Label("More …", systemImage: "ellipsis.circle").font(.system(size: 13, weight: .semibold)) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(phase == .running)
            }
            VStack(spacing: 0) {
                ForEach(Array(presets.enumerated()), id: \.element) { index, name in
                    if index > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                    LookCard(game: game, name: name, isActive: name == activePreset,
                             kind: name == Presets.defaultName ? L("Default") : (builtIn.contains(name) ? L("Included") : L("Own")),
                             locked: phase == .running, expanded: $expandedLook, onSelect: { select(name) },
                             onChange: { presetMessage = $0; refreshPresets() })
                }
            }
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .clipShape(RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line, lineWidth: 1))
            if let presetMessage { Text(presetMessage).font(.caption).foregroundStyle(Theme.good) }
            if let b = PortAdvice.better(for: game.name) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "sparkles").foregroundStyle(Theme.accent)
                    (Text(L("Better experience: %@", b.name)).fontWeight(.bold) + Text("  ·  " + b.why).foregroundColor(Theme.muted)).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Link("Open page", destination: b.url).buttonStyle(.plain).font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
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
        VStack(alignment: .leading, spacing: 12) {
            LaunchOptionsBox(game: $game)
            Card {
                Toggle(isOn: $game.autoStart) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Start this game automatically when the app opens").font(.system(size: 15, weight: .bold))
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
            Card {
                Toggle(isOn: $game.pipelineMetal) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smooth frame rate for Metal games (about 2 frames more input delay, gives effects a depth buffer)").font(.system(size: 15, weight: .bold))
                        Text("Off by default: Metal games pace their own frames, and the extra delay is noticeable in racing and action games. Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
        }
    }

    // MARK: keys

    private var keysSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Click a key, then press the combination you want.").font(.system(size: 12.5)).foregroundStyle(Theme.muted)
            Card {
                KeyRecorder(title: "Open overlay", binding: $game.overlayKey)
                Divider().overlay(Theme.line)
                KeyRecorder(title: "Screenshot", binding: $game.screenshotKey)
                Divider().overlay(Theme.line)
                KeyRecorder(title: "Effects on/off", binding: $game.effectsKey)
            }
            Text("Suggestions for the overlay key").font(.system(size: 13)).foregroundStyle(Theme.muted)
            Flow {
                Button("Home (Fn + ←)") { game.overlayKey = .home }.buttonStyle(SoftButton())
                Button("F10") { game.overlayKey = KeyBinding(vk: 0x79) }.buttonStyle(SoftButton())
                Button("Ctrl + Shift + O") { game.overlayKey = KeyBinding(vk: 0x4F, ctrl: true, shift: true) }.buttonStyle(SoftButton())
            }
            Text("Applied at the next start. Changes made later inside ReShade (Settings) are kept as long as you change nothing here.").font(.caption).foregroundStyle(Theme.muted)
            Button("Screenshots") { NSWorkspace.shared.open(instance.appendingPathComponent("Screenshots")) }.buttonStyle(SoftButton())
        }
    }

    // MARK: performance

    private var performanceSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Text("Frame rate limit").font(.system(size: 15, weight: .bold))
                Text("Holds the game to this frame rate (also saves power and heat). Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                if game.captureMode { Text("In screen filter mode this limits the filtered picture only; the game itself keeps running at its own rate.").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.accent) }
                let steps = Array(Set([0, 30, 60, 120, 144, game.fpsLimit])).sorted()
                Picker("", selection: $game.fpsLimit) { ForEach(steps, id: \.self) { Text($0 == 0 ? L("No limit") : "\($0) FPS").tag($0) } }
                    .labelsHidden().pickerStyle(.menu).fixedSize()
            }
            Card {
                Toggle(isOn: $game.captureHalfResolution) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Capture at half resolution (screen filter mode)").font(.system(size: 15, weight: .bold))
                        Text("Only used in the screen filter mode: the game window is captured at half the pixel size and enlarged again. ReShade has fewer pixels to process, so the frame rate is higher, but the picture is softer. Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
            Card {
                Toggle(isOn: $game.captureDynamic) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Dynamic resolution (screen filter mode)").font(.system(size: 15, weight: .bold))
                        Text("Only used in the screen filter mode: when ReShade cannot keep up, the capture size drops in steps (100 %, 90 %, 75 %) and returns when there is room again. The picture gets slightly softer and flickers briefly at each change. Not combined with half resolution. Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }.toggleStyle(.switch).tint(Theme.accent).disabled(game.captureHalfResolution)
            }
            Card {
                Toggle(isOn: $game.pipeline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Smooth frame rate for OpenGL games (about 2 frames more input delay)").font(.system(size: 15, weight: .bold))
                        Text("Hands frames to ReShade two frames late, so the game never waits for it. Takes effect at the next start.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                    }
                }.toggleStyle(.switch).tint(Theme.accent)
            }
        }
    }

    // MARK: advanced

    private var advancedTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Card {
                Text("Name").font(.system(size: 15, weight: .bold))
                TextField("Name", text: $game.name).textFieldStyle(.roundedBorder).frame(maxWidth: 360)
            }
            VStack(alignment: .leading, spacing: 12) {
                Card {
                    Text("Game copy").font(.system(size: 15, weight: .bold))
                    if game.captureMode { Text("Not used in screen filter mode: the original app is started.").font(.system(size: 13)).foregroundStyle(Theme.accent) }
                    Text(copyUsage == 0 ? L("There is no copy yet.") : L("Frees %@. It is made again at the next start.", ByteCountFormatter.string(fromByteCount: copyUsage, countStyle: .file))).font(.system(size: 13)).foregroundStyle(Theme.muted)
                    Flow {
                        Button("Recreate the game copy") { launcher.start(game, force: true) }.buttonStyle(SoftButton()).disabled(busy || game.captureMode)
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
                Toggle("Use the screen filter for this game", isOn: Binding(get: { game.captureMode }, set: { setCapture($0) })).toggleStyle(.switch).tint(Theme.accent).disabled(busy)
                if game.captureMode {
                    HStack(spacing: 10) {
                        Pill(text: captureAllowed ? L("Screen Recording: allowed") : L("Screen Recording: not allowed yet"), color: captureAllowed ? Theme.good : Theme.warn)
                        if !captureAllowed {
                            Button("Open System Settings") { NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) }.buttonStyle(SoftButton())
                        }
                    }
                    if !captureAllowed { Text("Switch MacShade on in the list, then quit and reopen MacShade.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                }
                if game.captureMode { Text(L("In the game: %@ opens ReShade, %@ switches the effects.", game.overlayKey.label, game.effectsKey.label)).font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            Card {
                Text("Uninstall game").font(.system(size: 15, weight: .bold))
                Label("Warning: this deletes the whole game, not only its entry in MacShade.", systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.bad)
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
        } message: { Text(L("The whole game will be deleted, not only removed from MacShade. These items go to the Trash:") + "\n\n" + uninstallTargets.map(\.path).joined(separator: "\n")) }
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
