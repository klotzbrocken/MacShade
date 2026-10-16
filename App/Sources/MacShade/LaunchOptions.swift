import AppKit
import SwiftUI

/// A ready-made start parameter for a game. `verified`: the option really occurs in the game's program (checked with `strings`); the others are common for the engine.
struct LaunchSuggestion: Identifiable {
    enum Kind { case plain, folder(flag: String), file(flag: String) }
    var id: String { title }
    var title: String
    var arguments = ""
    var kind = Kind.plain
    var prepend = false     // must be the first argument (e.g. an Unreal map URL)
    var verified = true
}

enum LaunchOptions {
    /// Suggestions for the games MacShade knows, by engine; matched on the game's name.
    static func suggestions(for game: Game) -> [LaunchSuggestion] {
        let n = game.name.lowercased()
        if n.contains("vkquake") || (n.contains("quake") && !n.contains("quake 2") && !n.contains("quake ii") && !n.contains("quake 3")) {
            return [
                .init(title: "Game data folder …", kind: .folder(flag: "-basedir")),
                .init(title: "Windowed", arguments: "-window"),
                .init(title: "Fullscreen", arguments: "-fullscreen"),
                .init(title: "Resolution 1920×1080", arguments: "-width 1920 -height 1080"),
                .init(title: "Resolution 2560×1440", arguments: "-width 2560 -height 1440"),
                .init(title: "No sound", arguments: "-nosound"),
                .init(title: "No gamepad", arguments: "-nojoy"),
                .init(title: "Write console log to a file", arguments: "-condebug"),
                .init(title: "Start map E1M1", arguments: "+map e1m1", verified: false),
            ]
        }
        if n.contains("doom") || n.contains("raze") {
            return [
                .init(title: "IWAD file …", kind: .file(flag: "-iwad")),
                .init(title: "Add a mod file …", kind: .file(flag: "-file")),
                .init(title: "Resolution 1920×1080", arguments: "-width 1920 -height 1080"),
                .init(title: "Start on map 1", arguments: "-warp 1"),
                .init(title: "Skill level 3", arguments: "-skill 3"),
                .init(title: "No monsters", arguments: "-nomonsters"),
                .init(title: "No sound", arguments: "-nosound"),
                .init(title: "No music", arguments: "-nomusic"),
            ]
        }
        if n.contains("yamagi") || n.contains("quake ii") || n.contains("quake 2") {
            return [
                .init(title: "Colosseum deathmatch with bots (q2dm1)", arguments: "+set game colosseum +set maxclients 32 +exec configs/dm.cfg +map q2dm1"),
                .init(title: "OpenGL 1.x renderer", arguments: "+set vid_renderer gl1"),
                .init(title: "Windowed", arguments: "+set vid_fullscreen 0"),
                .init(title: "Fullscreen", arguments: "+set vid_fullscreen 1"),
                .init(title: "Window 1280×800", arguments: "+set r_mode -1 +set r_customwidth 1280 +set r_customheight 800"),
                .init(title: "Game data folder …", kind: .folder(flag: "-datadir")),
                .init(title: "Capture the flag with bots (q2ctf1)", arguments: "+set game colosseum +set maxclients 32 +exec configs/ctf.cfg +map q2ctf1", verified: false),
            ]
        }
        if n.contains("quetoo") {
            return [
                .init(title: "Windowed", arguments: "+set r_fullscreen 0"),
                .init(title: "Fullscreen", arguments: "+set r_fullscreen 1"),
                .init(title: "Window 1920×1080", arguments: "+set r_windowWidth 1920 +set r_windowHeight 1080"),
                .init(title: "Without vsync", arguments: "+set r_swapInterval 0"),
                .init(title: "Anisotropic filtering 16×", arguments: "+set r_anisotropy 16"),
                .init(title: "Sound off", arguments: "+set s_volume 0"),
            ]
        }
        if n.contains("ut2004") {
            return [
                .init(title: "Start a deathmatch with bots (Rankin)", arguments: "DM-Rankin?Game=XGame.xDeathMatch?numbots=6", prepend: true),
                .init(title: "No sound", arguments: "-nosound", verified: false),
            ]
        }
        if n.contains("unreal") || n.contains("ut99") || n == "ut" {
            return [
                .init(title: "Start a deathmatch with bots (Deck16)", arguments: "DM-Deck16][?game=Botpack.DeathMatchPlus?numbots=6", prepend: true, verified: false),
                .init(title: "Skip intro video", arguments: "-nointro", verified: false),
                .init(title: "No sound", arguments: "-nosound", verified: false),
            ]
        }
        return []
    }

    /// Splits like the launcher does, and joins again with quotes where needed.
    static func join(_ tokens: [String]) -> String { tokens.map { $0.contains(" ") || $0.contains("][") ? "\"\($0)\"" : $0 }.joined(separator: " ") }

    /// Adds `arguments` (replacing a value-taking flag that is already there, ignoring exact duplicates).
    static func adding(_ suggestion: LaunchSuggestion, value: String? = nil, to current: String) -> String {
        var tokens = splitArguments(current)
        var new = splitArguments(suggestion.arguments)
        switch suggestion.kind {
        case .folder(let flag), .file(let flag):
            guard let value else { return current }
            if let i = tokens.firstIndex(of: flag) { tokens.remove(at: i); if i < tokens.count { tokens.remove(at: i) } }
            new = [flag, value]
        case .plain:
            // the same flags again would only repeat what is there; a flag with a value (+set name value) replaces the old value
            if new.first == "+set", new.count >= 3, let i = tokens.indices.first(where: { tokens[$0] == "+set" && $0 + 1 < tokens.count && tokens[$0 + 1] == new[1] }) { tokens.removeSubrange(i...min(i + 2, tokens.count - 1)) }
            else if new.count == 1, tokens.contains(new[0]) { return current }
            else if new.first == "-width" || new.first == "-height" { removeFlag("-width", in: &tokens); removeFlag("-height", in: &tokens) }
        }
        tokens = suggestion.prepend ? new + tokens : tokens + new
        return join(tokens)
    }

    private static func removeFlag(_ flag: String, in tokens: inout [String]) {
        if let i = tokens.firstIndex(of: flag) { tokens.remove(at: i); if i < tokens.count { tokens.remove(at: i) } }
    }
}

/// "Start parameters" box: the argument line, suggestions for this game, and pickers that insert a real path.
struct LaunchOptionsBox: View {
    @Binding var game: Game

    var body: some View {
        let all = LaunchOptions.suggestions(for: game)
        VStack(alignment: .leading, spacing: 20) {
            SectionTitle("Start parameters", "Passed to the game at every start. A map URL (Unreal games) has to come first; the suggestions take care of that.")
            Card {
                Text("PARAMETERS").font(.system(size: 12, weight: .bold)).tracking(0.8).foregroundStyle(Theme.muted)
                TextField("Parameters for the game (e.g. -basedir \"/path/to/data\")", text: $game.arguments)
                    .textFieldStyle(.plain).font(.system(size: 14, design: .monospaced)).padding(12)
                    .background(Theme.bg, in: RoundedRectangle(cornerRadius: 10)).overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
                Flow {
                    Button("Insert folder …") { insertPath(directories: true) }.buttonStyle(SoftButton())
                    Button("Insert file …") { insertPath(directories: false) }.buttonStyle(SoftButton())
                    Button("Clear") { game.arguments = "" }.buttonStyle(SoftButton()).disabled(game.arguments.isEmpty)
                }
            }
            if all.isEmpty {
                Text("No suggestions for this game yet.").font(.system(size: 13)).foregroundStyle(Theme.muted)
            } else {
                let checked = all.filter(\.verified), other = all.filter { !$0.verified }
                VStack(alignment: .leading, spacing: 10) {
                    Text("FOUND IN THE GAME'S PROGRAM").font(.system(size: 12, weight: .bold)).tracking(0.8).foregroundStyle(Theme.good)
                    Flow { ForEach(checked) { chip($0, verified: true) } }
                    if !other.isEmpty {
                        Text("COMMON FOR THIS ENGINE (NOT CHECKED)").font(.system(size: 12, weight: .bold)).tracking(0.8).foregroundStyle(Theme.muted).padding(.top, 8)
                        Flow { ForEach(other) { chip($0, verified: false) } }
                    }
                }
            }
        }
    }

    private func chip(_ item: LaunchSuggestion, verified: Bool) -> some View {
        Button { apply(item) } label: {
            HStack(spacing: 6) {
                if verified { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(Theme.good) }
                Text(LocalizedStringKey(item.title)).font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 12).padding(.vertical, 8).background(Theme.card, in: Capsule()).overlay(Capsule().stroke(Theme.lineStrong))
        }.buttonStyle(.plain)
    }

    private func apply(_ item: LaunchSuggestion) {
        switch item.kind {
        case .plain: game.arguments = LaunchOptions.adding(item, to: game.arguments)
        case .folder, .file:
            let panel = NSOpenPanel()
            if case .folder = item.kind { panel.canChooseDirectories = true; panel.canChooseFiles = false } else { panel.canChooseDirectories = false; panel.canChooseFiles = true }
            panel.message = L(item.title)
            if panel.runModal() == .OK, let url = panel.url { game.arguments = LaunchOptions.adding(item, value: url.path, to: game.arguments) }
        }
    }

    private func insertPath(directories: Bool) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = directories; panel.canChooseFiles = !directories
        if panel.runModal() == .OK, let url = panel.url { game.arguments = LaunchOptions.join(splitArguments(game.arguments) + [url.path]) }
    }
}
