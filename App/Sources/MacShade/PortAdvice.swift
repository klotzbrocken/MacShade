import Foundation

/// A better-suited port of a game that MacShade knows about (shown for games that were found or added).
struct PortSuggestion {
    let name: String
    let why: String
    let url: URL
}

enum PortAdvice {
    /// Ports that already are what we would recommend: no suggestion for those.
    private static let ports = ["vkquake", "yamagi", "uzdoom", "gzdoom", "zdoom", "ioquake3", "quetoo", "raze", "oldunreal", "darkplaces", "quakespasm"]

    static func better(for name: String) -> PortSuggestion? {
        let n = name.lowercased()
        if ports.contains(where: n.contains) { return nil }
        if n.contains("quake ii") || n.contains("quake 2") || n == "quake2" {
            return PortSuggestion(name: "Yamagi Quake II", why: L("Native Quake II port with OpenGL and Vulkan renderers and mod support (bots too)."), url: URL(string: "https://www.yamagi.org/quake2/")!)
        }
        if n.contains("quake iii") || n.contains("quake 3") { return PortSuggestion(name: "ioquake3", why: L("Open-source Quake III Arena engine for the Mac."), url: URL(string: "https://ioquake3.org")!) }
        if n.contains("quake") { return PortSuggestion(name: "vkQuake", why: L("Vulkan-based Quake port for Apple Silicon; works directly with MacShade."), url: URL(string: "https://github.com/Novum/vkQuake")!) }
        if n.contains("doom") { return PortSuggestion(name: "UZDoom", why: L("Modern Doom engine with Vulkan; works directly with MacShade."), url: URL(string: "https://github.com/UZDoom/UZDoom")!) }
        if n.contains("unreal tournament") && !n.contains("2004") && !n.contains("3") || n == "ut99" {
            return PortSuggestion(name: "OldUnreal UT99 patch", why: L("Community patch that keeps Unreal Tournament 99 running on modern systems."), url: URL(string: "https://github.com/OldUnreal/UnrealTournamentPatches")!)
        }
        return nil
    }

    /// Games that are known not to work: they refuse to run as a copy and relaunch themselves through their launcher.
    static func incompatible(_ name: String) -> String? {
        let n = name.lowercased()
        if n.contains("sims 4") { return L("Runs only through its own launcher (EA app) and refuses a modified copy, so MacShade cannot load ReShade into it.") }
        return nil
    }
}
