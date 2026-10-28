import SwiftUI

/// The effects (ReShade "techniques") the shader collections offer, read from the `.fx` files.
enum TechniqueCatalog {
    struct Item: Identifiable, Hashable {
        let name: String, file: String
        var id: String { name + "@" + file }
    }

    /// Scans `Shaders` folders for `technique <Name>`; slow-ish (hundreds of files), so call it off the main thread.
    nonisolated static func scan(_ shaderDirs: [URL]) -> [Item] {
        let fm = FileManager.default
        guard let regex = try? NSRegularExpression(pattern: #"^\s*technique\s+([A-Za-z_][A-Za-z0-9_]*)"#, options: [.anchorsMatchLines]) else { return [] }
        var seen = Set<String>(), items: [Item] = []
        for dir in shaderDirs {
            guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in en where url.pathExtension == "fx" {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                let ns = text as NSString
                for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    let item = Item(name: ns.substring(with: m.range(at: 1)), file: url.lastPathComponent)
                    if seen.insert(item.id).inserted { items.append(item) }
                }
            }
        }
        return items.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}

extension Presets {
    /// "Name@File.fx" ids a preset switches on, in the order of its `Techniques=` line.
    static func techniqueIDs(_ name: String, for game: Game) -> [String] {
        guard let text = try? String(contentsOf: url(name, for: game), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Techniques=") }) else { return [] }
        return line.dropFirst("Techniques=".count).split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// Replaces the `Techniques=` line (the rest of the preset, e.g. the effect settings, stays) and makes sure the sorting line knows the new effects.
    static func setTechniques(_ ids: [String], in name: String, for game: Game) {
        let target = url(name, for: game)
        var lines = ((try? String(contentsOf: target, encoding: .utf8)) ?? "").components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        let value = ids.joined(separator: ",")
        if let i = lines.firstIndex(where: { $0.hasPrefix("Techniques=") }) { lines[i] = "Techniques=" + value } else { lines.insert("Techniques=" + value, at: 0) }
        if let i = lines.firstIndex(where: { $0.hasPrefix("TechniqueSorting=") }) {
            var sorting = lines[i].dropFirst("TechniqueSorting=".count).split(separator: ",").map(String.init)
            for id in ids where !sorting.contains(id) { sorting.append(id) }
            lines[i] = "TechniqueSorting=" + sorting.joined(separator: ",")
        } else if let i = lines.firstIndex(where: { $0.hasPrefix("Techniques=") }) { lines.insert("TechniqueSorting=" + value, at: i + 1) }
        try? (lines.joined(separator: "\n") + "\n").write(to: target, atomically: true, encoding: .utf8)
    }

    /// A file name from what the user typed (no path characters), or nil when nothing usable is left.
    static func fileName(from typed: String) -> String? {
        let bad = CharacterSet(charactersIn: "/:\\\n\r\t")
        var base = typed.components(separatedBy: bad).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        if base.lowercased().hasSuffix(".ini") { base = String(base.dropLast(4)).trimmingCharacters(in: .whitespaces) }
        guard !base.isEmpty, !base.hasPrefix("."), base.count <= 60, base.lowercased() != "reshade" else { return nil }
        return base + ".ini"
    }

    /// Gives an own look a new name. Returns an error text, or nil when it worked.
    static func rename(_ name: String, to typed: String, for game: Game) -> String? {
        guard let new = fileName(from: typed) else { return L("Please type a name for the look.") }
        guard new != name else { return nil }
        guard !FileManager.default.fileExists(atPath: url(new, for: game).path) else { return L("A look with this name already exists.") }
        do { try FileManager.default.moveItem(at: url(name, for: game), to: url(new, for: game)) } catch { return error.localizedDescription }
        if active(for: game) == name { activate(new, for: game) }
        return nil
    }

    /// Saves a copy of a look under a new name and makes it the active one. Returns an error text, or nil when it worked.
    static func duplicate(_ name: String, as typed: String, for game: Game) -> String? {
        guard let new = fileName(from: typed) else { return L("Please type a name for the look.") }
        guard !FileManager.default.fileExists(atPath: url(new, for: game).path) else { return L("A look with this name already exists.") }
        do { try FileManager.default.copyItem(at: url(name, for: game), to: url(new, for: game)) } catch { return error.localizedDescription }
        activate(new, for: game)
        return nil
    }
}

/// One look in the list: name, a checkbox that makes it the (only) active look, and a Details button with the effects, the name and the shader choice.
struct LookCard: View {
    let game: Game
    let name: String
    let isActive: Bool
    let kind: String          // Default / Included / Own
    let locked: Bool          // the game is running
    @Binding var expanded: String?
    let onSelect: () -> Void
    let onChange: (String) -> Void   // message; the list is read again

    @State private var typedName = ""
    @State private var ids: [String] = []
    @State private var catalog: [TechniqueCatalog.Item] = []
    @State private var search = ""
    @State private var adding = false
    @State private var error: String?

    private var open: Bool { expanded == name }
    private var own: Bool { kind == L("Own") }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Toggle("", isOn: Binding(get: { isActive }, set: { if $0 { onSelect() } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(locked).help(L("Activate look"))
                Text(Presets.displayName(name)).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(kind).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(isActive ? Theme.accent : Theme.muted)
                Spacer()
                Button { expanded = open ? nil : name } label: {
                    HStack(spacing: 5) { Text(open ? L("Hide details") : L("Details")); Image(systemName: open ? "chevron.up" : "chevron.down").font(.system(size: 10, weight: .bold)) }
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(open ? Theme.accent : Theme.muted)
                }.buttonStyle(.plain)
            }
            if open { details.padding(.leading, 30) }
        }
        .padding(.horizontal, 16).padding(.vertical, 13).frame(maxWidth: .infinity, alignment: .leading)
        .background(isActive ? Theme.accent.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        .task(id: open) { if open { typedName = String(name.dropLast(4)); ids = Presets.techniqueIDs(name, for: game); await loadCatalog() } }
    }

    private func loadCatalog() async {
        guard catalog.isEmpty else { return }
        let dirs = Paths.collectionDirs().map { $0.appendingPathComponent("Shaders") }
        catalog = await Task.detached { TechniqueCatalog.scan(dirs) }.value
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 16) {
            let parts = Presets.explain(name, for: game)
            if !parts.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                        (Text(part.title).fontWeight(.semibold).foregroundColor(Theme.text) + Text(part.detail.isEmpty ? "" : " · " + part.detail).foregroundColor(Theme.muted))
                            .font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Look name").font(.system(size: 13, weight: .bold))
                HStack(spacing: 8) {
                    TextField("", text: $typedName).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                    if own { Button("Rename") { finish(Presets.rename(name, to: typedName, for: game), L("Look renamed.")) }.buttonStyle(SoftButton()) }
                    Button("Save as new look") { finish(Presets.duplicate(name, as: typedName, for: game), L("Look saved and selected.")) }.buttonStyle(SoftButton())
                }.disabled(locked)
                if !own { Text("The default and included looks keep their name; save a copy to change it.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Shaders in this look").font(.system(size: 13, weight: .bold))
                if ids.isEmpty { Text("No shader selected: the game stays as it is.").font(.system(size: 12)).foregroundStyle(Theme.muted) }
                Flow(spacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        HStack(spacing: 6) {
                            Text(id.split(separator: "@").first.map(String.init) ?? id).font(.system(size: 12.5, weight: .semibold))
                            Button { ids.removeAll { $0 == id }; save() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Theme.muted).help(L("Remove"))
                        }.padding(.horizontal, 10).padding(.vertical, 5).background(Theme.raised, in: Capsule())
                    }
                    Button { adding = true } label: { Label("Add shader …", systemImage: "plus") }.buttonStyle(SoftButton())
                        .popover(isPresented: $adding, arrowEdge: .bottom) { picker }
                }.disabled(locked)
                Text("Effects further down the list are applied after the ones above. In the game you can still change every setting live.").font(.system(size: 12)).foregroundStyle(Theme.muted)
            }
            if let error { Text(error).font(.caption).foregroundStyle(Theme.bad) }
        }
    }

    private var picker: some View {
        let free = catalog.filter { !ids.contains($0.id) && (search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.file.localizedCaseInsensitiveContains(search)) }
        return VStack(alignment: .leading, spacing: 8) {
            TextField(L("Search shaders"), text: $search).textFieldStyle(.roundedBorder)
            if catalog.isEmpty { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(free.prefix(120)) { item in
                        Button { ids.append(item.id); save(); adding = false } label: {
                            HStack { Text(item.name).font(.system(size: 13, weight: .semibold)); Spacer(); Text(item.file).font(.system(size: 11.5)).foregroundStyle(Theme.muted) }
                                .padding(.vertical, 4).padding(.horizontal, 6).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                    if free.count > 120 { Text(L("%d more: refine the search", free.count - 120)).font(.system(size: 12)).foregroundStyle(Theme.muted).padding(6) }
                }
            }.frame(height: 280)
        }.padding(12).frame(width: 360)
    }

    private func save() { Presets.setTechniques(ids, in: name, for: game); error = nil; onChange(L("Shaders updated.")) }

    private func finish(_ failure: String?, _ message: String) {
        if let failure { error = failure } else { error = nil; expanded = nil; onChange(message) }
    }
}
