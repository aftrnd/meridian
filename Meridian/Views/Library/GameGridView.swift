import SwiftUI

struct GameGridView: View {
    let game: Game
    let isSelected: Bool
    var isFavorite: Bool = false
    var isRunning: Bool = false

    @State private var isHovered = false
    @State private var runningPulse = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artSection
            infoRow
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isRunning
                    ? Color.green.opacity(0.08)
                    : (isSelected ? Color.accentColor.opacity(0.1) : Color.clear))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isRunning
                        ? Color.green.opacity(runningPulse ? 0.9 : 0.5)
                        : (isSelected
                            ? Color.accentColor
                            : (isHovered ? Color.primary.opacity(0.12) : Color.clear)),
                    lineWidth: isRunning ? 1.5 : (isSelected ? 1.5 : 1)
                )
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
        .onAppear {
            if isRunning {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    runningPulse = true
                }
            }
        }
        .onChange(of: isRunning) { _, running in
            if running {
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    runningPulse = true
                }
            } else {
                runningPulse = false
            }
        }
    }

    private var artSection: some View {
        CachedAsyncImage(url: game.capsuleURL, fallbacks: game.capsuleURLFallbacks) { phase in
            switch phase {
            case .success(let image):
                image
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            case .empty:
                Color.primary.opacity(0.05)
                    .overlay { ProgressView().scaleEffect(0.6) }
            case .failure:
                artPlaceholder
            @unknown default:
                artPlaceholder
            }
        }
        .aspectRatio(460.0 / 215.0, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipped()
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 4) {
                if isRunning {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.green)
                            .frame(width: 6, height: 6)
                            .scaleEffect(runningPulse ? 1.3 : 0.8)
                        Text("Now Playing")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
                }

                if isFavorite {
                    Image(systemName: "heart.fill")
                        .font(.caption2)
                        .foregroundStyle(.white)
                        .padding(5)
                        .background(.pink.opacity(0.85), in: Circle())
                        .padding(6)
                }
            }
        }
        .clipShape(UnevenRoundedRectangle(topLeadingRadius: 12, topTrailingRadius: 12))
    }

    private var artPlaceholder: some View {
        Color.primary.opacity(0.05)
            .overlay {
                Image(systemName: "gamecontroller")
                    .font(.title2)
                    .foregroundStyle(.tertiary)
            }
    }

    private var infoRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(game.name)
                .font(.footnote)
                .fontWeight(.medium)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
                .help(game.name)

            HStack(spacing: 6) {
                Text(game.playtimeFormatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                Spacer()

                if game.windowsOnly {
                    WindowsBadge()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.regularMaterial)
        .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12))
    }
}

// MARK: - Windows badge

struct WindowsBadge: View {
    var body: some View {
        Label("Windows", systemImage: "desktopcomputer")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.indigo, in: Capsule())
    }
}

#Preview {
    HStack {
        GameGridView(game: Game.previews[0], isSelected: false, isFavorite: true)
        GameGridView(game: Game.previews[2], isSelected: true, isFavorite: false)
    }
    .padding()
    .frame(width: 440)
}
