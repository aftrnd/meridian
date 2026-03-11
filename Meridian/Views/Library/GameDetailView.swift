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
            heroSection

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
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
            Text("This will delete the Wine prefix, Steam installation, and all downloaded game files. The Wine engine runtime will be kept. On next launch, everything will be set up fresh.")
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        heroImage
            .frame(maxWidth: .infinity)
            .frame(height: 240)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(
                    colors: [.clear, .black.opacity(0.6)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 110)
                .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(currentGame.name)
                        .font(.title)
                        .fontWeight(.bold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 1)

                    HStack(spacing: 8) {
                        if currentGame.playtimeMinutes > 0 {
                            Text(currentGame.playtimeFormatted + " played")
                                .font(.subheadline)
                                .foregroundStyle(.white.opacity(0.8))
                        }
                        if currentGame.windowsOnly {
                            WindowsBadge()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
            }
    }

    @ViewBuilder
    private var heroImage: some View {
        AsyncImage(url: game.heroURL) { heroPhase in
            switch heroPhase {
            case .success(let image):
                image.resizable().aspectRatio(contentMode: .fill)
            default:
                AsyncImage(url: game.capsuleURL) { capsulePhase in
                    switch capsulePhase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fill)
                    default:
                        Color.primary.opacity(0.05)
                    }
                }
            }
        }
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

    // MARK: - Launch

    @ViewBuilder
    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                playButton
                Spacer()
            }
            if isActivePhase {
                ActivityCard(launcher: launcher, openWindow: openWindow)
            }
        }
    }

    private var isActivePhase: Bool {
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching, .running:
            return true
        default:
            return false
        }
    }

    private var isInProgress: Bool {
        switch launcher.launchState {
        case .preparingEngine, .preparingPrefix, .bootstrappingSteam, .launching:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private var playButton: some View {
        switch launcher.launchState {
        case .idle, .exited:
            Button { handlePlayTapped() } label: {
                Label(currentGame.isInstalled ? "Play" : "Install & Play",
                      systemImage: currentGame.isInstalled ? "play.fill" : "arrow.down.circle.fill")
                    .font(.headline)
                    .frame(minWidth: 130)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!steamAuth.isAuthenticated)

        case .preparingEngine, .preparingPrefix:
            HStack(spacing: 8) {
                ProgressButton("Preparing…")
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
                Button {} label: {
                    Label("Running", systemImage: "play.circle.fill")
                        .font(.headline)
                        .frame(minWidth: 100)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    Task { await launcher.stopGame(engine: engine, steamManager: steamManager) }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }

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

    private var cancelButton: some View {
        Button {
            Task { await launcher.cancelLaunch(engine: engine, steamManager: steamManager) }
        } label: {
            Label("Cancel", systemImage: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }

    private var currentGame: Game {
        library.games.first(where: { $0.id == game.id }) ?? game
    }

    // MARK: - Info

    private var infoSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let recent = currentGame.playtime2WeekMinutes, recent > 0 {
                infoRow("Last 2 weeks", value: "\(recent / 60) hrs")
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

// MARK: - Progress Button

private struct ProgressButton: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Button {} label: {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.75)
                Text(title)
            }
            .frame(minWidth: 130)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(true)
    }
}

// MARK: - Activity Card

private struct ActivityCard: View {
    let launcher: GameLauncher
    let openWindow: OpenWindowAction

    @State private var elapsed: TimeInterval = 0
    @State private var timer: Timer?

    private var recentLogs: [String] {
        launcher.logs.suffix(3).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 16, height: 16)
                VStack(alignment: .leading, spacing: 2) {
                    Text(launcher.currentActivity ?? "Working…")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    if elapsed > 5 {
                        Text(elapsedLabel)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .monospacedDigit()
                    }
                }
                Spacer()
                Button {
                    openWindow(id: "launch-log")
                } label: {
                    Label("Logs", systemImage: "terminal")
                        .font(.caption)
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }

            if !recentLogs.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(recentLogs.enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator, lineWidth: 0.5))
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private var elapsedLabel: String {
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return mins > 0 ? "\(mins)m \(secs)s elapsed" : "\(secs)s elapsed"
    }

    private func startTimer() {
        elapsed = 0
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in elapsed += 1 }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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
