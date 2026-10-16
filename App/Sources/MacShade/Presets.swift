import Foundation

/// Presets of a game live in its instance folder next to ReShade.ini; the active one is `PresetPath` in ReShade.ini.
/// `Look.ini` is the built-in default (the single-pass MacLook effect: sharp textures, bloom, better colours, vignette) and can be restored at any time.
@MainActor enum Presets {
    static let defaultName = "Look.ini"
    static let original = "ReShadePreset.ini"   // ReShade's own preset: whatever was saved from the overlay

    private static func ini(_ game: Game) -> URL { Paths.instance(for: game).appendingPathComponent("ReShade.ini") }
    static func url(_ name: String, for game: Game) -> URL { Paths.instance(for: game).appendingPathComponent(name) }

    static func list(for game: Game) -> [String] {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: Paths.instance(for: game).path)) ?? []
        return files.filter { $0.hasSuffix(".ini") && $0 != "ReShade.ini" }.sorted()
    }

    static func active(for game: Game) -> String? {
        Launcher.iniGet(ini(game), section: "GENERAL", key: "PresetPath").map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    static func activate(_ name: String, for game: Game) {
        try? FileManager.default.createDirectory(at: Paths.instance(for: game), withIntermediateDirectories: true)
        Launcher.iniSet(ini(game), section: "GENERAL", key: "PresetPath", value: url(name, for: game).path)
    }

    /// Strength of sharpening / bloom that suits the game's textures.
    private static func tuning(_ game: Game) -> (sharp: Double, bloom: Double) {
        let n = game.name.lowercased()
        if n.contains("quake") { return (0.9, 0.9) }
        if n.contains("doom") { return (1.0, 0.8) }
        if n.contains("ut") || n.contains("unreal") { return (1.4, 1.0) }
        return (1.0, 1.0)
    }

    /// Writes the built-in default preset (only when missing, unless `overwrite`).
    static func writeDefault(for game: Game, overwrite: Bool = false) {
        try? FileManager.default.createDirectory(at: Paths.instance(for: game), withIntermediateDirectories: true)
        seedBundled(for: game, overwrite: overwrite)
        let target = url(defaultName, for: game)
        // older versions wrote a preset with four separate effects (the qUINT bloom alone cost ~5 ms per frame): replace it by the single-pass MacLook
        let outdated = ((try? String(contentsOf: target, encoding: .utf8)) ?? "").contains("qUINT_bloom")
        if !overwrite && !outdated && FileManager.default.fileExists(atPath: target.path) { return }
        let t = tuning(game)
        let text = """
        Techniques=MacLook@MacLook.fx
        TechniqueSorting=MacLook@MacLook.fx

        [MacLook.fx]
        SharpStrength=\(String(format: "%.6f", t.sharp))
        BloomIntensity=\(String(format: "%.6f", t.bloom))
        Vibrance=0.250000
        VignetteAmount=0.400000

        """
        try? FileManager.default.createDirectory(at: Paths.instance(for: game), withIntermediateDirectories: true)
        try? text.write(to: target, atomically: true, encoding: .utf8)
    }

    /// Rewrites the default preset and makes it the active one.
    static func restoreDefault(for game: Game) { writeDefault(for: game, overwrite: true); activate(defaultName, for: game) }

    /// Back to the state of a fresh install: deletes every preset (imported ones too), then restores the default preset.
    static func resetAll(for game: Game) {
        for name in list(for: game) { try? FileManager.default.removeItem(at: url(name, for: game)) }
        restoreDefault(for: game)
    }

    // MARK: presets shipped with the app (Resources/Presets/<game name>/*.ini, e.g. the converted "UT2004 Reshade v.2" by RealDeal!)

    private static func bundledFiles(for game: Game) -> [URL] {
        guard let root = Bundle.main.resourceURL?.appendingPathComponent("Presets") else { return [] }
        let fm = FileManager.default
        let folders = ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 == "_all" || game.name.lowercased().contains($0.lowercased()) }   // "_all": for every game
        return folders.flatMap { f in ((try? fm.contentsOfDirectory(at: root.appendingPathComponent(f), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "ini" } }
    }
    static func bundledNames(for game: Game) -> Set<String> { Set(bundledFiles(for: game).map(\.lastPathComponent)) }

    private static func seedBundled(for game: Game, overwrite: Bool) {
        let fm = FileManager.default
        for src in bundledFiles(for: game) {
            let dst = url(src.lastPathComponent, for: game)
            if fm.fileExists(atPath: dst.path) { if !overwrite { continue }; try? fm.removeItem(at: dst) }
            try? fm.copyItem(at: src, to: dst)
        }
    }

    /// Removes a preset (not the default one); falls back to the default preset when it was the active one.
    static func delete(_ name: String, for game: Game) {
        guard name != defaultName else { return }
        try? FileManager.default.removeItem(at: url(name, for: game))
        if active(for: game) == name { activate(defaultName, for: game) }
    }

    /// Effect names a preset switches on (the "Techniques=" line, without the "@file.fx" part).
    static func effects(_ name: String, for game: Game) -> [String] {
        guard let text = try? String(contentsOf: url(name, for: game), encoding: .utf8),
              let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("Techniques=") }) else { return [] }
        return line.dropFirst("Techniques=".count).split(separator: ",").map { String($0.split(separator: "@")[0]).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// What a preset does, in plain words: (filter with its strength, what it does). MacLook is split into its four parts.
    static func explain(_ name: String, for game: Game) -> [(title: String, detail: String)] {
        guard let text = try? String(contentsOf: url(name, for: game), encoding: .utf8) else { return [] }
        var values: [String: Double] = [:], section = ""
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") { section = line; continue }
            if section == "[MacLook.fx]", let eq = line.firstIndex(of: "="), let v = Double(line[line.index(after: eq)...]) { values[String(line[..<eq])] = v }
        }
        var out: [(String, String)] = []
        for effect in effects(name, for: game) {
            switch effect {
            case "MacLook":
                func v(_ k: String, _ d: Double) -> Double { values[k] ?? d }
                func f(_ x: Double) -> String { String(format: "%.1f", x) }
                if v("SharpStrength", 1) > 0.01 { out.append((L("Sharpening %@", f(v("SharpStrength", 1))), L("Crisper textures"))) }
                if v("BloomIntensity", 0.8) > 0.01 { out.append((L("Bloom %@", f(v("BloomIntensity", 0.8))), L("Soft glow around bright areas"))) }
                let vib = v("Vibrance", 0.25)
                if abs(vib) > 0.01 { out.append((L("Vibrance %@", f(vib)), vib > 0 ? L("Richer, more natural colours") : L("Muted, grittier colours"))) }
                if v("VignetteAmount", 0.4) > 0.01 { out.append((L("Vignette %@", f(v("VignetteAmount", 0.4))), L("Darker screen edges"))) }
            case "ContrastAdaptiveSharpen": out.append(("CAS", L("Crisper textures")))
            case "Vibrance": out.append(("Vibrance", L("Richer, more natural colours")))
            case "Bloom": out.append(("Bloom", L("Soft glow around bright areas")))
            case "AdvancedCRT": out.append(("CRT", L("Old monitor look: scanlines and curved screen")))
            case "Tint": out.append(("Tint", L("Warm or cool colour cast")))
            case "FilmGrain": out.append(("FilmGrain", L("Fine film grain")))
            case "Smart_Sharp": out.append(("Smart Sharp", L("Sharpens edges without halos")))
            case "prod80_04_ContrastBrightnessSaturation": out.append((L("Contrast & colour"), L("More contrast, saturation and vibrance")))
            case "prod80_02_Bloom": out.append(("Bloom", L("Realistic glow around bright areas")))
            case "Tonemap": out.append(("Tonemap", L("Gamma, saturation and a touch of bleach")))
            case "Curves": out.append(("Curves", L("Contrast S-curve")))
            case "LumaSharpen": out.append(("LumaSharpen", L("Sharpens textures")))
            case "FXAA": out.append(("FXAA", L("Smooths jagged edges")))
            case "Technicolor": out.append(("Technicolor", L("Film colour grade")))
            case "DPX": out.append(("DPX", L("Film contrast and colour")))
            case "HDR": out.append(("HDR", L("Brighter highlights, deeper shadows")))
            case "AmbientLight": out.append(("AmbientLight", L("Soft ambient glow")))
            case "Colourfulness": out.append(("Colourfulness", L("Stronger colours")))
            case "Clarity": out.append(("Clarity", L("Local contrast")))
            default: out.append((effect, ""))
            }
        }
        return out
    }

    static func displayName(_ file: String) -> String {
        let base = String(file.dropLast(4))
        return file == defaultName ? L("%@ (default)", base) : base
    }
}
