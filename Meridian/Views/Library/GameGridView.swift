import SwiftUI

struct GameGridView: View {
    let game: Game
    let isSelected: Bool

    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            artSection
            infoRow
        }
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(
                    isSelected
                        ? Color.accentColor
                        : (isHovered ? Color.primary.opacity(0.12) : Color.clear),
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .onHover { isHovered = $0 }
        .contentShape(Rectangle())
    }

    private var artSection: some View {
        CachedAsyncImage(url: game.capsuleURL) { phase in
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
        GameGridView(game: Game.previews[0], isSelected: false)
        GameGridView(game: Game.previews[2], isSelected: true)
    }
    .padding()
    .frame(width: 440)
}
