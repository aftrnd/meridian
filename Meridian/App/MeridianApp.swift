import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth     = SteamAuthService()
    @State private var library       = SteamLibraryStore()
    @State private var engine        = WineEngine()
    @State private var steamManager  = WineSteamManager()
    @State private var sessionBridge = SteamSessionBridge()
    @State private var launcher      = GameLauncher()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(engine)
                .environment(steamManager)
                .environment(sessionBridge)
                .environment(launcher)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1130, height: 620)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meridian") {
                Button("Sign Out of Steam") {
                    steamAuth.signOut()
                }
                .disabled(!steamAuth.isAuthenticated)
            }
        }

        WindowGroup("Launch Log", id: "launch-log") {
            LaunchLogWindow()
                .environment(launcher)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 560, height: 320)

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(engine)
                .environment(library)
        }
    }
}
