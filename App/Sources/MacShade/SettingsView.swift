import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

/// App-wide settings (⌘,).
struct SettingsView: View {
    var embedded = true
    var showPackages: () -> Void = {}
    @State private var keys = GlobalKeys.load()
    @EnvironmentObject var updates: UpdateChecker
    @State private var keysApplied = false
    @State private var importMessage: String?
    @State private var importing = false
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    @State private var language = (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { code in appLanguages.first { code.hasPrefix($0.code) }?.code } ?? "auto"
    @State private var languageChanged = false
    @EnvironmentObject var store: Store
    @EnvironmentObject var launcher: Launcher
    @State private var copiesFolder = Paths.copies.path
    @State private var copiesUsage: Int64 = 0
    @State private var moving = false
    @State private var confirmDeleteAll = false
    private var anyRunning: Bool { store.games.contains { launcher.isBusy($0.id) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Settings").font(.system(size: 30, weight: .heavy))

            Card {
                HStack {
                    Text("Language").font(.system(size: 15, weight: .bold)); Spacer()
                    Picker("", selection: $language) {
                        Text("Automatic (system)").tag("auto")
                        ForEach(appLanguages, id: \.code) { Text($0.name).tag($0.code) }
                    }.labelsHidden().frame(width: 220)
                }
                .onChange(of: language) { code in
                    if code == "auto" { UserDefaults.standard.removeObject(forKey: "AppleLanguages") } else { UserDefaults.standard.set([code], forKey: "AppleLanguages") }
                    languageChanged = true
                }
                if languageChanged { Text("Takes effect after restarting MacShade.").font(.caption).foregroundStyle(Theme.muted) }
                Divider().overlay(Theme.line)
                Toggle("Start MacShade automatically at login", isOn: $launchAtLogin).toggleStyle(.switch).tint(Theme.accent)
                    .onChange(of: launchAtLogin) { enabled in
                        do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }; message = nil }
                        catch { message = L("Could not change autostart: %@", error.localizedDescription); launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                if SMAppService.mainApp.status == .requiresApproval { Text("Please allow it in System Settings under “Login Items”.").font(.caption).foregroundStyle(Theme.warn) }
                if let message { Text(message).font(.caption).foregroundStyle(Theme.bad) }
                Text("Individual games can also start automatically when the app opens (in the game view).").font(.caption).foregroundStyle(Theme.muted)
            }

            Card {
                Text("Hotkeys for all games").font(.system(size: 15, weight: .bold))
                Text("These keys are used for new games. “Apply to all games” sets them in every game of your list.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                KeyRecorder(title: "Open overlay", binding: $keys.overlay)
                KeyRecorder(title: "Screenshot", binding: $keys.screenshot)
                KeyRecorder(title: "Effects on/off", binding: $keys.effects)
                HStack {
                    Button("Apply to all games") {
                        for i in store.games.indices { store.games[i].overlayKey = keys.overlay; store.games[i].screenshotKey = keys.screenshot; store.games[i].effectsKey = keys.effects }
                        keysApplied = true
                    }.buttonStyle(SoftButton(tint: Theme.accent))
                    Button("Reset keys") { keys = GlobalKeys.Set(); keysApplied = false }.buttonStyle(SoftButton())
                    if keysApplied { Text("Applied to all games. Takes effect at the next start.").font(.caption).foregroundStyle(Theme.good) }
                }
            }
            .onChange(of: keys) { GlobalKeys.save($0) }

            Card {
                Text("Updates").font(.system(size: 15, weight: .bold))
                Text(L("Version %@", (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "?")).font(.system(size: 13)).foregroundStyle(Theme.muted)
                Toggle("Check for updates automatically", isOn: Binding(get: { updates.automatic }, set: { updates.automatic = $0 })).toggleStyle(.switch).tint(Theme.accent)
                Button("Check for updates now") { updates.updater.checkForUpdates() }.buttonStyle(SoftButton(tint: Theme.accent))
            }

            Card {
                Text("Shaders and effects").font(.system(size: 15, weight: .bold))
                Text("Import your own effects: a folder or ZIP that contains “Shaders” (and optionally “Textures”). They are available in all games right away.").font(.system(size: 13)).foregroundStyle(Theme.muted)
                Flow {
                    Button("Import shaders …") { importShaders() }.buttonStyle(SoftButton(tint: Theme.accent)).disabled(importing)
                    Button("Effect packages") { showPackages() }.buttonStyle(SoftButton())
                    Button("Show collections in Finder") { NSWorkspace.shared.open(Paths.collections) }.buttonStyle(SoftButton())
                }
                if importing { ProgressView().controlSize(.small) }
                if let importMessage { Text(importMessage).font(.caption).foregroundStyle(Theme.muted) }
            }

            Card {
                Text("Game copies").font(.system(size: 15, weight: .bold))
                Text(copiesFolder).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.muted).lineLimit(2).truncationMode(.middle)
                Flow {
                    Button("Choose folder …") { chooseFolder() }.buttonStyle(SoftButton()).disabled(moving || anyRunning)
                    Button("Use default") { move(to: Paths.defaultCopies) }.buttonStyle(SoftButton()).disabled(moving || anyRunning || !Paths.usesCustomCopies)
                    Button("Delete all copies …", role: .destructive) { confirmDeleteAll = true }.buttonStyle(SoftButton(tint: Theme.bad)).disabled(moving || anyRunning || copiesUsage == 0)
                    if moving { ProgressView().controlSize(.small); Text("Moving …").font(.caption) }
                }
                Text(L("Uses %@", ByteCountFormatter.string(fromByteCount: copiesUsage, countStyle: .file))).font(.system(size: 13, weight: .semibold))
                Text("Each game is copied and signed once so that ReShade can be loaded. The copies can be deleted at any time; they are made again at the next start. They can also live on an external drive (slower start, normal speed in the game).").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .padding(embedded ? 36 : 24).frame(maxWidth: embedded ? 860 : 620, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg).foregroundStyle(Theme.text).preferredColorScheme(.dark)
        .task { await refreshUsage() }
        .confirmationDialog(L("Delete all game copies?"), isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("Delete", role: .destructive) { Paths.deleteAllCopies(); Task { await refreshUsage() } }
        } message: { Text("They are made again when you start a game. Your games and settings are not touched.") }
    }

    private func importShaders() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]; panel.message = L("Choose a folder (with Shaders/Textures) or a ZIP")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let name = url.deletingPathExtension().lastPathComponent
        importing = true; importMessage = nil
        Task {
            do { try await PackageManager.install(name: name, from: url); importMessage = L("“%@” was installed.", name) }
            catch { importMessage = L("Error with “%@”: %@", name, "\(error)") }
            importing = false
        }
    }

    private func refreshUsage() async {
        let url = Paths.copies
        copiesUsage = await Task.detached { Paths.diskUsage(url) }.value
    }

    private func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.message = L("Choose a folder for the game copies")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        move(to: url.appendingPathComponent("MacShade Games"))
    }

    /// Moves the copies to `new` (may take a while on an external drive) and uses it from then on.
    private func move(to new: URL) {
        let old = Paths.copies
        guard old.path != new.path else { return }
        moving = true; message = nil
        Task {
            do {
                try await Task.detached { try Paths.moveCopies(from: old, to: new) }.value
                if new.path == Paths.defaultCopies.path { UserDefaults.standard.removeObject(forKey: "copiesFolder") } else { UserDefaults.standard.set(new.path, forKey: "copiesFolder") }
                copiesFolder = Paths.copies.path
            } catch { message = L("Could not move the copies: %@", error.localizedDescription) }
            moving = false; await refreshUsage()
        }
    }
}
