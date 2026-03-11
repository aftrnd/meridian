import Observation
import Foundation
import os.log

private let log = Logger(subsystem: "com.meridian.app", category: "SteamLibrary")

/// Owns the fetched game list and drives search/filter/sort.
@Observable
@MainActor
final class SteamLibraryStore {
    private(set) var games: [Game] = []
    private(set) var recentGames: [Game] = []
    private(set) var isLoading: Bool = false
    private(set) var loadError: String?
    private(set) var lastRefreshed: Date?

    var searchQuery: String = ""
    var sortOrder: SortOrder = .nameAscending
    var filter: LibraryFilter = .all
    private let settings = AppSettings.shared

    // MARK: - Computed filtered / sorted view

    var filteredGames: [Game] {
        var result = games

        switch filter {
        case .all:       break
        case .recent:    result = recentGames
        case .installed: result = result.filter { $0.isInstalled }
        case .favorites: result = result.filter { settings.isFavorite(appID: $0.id) }
        }

        if !searchQuery.isEmpty {
            let q = searchQuery.lowercased()
            result = result.filter { $0.name.lowercased().contains(q) }
        }

        switch sortOrder {
        case .nameAscending:       result.sort { $0.name < $1.name }
        case .nameDescending:      result.sort { $0.name > $1.name }
        case .playtimeDescending:  result.sort { $0.playtimeMinutes > $1.playtimeMinutes }
        case .recentlyPlayed:      result.sort { ($0.playtime2WeekMinutes ?? 0) > ($1.playtime2WeekMinutes ?? 0) }
        }

        return result
    }

    // MARK: - Fetch

    func refresh(steamID: String, apiKey: String) async {
        guard !isLoading, !steamID.isEmpty else {
            log.debug("[refresh] skipped: isLoading=\(self.isLoading) steamID.isEmpty=\(steamID.isEmpty)")
            return
        }
        guard !apiKey.isEmpty else {
            log.warning("[refresh] no API key configured")
            loadError = "Steam Web API key not configured. Add it in Settings."
            return
        }
        log.info("[refresh] starting for steamID=\(steamID)")
        isLoading = true
        loadError = nil
        defer { isLoading = false }

        do {
            async let owned  = SteamAPIService.shared.fetchOwnedGames(steamID: steamID, apiKey: apiKey)
            async let recent = SteamAPIService.shared.fetchRecentlyPlayed(steamID: steamID, apiKey: apiKey)
            let (ownedGames, recentlyPlayed) = try await (owned, recent)
            games = applyInstallCache(to: ownedGames)
            recentGames = applyInstallCache(to: recentlyPlayed)
            lastRefreshed = .now
            log.info("[refresh] complete: \(ownedGames.count) owned, \(recentlyPlayed.count) recent")
        } catch {
            loadError = error.localizedDescription
            log.error("[refresh] failed: \(error.localizedDescription)")
        }
    }

    func setInstalled(_ installed: Bool, for appID: Int) {
        log.info("[setInstalled] appID=\(appID) installed=\(installed)")
        if installed {
            settings.markInstalled(appID: appID)
        } else {
            settings.markNotInstalled(appID: appID)
        }
        updateInstalledFlag(for: appID, installed: installed)
    }

    // MARK: - Private helpers

    private func applyInstallCache(to source: [Game]) -> [Game] {
        source.map { game in
            var copy = game
            copy.isInstalled = settings.isInstalled(appID: game.id)
            return copy
        }
    }

    private func updateInstalledFlag(for appID: Int, installed: Bool) {
        if let idx = games.firstIndex(where: { $0.id == appID }) {
            games[idx].isInstalled = installed
        }
        if let idx = recentGames.firstIndex(where: { $0.id == appID }) {
            recentGames[idx].isInstalled = installed
        }
    }

    // MARK: - Filter / sort types

    enum SortOrder: String, CaseIterable, Identifiable {
        case nameAscending      = "Name (A–Z)"
        case nameDescending     = "Name (Z–A)"
        case playtimeDescending = "Most Played"
        case recentlyPlayed     = "Recently Played"
        var id: String { rawValue }
    }

    enum LibraryFilter: String, CaseIterable, Identifiable {
        case all       = "All Games"
        case recent    = "Recent"
        case installed = "Installed"
        case favorites = "Favorites"
        var id: String { rawValue }
    }

    func isFavorite(appID: Int) -> Bool {
        settings.isFavorite(appID: appID)
    }

    func toggleFavorite(appID: Int) {
        log.info("[toggleFavorite] appID=\(appID)")
        settings.toggleFavorite(appID: appID)
    }
}
