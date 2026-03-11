import SwiftUI

/// Shown when no Wine backend is detected.
struct EngineSetupView: View {
    @Environment(WineEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                Image(systemName: "gearshape.arrow.triangle.2.circlepath")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.tint)

                Text("Wine Runtime Required")
                    .font(.title2)
                    .fontWeight(.semibold)

                Text("Meridian needs a Wine runtime to run Windows games. Install CrossOver from codeweavers.com, then relaunch Meridian.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }

            if engine.isReady {
                Label("Engine ready (\(engine.backendName))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                VStack(spacing: 12) {
                    Link("Get CrossOver", destination: URL(string: "https://www.codeweavers.com/crossover")!)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                    Button("Re-detect") {
                        engine.detect()
                    }
                    .buttonStyle(.bordered)

                    Button("Cancel") { dismiss() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
            }

            if case .error(let msg) = engine.state {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
        }
        .padding(40)
        .frame(minWidth: 500, minHeight: 340)
        .onChange(of: engine.state) { _, newState in
            if newState == .ready { dismiss() }
        }
    }
}
