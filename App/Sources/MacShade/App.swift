import SwiftUI

@main
struct MacShadeApp: App {
    @NSApplicationDelegateAdaptor(QuitOnClose.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var launcher = Launcher()
    init() {
        // settings of the former bundle "local.reshademac" (language, copies folder, default keys), taken over once
        let d = UserDefaults.standard
        if d.object(forKey: "migratedFromReShadeMac") == nil, let old = UserDefaults(suiteName: "local.reshademac") {
            for k in ["copiesFolder", "AppleLanguages", "globalKeys"] where d.object(forKey: k) == nil { if let v = old.object(forKey: k) { d.set(v, forKey: k) } }
            d.set(true, forKey: "migratedFromReShadeMac")
        }
    }
    var body: some Scene {
        WindowGroup("MacShade") {
            ContentView().environmentObject(store).environmentObject(launcher).frame(minWidth: 1000, minHeight: 680)
        }
        Settings { SettingsView(embedded: false, showPackages: {}).environmentObject(store).environmentObject(launcher) }
    }
}

/// Closing the window quits the app (no Dock or menu bar leftovers).
final class QuitOnClose: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
