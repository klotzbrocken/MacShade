import SwiftUI
import UniformTypeIdentifiers

/// Effect packages: the list ReShade's installer offers, plus import from URL / zip / folder.
struct PackagesView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var packages: [EffectPackage] = []
    @State private var loading = true
    @State private var busy: Set<String> = []
    @State private var message: String?
    @State private var urlText = ""
    @State private var installedTick = 0   // forces refresh of install state

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("Effect packages").font(.title2.bold()); Spacer(); Button("Done") { dismiss() }.keyboardShortcut(.defaultAction) }
            Text("The same package list as the ReShade installer. Installed packages are available in all games right away (press “Reload” in the overlay, or restart the game).")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox {
                if loading { ProgressView().padding() }
                else if packages.isEmpty { Text("The package list could not be loaded (no internet connection?).").padding() }
                else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(packages) { p in row(p) }
                        }.padding(8)
                    }.frame(minHeight: 220)
                }
            }
            GroupBox("Import your own") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        TextField("URL of a .zip with shaders", text: $urlText).textFieldStyle(.roundedBorder)
                        Button("Download") { importURL() }.disabled(urlText.isEmpty)
                    }
                    HStack {
                        Button("Choose folder or ZIP …") { importLocal() }
                        Text("The folder should contain “Shaders” (and optionally “Textures”).").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Import presets (.ini) per game in the game view (“Import preset …”).").font(.caption).foregroundStyle(.secondary)
                }.padding(6)
            }
            if let message { Text(message).font(.callout) }
            HStack { Button("Show collections in Finder") { NSWorkspace.shared.open(Paths.collections) }; Spacer() }
        }
        .padding(20).frame(width: 640, height: 600)
        .task { await load() }
    }

    private func row(_ p: EffectPackage) -> some View {
        let installed = PackageManager.isInstalled(p); _ = installedTick
        return HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p.name).font(.headline)
                Text(p.summary).font(.caption).foregroundStyle(.secondary)
                if let r = p.repositoryURL { Link(r.absoluteString, destination: r).font(.caption2) }
            }
            Spacer()
            if busy.contains(p.name) { ProgressView().controlSize(.small) }
            else {
                Button(LocalizedStringKey(installed ? "Update" : "Install")) { run(p.name) { try await PackageManager.install(name: p.name, from: p.downloadURL) } }
                if installed { Button("Remove", role: .destructive) { remove(p) } }
            }
        }
    }

    private func load() async {
        loading = true
        packages = (try? await PackageManager.fetchList()) ?? []
        loading = false
    }

    private func run(_ name: String, _ work: @escaping () async throws -> Void) {
        busy.insert(name); message = nil
        Task {
            do { try await work(); message = L("“%@” was installed.", name) } catch { message = L("Error with “%@”: %@", name, "\(error)") }
            busy.remove(name); installedTick += 1
        }
    }

    private func remove(_ p: EffectPackage) {
        try? FileManager.default.removeItem(at: Paths.collections.appendingPathComponent(PackageManager.folderName(p.name)))
        installedTick += 1; message = L("“%@” was removed.", p.name)
    }

    private func importLocal() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = true
        panel.allowedContentTypes = [.folder, .zip]; panel.message = L("Choose a folder (with Shaders/Textures) or a ZIP")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run(url.deletingPathExtension().lastPathComponent) { try await PackageManager.install(name: url.deletingPathExtension().lastPathComponent, from: url) }
    }

    private func importURL() {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespaces)), url.scheme?.hasPrefix("http") == true else { message = L("Please enter a valid http(s) address."); return }
                let name = url.deletingPathExtension().lastPathComponent
        run(name) { try await PackageManager.install(name: name, from: url) }
    }
}
