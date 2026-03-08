import SwiftUI

struct ContentView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(VMManager.self) private var vmManager

    @State private var launcher = GameLauncher()
    @State private var selectedGame: Game?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showProvision = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            if !steamAuth.isAuthenticated {
                AuthView()
            } else {
                mainContent
                    .task {
                        await library.refresh(steamID: steamAuth.steamID, apiKey: steamAuth.apiKey)
                    }
                    .sheet(isPresented: Binding(
                        get: { steamAuth.needsAPIKey },
                        set: { _ in }
                    )) {
                        APIKeySetupSheet()
                    }
                    .sheet(isPresented: $showProvision) {
                        VMProvisionView()
                            .environment(vmManager)
                    }
                    .onAppear {
                        if case .notProvisioned = vmManager.state { showProvision = true }
                    }
            }
        }
        .frame(minWidth: 960, minHeight: 620)
    }

    @ViewBuilder
    private var mainContent: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(selectedFilter: Binding(
                get: { library.filter },
                set: { library.filter = $0 }
            ))
            .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 220)
        } detail: {
            LibraryView(
                selectedGame: $selectedGame,
                onActivateGame: { game in
                    selectedGame = game
                    openWindow(id: "game-detail", value: game.id)
                }
            )
                .navigationSplitViewColumnWidth(min: 720, ideal: 980)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        VMStatusBarView(onSetUp: { showProvision = true })
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
        }
    }
}

// MARK: - Sidebar

private struct SidebarView: View {
    @Binding var selectedFilter: SteamLibraryStore.LibraryFilter
    @Environment(SteamAuthService.self) private var steamAuth

    var body: some View {
        List(SteamLibraryStore.LibraryFilter.allCases, selection: $selectedFilter) { filter in
            Label(filter.rawValue, systemImage: filterIcon(filter))
                .tag(filter)
        }
        .listStyle(.sidebar)
        .navigationTitle("Meridian")
        .safeAreaInset(edge: .bottom) {
            userRow
        }
    }

    private var userRow: some View {
        HStack(spacing: 10) {
            AsyncImage(url: steamAuth.avatarURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(steamAuth.displayName.isEmpty ? "Steam User" : steamAuth.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Steam ID: \(steamAuth.steamID.suffix(8))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func filterIcon(_ filter: SteamLibraryStore.LibraryFilter) -> String {
        switch filter {
        case .all:       return "square.grid.2x2"
        case .recent:    return "clock"
        case .installed: return "internaldrive"
        case .windows:   return "cpu"
        }
    }
}

#Preview {
    ContentView()
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(VMManager())
        .environment(SteamSessionBridge())
}
