import SwiftUI

struct LibraryView: View {
    @Environment(SteamLibraryStore.self) private var library
    @Environment(GameLauncher.self)      private var launcher
    @Binding var selectedGame: Game?

    private static let gridSpacing: CGFloat = 16
    private let columns = [
        GridItem(.adaptive(minimum: 180, maximum: 260), spacing: gridSpacing)
    ]

    var body: some View {
        @Bindable var library = library
        Group {
            if library.isLoading && library.games.isEmpty {
                loadingView
            } else if let error = library.loadError {
                errorView(error)
            } else if library.filteredGames.isEmpty {
                emptyView
            } else {
                gameGrid
            }
        }
        .navigationTitle("")
    }

    private var gameGrid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(library.filteredGames) { game in
                    GameGridView(
                        game: game,
                        isSelected: selectedGame?.id == game.id,
                        isFavorite: library.isFavorite(appID: game.id),
                        showFavoriteBadge: library.filter != .favorites,
                        gameState: gameState(for: game)
                    )
                        .onTapGesture { selectedGame = game }
                        .contextMenu {
                            Button {
                                library.toggleFavorite(appID: game.id)
                            } label: {
                                Label(
                                    library.isFavorite(appID: game.id) ? "Remove from Favorites" : "Add to Favorites",
                                    systemImage: library.isFavorite(appID: game.id) ? "heart.slash" : "heart"
                                )
                            }
                            Divider()
                            Button {
                                selectedGame = game
                            } label: {
                                Label("View Details", systemImage: "info.circle")
                            }
                            Divider()
                            Button(role: .destructive) {
                                library.hideGame(appID: game.id)
                            } label: {
                                Label("Hide Game", systemImage: "eye.slash")
                            }
                        }
                }
            }
            .padding(Self.gridSpacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
    }

    private func gameState(for game: Game) -> GameCardState {
        guard launcher.activeAppID == game.id else {
            return game.isInstalled ? .idle : .notInstalled
        }
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching:
            return .launching
        case .running:
            return .running
        case .stopping:
            return .stopping
        default:
            return game.isInstalled ? .idle : .notInstalled
        }
    }

    // MARK: - Loading skeleton

    private var loadingView: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Self.gridSpacing) {
                ForEach(0..<16, id: \.self) { _ in
                    GameGridPlaceholder()
                }
            }
            .padding(Self.gridSpacing)
        }
        .ignoresSafeArea(edges: [.top, .bottom])
        .scrollIndicators(.hidden)
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.secondary)
            Text("Couldn't load library")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray")
                .font(.system(size: 40, weight: .thin))
                .foregroundStyle(.tertiary)
            Text("No games found")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Sort Menu Button (circular glass)

struct SortMenuButton: View {
    @Binding var sortOrder: SteamLibraryStore.SortOrder
    @State private var showPopover = false

    var body: some View {
        Button { showPopover.toggle() } label: {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.primary)
                // Square frame is what the circle is inscribed in —
                // must be set here on the label, before buttonStyle strips chrome.
                .frame(width: 28, height: 28)
        }
        // .plain removes ALL system button chrome so only our glass shows.
        .buttonStyle(.plain)
        .background {
            if #available(macOS 26.0, *) {
                Circle().glassEffect(.regular.interactive())
            } else {
                Circle()
                    .fill(.regularMaterial)
                    .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
            }
        }
        .popover(isPresented: $showPopover, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(SteamLibraryStore.SortOrder.allCases) { order in
                    Button {
                        sortOrder = order
                        showPopover = false
                    } label: {
                        HStack {
                            Text(order.rawValue)
                                .font(.body)
                            Spacer()
                            if sortOrder == order {
                                Image(systemName: "checkmark")
                                    .font(.body)
                                    .foregroundStyle(.tint)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(width: 200)
            .padding(.vertical, 6)
        }
        .help("Sort library")
    }
}

struct GlassCircleBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: .circle)
        } else {
            content
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Skeleton placeholder card

private struct GameGridPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            RoundedRectangle(cornerRadius: 0)
                .fill(.quaternary)
                .aspectRatio(460.0 / 215.0, contentMode: .fit)
                .overlay { ShimmerView() }
                .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))

            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(.quaternary)
                    .frame(height: 12)
                    .frame(maxWidth: 120)
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary.opacity(0.6))
                    .frame(height: 10)
                    .frame(maxWidth: 60)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
        }
        .background(RoundedRectangle(cornerRadius: 12).fill(.primary.opacity(0.03)))
    }
}
