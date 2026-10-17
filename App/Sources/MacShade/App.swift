import SwiftUI
import Sparkle

@main
struct MacShadeApp: App {
    @NSApplicationDelegateAdaptor(QuitOnClose.self) private var delegate
    @StateObject private var store = Store()
    @StateObject private var launcher = Launcher()
    private let updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
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
            ContentView().environmentObject(store).environmentObject(launcher).environmentObject(UpdateChecker(updater.updater)).frame(minWidth: 1000, minHeight: 680)
        }
        .commands { CommandGroup(after: .appInfo) { Button(L("Check for Updates …")) { updater.checkForUpdates(nil) } } }
        Settings { SettingsView(embedded: false, showPackages: {}).environmentObject(store).environmentObject(launcher).environmentObject(UpdateChecker(updater.updater)) }
    }
}

/// Closing the window quits the app (no Dock or menu bar leftovers).
final class QuitOnClose: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

/// Hands Sparkle's updater to the views (Settings has a "Check for updates" button and the automatic-check switch).
final class UpdateChecker: ObservableObject {
    let updater: SPUUpdater
    init(_ updater: SPUUpdater) { self.updater = updater }
    var automatic: Bool { get { updater.automaticallyChecksForUpdates } set { objectWillChange.send(); updater.automaticallyChecksForUpdates = newValue } }
}
