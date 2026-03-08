import SwiftUI
import AppKit

@main
struct MeridianApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    @State private var steamAuth     = SteamAuthService()
    @State private var library       = SteamLibraryStore()
    @State private var vmManager     = VMManager()
    @State private var sessionBridge = SteamSessionBridge()
    @State private var launcher      = GameLauncher()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(steamAuth)
                .environment(library)
                .environment(vmManager)
                .environment(sessionBridge)
                .environment(launcher)
                .frame(minWidth: 960, minHeight: 620)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1200, height: 760)

        WindowGroup("Game", id: "game-detail", for: Int.self) { $appID in
            if let appID {
                GameDetailWindowView(appID: appID)
                    .environment(steamAuth)
                    .environment(library)
                    .environment(vmManager)
                    .environment(sessionBridge)
                    .environment(launcher)
                    .frame(minWidth: 860, minHeight: 620)
            }
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Meridian") {
                Button("Check for VM Image Update") {
                    Task { await vmManager.imageProvider.checkForUpdate() }
                }
                .keyboardShortcut("U", modifiers: [.command, .shift])

                Divider()

                Button("Sign Out of Steam") {
                    steamAuth.signOut()
                }
                .disabled(!steamAuth.isAuthenticated)
            }
        }

        Settings {
            SettingsView()
                .environment(steamAuth)
                .environment(vmManager)
        }
    }
}

struct GameDetailWindowView: View {
    let appID: Int

    @Environment(SteamLibraryStore.self) private var library
    @Environment(GameLauncher.self) private var launcher

    var body: some View {
        Group {
            if let game = library.games.first(where: { $0.id == appID }) {
                GameDetailView(game: game)
                    .environment(launcher)
            } else {
                ContentUnavailableView("Game Not Found", systemImage: "exclamationmark.triangle")
            }
        }
        .background(WindowChromeConfigurator())
    }
}

private struct WindowChromeConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.styleMask.insert(.fullSizeContentView)
            // Keep this as an anchored detail panel.
            window.isMovable = false
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}
