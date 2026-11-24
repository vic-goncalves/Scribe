import SwiftUI

struct SetupView: View {
    @Environment(Transcriber.self) private var transcriber
    @State private var choice = ModelOption.recommended

    var body: some View {
        VStack(spacing: 28) {
            VStack(spacing: 10) {
                Image(systemName: "waveform")
                    .font(.system(size: 44, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Welcome to Scribe")
                    .font(.largeTitle.weight(.semibold))
                Text("Scribe turns recordings into searchable transcripts, entirely on this Mac. It needs a speech model first. That's a one-time download, and after it nothing leaves your computer.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 8) {
                ForEach(ModelOption.all) { option in
                    ModelOptionCard(option: option, isSelected: option == choice) { choice = option }
                }
            }
            .disabled(isBusy)

            status
                .frame(height: 56)
        }
        .padding(40)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var isBusy: Bool {
        switch transcriber.phase {
        case .downloading, .loading: true
        default: false
        }
    }

    @ViewBuilder
    private var status: some View {
        switch transcriber.phase {
        case .downloading(let fraction):
            VStack(spacing: 8) {
                ProgressView(value: fraction)
                Text("Downloading \(choice.name) model · \(Int(fraction * 100))% of \(choice.size)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        case .loading:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Optimizing the model for your Mac. The first time can take a few minutes.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .failed(let message):
            VStack(spacing: 8) {
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                downloadButton(title: "Try Again")
            }
        case .needsSetup, .ready:
            VStack(spacing: 8) {
                downloadButton(title: "Download and Continue")
                Text("Stored in ~/Library/Application Support/Scribe")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func downloadButton(title: String) -> some View {
        Button(title) {
            Task { await transcriber.install(choice) }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .keyboardShortcut(.defaultAction)
    }
}

private struct ModelOptionCard: View {
    let option: ModelOption
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: isSelected ? "largecircle.fill.circle" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.name).font(.headline)
                        if option == ModelOption.recommended {
                            Text("Recommended")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.tint.opacity(0.15), in: Capsule())
                                .foregroundStyle(.tint)
                        }
                        Spacer()
                        Text(option.size)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(option.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.08)) : AnyShapeStyle(.quaternary.opacity(0.5)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.5)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
