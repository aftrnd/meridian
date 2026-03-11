import SwiftUI

struct ContentView: View {
    @Environment(SteamAuthService.self) private var steamAuth
    @Environment(SteamLibraryStore.self) private var library
    @Environment(WineEngine.self) private var engine

    @State private var selectedGame: Game?
    @State private var columnVisibility = NavigationSplitViewVisibility.all
    @State private var showEngineSetup = false

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
                    .sheet(isPresented: $showEngineSetup) {
                        EngineSetupView()
                            .environment(engine)
                    }
                    .sheet(item: $selectedGame) { game in
                        GameDetailView(game: game) {
                            selectedGame = nil
                        }
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
            LibraryView(selectedGame: $selectedGame)
                .navigationSplitViewColumnWidth(min: 720, ideal: 980)
                .safeAreaInset(edge: .bottom) {
                    HStack {
                        Spacer()
                        EngineStatusPill(onSetUp: { showEngineSetup = true })
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
            profileRow
        }
    }

    private var profileRow: some View {
        HStack(spacing: 10) {
            AsyncImage(url: steamAuth.avatarURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 28, height: 28)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text(steamAuth.displayName.isEmpty ? "Steam User" : steamAuth.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Text("Steam")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func filterIcon(_ filter: SteamLibraryStore.LibraryFilter) -> String {
        switch filter {
        case .all:       return "square.grid.2x2"
        case .recent:    return "clock"
        case .installed: return "internaldrive"
        case .favorites: return "heart.fill"
        }
    }
}

// MARK: - Engine Status Pill

private struct EngineStatusPill: View {
    @Environment(WineEngine.self) private var engine
    var onSetUp: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dotColor)
                .frame(width: 7, height: 7)
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(.secondary)

            if !engine.isReady {
                Button("Set Up…") { onSetUp?() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.tint)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
    }

    private var dotColor: Color {
        switch engine.state {
        case .ready:          return .green
        case .notInstalled:   return .gray
        case .error:          return .red
        }
    }

    private var statusLabel: String {
        switch engine.state {
        case .ready:          return "Engine: \(engine.backendName)"
        case .notInstalled:   return "Engine Not Found"
        case .error:          return "Engine Error"
        }
    }
}

#Preview {
    ContentView()
        .environment(SteamAuthService())
        .environment(SteamLibraryStore())
        .environment(WineEngine())
        .environment(WineSteamManager())
        .environment(SteamSessionBridge())
}
