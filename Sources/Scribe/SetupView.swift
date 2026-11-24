import SwiftUI

struct SetupView: View {
    @Environment(Transcriber.self) private var transcriber
    @State private var choice = ModelOption.recommended

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Welcome to Scribe")
                    .font(.system(size: 28, weight: .bold))
                Text("Scribe transcribes audio entirely on this Mac. Choose a speech model to download. It's a one-time download, and after that everything works offline.")
                    .font(.system(size: 14))
                    .foregroundStyle(Theme.secondaryText)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(Array(ModelOption.all.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                    ModelChoiceRow(option: option, isSelected: option == choice) { choice = option }
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .disabled(isBusy)

            status
                .frame(height: 44, alignment: .top)
        }
        .padding(48)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas)
        .ignoresSafeArea()
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
            VStack(alignment: .leading, spacing: 8) {
                ProgressBar(value: fraction > 0 ? fraction : nil)
                Text("Downloading \(choice.name) model · \(Int(fraction * 100))% of \(choice.size)")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
                    .monospacedDigit()
            }
        case .loading:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing the model for your Mac. The first time can take a few minutes.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        case .failed(let message):
            HStack(spacing: 12) {
                downloadButton(title: "Try again")
                Text(message)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.red)
            }
        case .needsSetup, .ready:
            HStack(spacing: 12) {
                downloadButton(title: "Download and continue")
                Text("You can switch models later.")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private func downloadButton(title: String) -> some View {
        Button(title) {
            Task { await transcriber.install(choice) }
        }
        .buttonStyle(PrimaryButtonStyle())
        .keyboardShortcut(.defaultAction)
    }
}

private struct ModelChoiceRow: View {
    let option: ModelOption
    let isSelected: Bool
    let select: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: select) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .strokeBorder(isSelected ? Color.brand : Theme.tertiaryText.opacity(0.6), lineWidth: isSelected ? 5 : 1.25)
                    .frame(width: 16, height: 16)
                    .animation(.easeOut(duration: 0.12), value: isSelected)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(option.name)
                            .font(.system(size: 13.5, weight: .medium))
                        if option == ModelOption.recommended {
                            Text("Recommended")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.secondaryText)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 1)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.hover))
                        }
                    }
                    Text(option.summary)
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Text(option.size)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .background(isHovered ? Theme.hover.opacity(0.6) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
