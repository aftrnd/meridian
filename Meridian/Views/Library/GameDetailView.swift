import SwiftUI
import AppKit

struct GameDetailView: View {
    let game: Game
    let onDismiss: () -> Void

    @Environment(SteamLibraryStore.self)  private var library
    @Environment(WineEngine.self)         private var engine
    @Environment(WineSteamManager.self)   private var steamManager
    @Environment(SteamAuthService.self)   private var steamAuth
    @Environment(SteamSessionBridge.self) private var sessionBridge
    @Environment(GameLauncher.self)       private var launcher
    @Environment(\.openWindow)            private var openWindow

    @State private var showEngineSetup = false
    @State private var showResetConfirm = false

    var body: some View {
        VStack(spacing: 0) {
            heroArt
            titleHeader
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    launchSection
                    infoSection
                }
                .padding(20)
            }
            Divider()
            footerBar
        }
        .frame(minWidth: 520, minHeight: 480)
        .sheet(isPresented: $showEngineSetup) {
            EngineSetupView().environment(engine)
        }
        .alert("Reset Wine Environment?", isPresented: $showResetConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                Task {
                    await launcher.cleanupProcesses(engine: engine, steamManager: steamManager)
                    WinePrefix.defaultPrefix.reset()
                }
            }
        } message: {
            Text("This will delete the Wine prefix, Steam installation, and all downloaded game files. On next launch, everything will be set up fresh.")
        }
    }

    // MARK: - Art banner

    private var heroArt: some View {
        CachedAsyncImage(url: game.heroURL, fallbacks: game.heroURLFallbacks) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity.animation(.easeIn(duration: 0.25)))
            case .failure:
                // Hero not available — fall back to capsule art
                CachedAsyncImage(url: game.capsuleURL, fallbacks: game.capsuleURLFallbacks) { capsulePhase in
                    switch capsulePhase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .transition(.opacity.animation(.easeIn(duration: 0.25)))
                    case .empty:
                        artShimmer
                    default:
                        artPlaceholder
                    }
                }
            case .empty:
                artShimmer
            @unknown default:
                artPlaceholder
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipped()
    }

    private var artShimmer: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                ShimmerView()
            }
    }

    private var artPlaceholder: some View {
        Rectangle()
            .fill(.quaternary)
            .overlay {
                Image(systemName: "photo")
                    .font(.title)
                    .foregroundStyle(.tertiary)
            }
    }

    // MARK: - Title header

    private var titleHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(currentGame.name)
                    .font(.title3)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if currentGame.playtimeMinutes > 0 {
                        Text(currentGame.playtimeFormatted + " played")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if !currentGame.isInstalled {
                        NotInstalledBadge()
                    }
                }
            }

            Spacer(minLength: 0)

            Button {
                library.toggleFavorite(appID: currentGame.id)
            } label: {
                Image(systemName: library.isFavorite(appID: currentGame.id) ? "heart.fill" : "heart")
                    .foregroundStyle(library.isFavorite(appID: currentGame.id) ? .pink : .secondary)
                    .font(.title3)
            }
            .buttonStyle(.borderless)
            .help(library.isFavorite(appID: currentGame.id) ? "Remove from Favorites" : "Add to Favorites")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack {
            Spacer()
            Button("Done") { onDismiss() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            Button("") { onDismiss() }
                .keyboardShortcut(.cancelAction)
                .hidden()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Launch section

    @ViewBuilder
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            playButton
            if isThisGameActive {
                StatusCard(game: currentGame, launcher: launcher, openWindow: openWindow)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .animation(.easeInOut(duration: 0.2), value: isThisGameActive)
            }
        }
    }

    // MARK: - Per-game gating

    /// True when the global launcher is operating on THIS game specifically.
    /// Prep states (preparingEngine / preparingPrefix / bootstrappingSteam / launching)
    /// are attributed to the active game via launcher.activeAppID.
    private var isThisGame: Bool {
        launcher.activeAppID == game.id
    }

    /// True when the UI should show active launch controls for this game.
    private var isThisGameActive: Bool {
        guard isThisGame else { return false }
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching, .running, .stopping:
            return true
        default:
            return false
        }
    }

    // MARK: - Play button

    @ViewBuilder
    private var playButton: some View {
        // If launcher is busy with a different game, show a plain Play button
        // (user can't launch a second game simultaneously anyway).
        if let activeID = launcher.activeAppID, activeID != game.id {
            idleButton
        } else {
            activePlayButton
        }
    }

    @ViewBuilder
    private var activePlayButton: some View {
        switch launcher.launchState {
        case .idle, .exited:
            idleButton

        case .preparingEngine, .preparingPrefix:
            HStack(spacing: 8) {
                ProgressButton(launcher.currentActivity ?? "Preparing…")
                cancelButton
            }

        case .bootstrappingSteam:
            HStack(spacing: 8) {
                ProgressButton("Updating Steam…")
                cancelButton
            }

        case .launching:
            ProgressButton("Launching…")

        case .running:
            HStack(spacing: 8) {
                if launcher.processesConfirmed {
                    Button {} label: {
                        Label("Running", systemImage: "play.circle.fill")
                            .font(.headline)
                            .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(true)
                } else {
                    ProgressButton("Starting…")
                }

                stopButton
            }

        case .stopping:
            ProgressButton("Stopping…")

        case .failed(let msg):
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if !engine.isReady {
                        Button { showEngineSetup = true } label: {
                            Label("Set Up Engine…", systemImage: "arrow.down.circle")
                                .frame(minWidth: 130)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    } else {
                        Button { handlePlayTapped() } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .frame(minWidth: 130)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                    }

                    Button { showResetConfirm = true } label: {
                        Label("Reset", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("Delete Wine prefix and start fresh")
                }

                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var idleButton: some View {
        Button { handlePlayTapped() } label: {
            Label(
                currentGame.isInstalled ? "Play" : "Install & Play",
                systemImage: currentGame.isInstalled ? "play.fill" : "arrow.down.circle.fill"
            )
            .font(.headline)
            .frame(minWidth: 130)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(!steamAuth.isAuthenticated || isLauncherBusyWithOtherGame)
        .help(isLauncherBusyWithOtherGame ? "Stop the current game before launching another" : "")
    }

    /// True when the launcher is actively working on a different game.
    /// Prevents accidentally interrupting an in-progress launch or running game.
    private var isLauncherBusyWithOtherGame: Bool {
        guard let activeID = launcher.activeAppID, activeID != game.id else { return false }
        switch launcher.launchState {
        case .idle, .exited, .failed: return false
        default: return true
        }
    }

    private var cancelButton: some View {
        Button {
            Task { await launcher.cancelLaunch(engine: engine, steamManager: steamManager) }
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var stopButton: some View {
        Button {
            Task { await launcher.stopGame(engine: engine, steamManager: steamManager) }
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recent = currentGame.playtime2WeekMinutes, recent > 0 {
                let value = recent >= 60 ? "\(recent / 60) hrs" : "\(recent) min"
                infoRow("Last 2 weeks", value: value)
                Divider().padding(.leading, 12)
            }
            infoRow("App ID", value: String(currentGame.id), monospaced: true)
            if currentGame.windowsOnly {
                Divider().padding(.leading, 12)
                HStack {
                    Text("Compatibility")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                    Spacer()
                    WindowsBadge()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
    }

    private func infoRow(_ label: String, value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
                .font(.subheadline)
            Spacer()
            Text(value)
                .font(monospaced ? .subheadline.monospaced() : .subheadline)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: - Helpers

    private var currentGame: Game {
        library.gameWithMergedPlaytime(appID: game.id) ?? library.games.first(where: { $0.id == game.id }) ?? game
    }

    private func handlePlayTapped() {
        guard engine.isReady else {
            showEngineSetup = true
            return
        }
        launcher.launch(
            game: currentGame,
            engine: engine,
            steamManager: steamManager,
            sessionBridge: sessionBridge,
            library: library
        )
    }
}

// MARK: - Not Installed Badge

private struct NotInstalledBadge: View {
    var body: some View {
        Text("Not Installed")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Color.orange, in: Capsule())
    }
}

// MARK: - Progress Button (disabled, spinning)

private struct ProgressButton: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Button {} label: {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                Text(title)
                    .lineLimit(1)
            }
            .frame(minWidth: 130)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(true)
    }
}

// MARK: - Status Card

/// Contextual status strip below the play button. Shows what Meridian is
/// actually doing right now, with an elapsed timer and a link to full logs.
private struct StatusCard: View {
    let game: Game
    let launcher: GameLauncher
    let openWindow: OpenWindowAction

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 10) {
                if showsSpinner(at: context.date) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 16, height: 16)
                } else {
                    Image(systemName: stateIcon)
                        .font(.caption)
                        .foregroundStyle(stateIconColor)
                        .frame(width: 16, height: 16)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text(statusMessage(at: context.date))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)

                    if let elapsed = elapsedText(at: context.date) {
                        Text(elapsed)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }

                    if showsLastLog, let lastLog = launcher.logs.last, !lastLog.isEmpty {
                        Text(lastLog)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer()

                Button {
                    openWindow(id: "launch-log")
                } label: {
                    Image(systemName: "terminal")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tertiary)
                .help("View launch logs")
            }
            .padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        }
    }

    private func showsSpinner(at date: Date) -> Bool {
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching, .stopping:
            return true
        case .running:
            return !launcher.processesConfirmed
        default:
            return false
        }
    }

    /// Show the last log line during active prep/launch/unconfirmed-running states.
    /// Hidden once confirmed running so it doesn't show stale text.
    private var showsLastLog: Bool {
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching:
            return true
        case .running:
            return !launcher.processesConfirmed
        default:
            return false
        }
    }

    private var stateIcon: String {
        switch launcher.launchState {
        case .running: return "checkmark.circle.fill"
        case .stopping: return "stop.circle"
        default: return "clock"
        }
    }

    private var stateIconColor: Color {
        switch launcher.launchState {
        case .running: return .green
        default: return .secondary
        }
    }

    private func statusMessage(at date: Date) -> String {
        switch launcher.launchState {
        case .preparingEngine:
            return launcher.currentActivity ?? "Checking Wine runtime…"
        case .preparingPrefix:
            return launcher.currentActivity ?? "Preparing Wine environment…"
        case .bootstrappingSteam:
            return "Updating Steam — first launch takes a few minutes"
        case .launching:
            return "Launching \(game.name)…"
        case .running:
            if launcher.processesConfirmed {
                return game.isInstalled
                    ? "Game is running"
                    : "Installing via Steam — download in progress"
            }
            let elapsed = launcher.runningSince.map { date.timeIntervalSince($0) } ?? 0
            // Grace period is 5s; if we still haven't confirmed by ~10s something
            // is taking longer than usual (e.g. slow first Steam login).
            return elapsed > 10
                ? "Steam is loading — game window opening soon…"
                : "Opening game window…"
        case .stopping:
            return "Stopping game…"
        default:
            return launcher.currentActivity ?? "Working…"
        }
    }

    /// Elapsed time from the pipeline start (prep + launch) or from when
    /// the game entered running state. Uses authoritative dates from the
    /// launcher — never resets when the view is navigated away and back.
    private func elapsedText(at date: Date) -> String? {
        let start: Date?
        switch launcher.launchState {
        case .running:
            start = launcher.runningSince ?? launcher.pipelineStartDate
        default:
            start = launcher.pipelineStartDate
        }
        guard let start else { return nil }
        let secs = Int(date.timeIntervalSince(start))
        guard secs >= 3 else { return nil }
        let mins = secs / 60
        let rem  = secs % 60
        return mins > 0 ? "\(mins)m \(rem)s" : "\(rem)s"
    }
}

// MARK: - Shimmer (loading skeleton animation)

struct ShimmerView: View {
    @State private var phase: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            LinearGradient(
                stops: [
                    .init(color: .clear,            location: 0),
                    .init(color: .white.opacity(0.1), location: 0.4),
                    .init(color: .white.opacity(0.2), location: 0.5),
                    .init(color: .white.opacity(0.1), location: 0.6),
                    .init(color: .clear,            location: 1),
                ],
                startPoint: .init(x: phase - 0.3, y: 0.5),
                endPoint:   .init(x: phase + 0.3, y: 0.5)
            )
            .frame(width: w * 2)
            .offset(x: -w + phase * w * 2)
        }
        .onAppear {
            withAnimation(.linear(duration: 1.4).repeatForever(autoreverses: false)) {
                phase = 1
            }
        }
        .clipped()
    }
}

// MARK: - Launch Log Window

struct LaunchLogWindow: View {
    @Environment(GameLauncher.self) private var launcher

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            logContent
        }
        .frame(minWidth: 500, minHeight: 280)
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Image(systemName: "terminal")
                .foregroundStyle(.secondary)
            Text("Launch Log")
                .font(.headline)
            Spacer()
            if !launcher.logs.isEmpty {
                Text("\(launcher.logs.count) lines")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button {
                    let text = launcher.logs.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                } label: {
                    Label("Copy All", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderless)
            } else {
                Text("No output yet")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var logContent: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    if launcher.logs.isEmpty {
                        Text("Waiting for output…")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(12)
                    } else {
                        ForEach(Array(launcher.logs.enumerated()), id: \.offset) { i, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.primary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(i)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                    }
                }
            }
            .onChange(of: launcher.logs.count) { _, n in
                guard n > 0 else { return }
                proxy.scrollTo(n - 1, anchor: .bottom)
            }
        }
    }
}
