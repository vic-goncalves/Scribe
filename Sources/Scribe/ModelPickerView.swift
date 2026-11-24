import SwiftUI

struct ModelPickerView: View {
    @Environment(Transcriber.self) private var transcriber
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Speech models")
                    .font(.system(size: 17, weight: .semibold))
                Text("Models run entirely on this Mac. Each one is a one-time download.")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.secondaryText)
            }
            .padding(20)

            VStack(spacing: 0) {
                ForEach(Array(ModelOption.all.enumerated()), id: \.element.id) { index, option in
                    if index > 0 {
                        Rectangle().fill(Theme.border).frame(height: 1)
                    }
                    ModelRow(option: option)
                }
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.elevated))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border, lineWidth: 1))
            .padding(.horizontal, 20)

            HStack {
                Text("Stored in ~/Library/Application Support/Scribe")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.tertiaryText)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .padding(20)
        }
        .frame(width: 520)
        .background(Theme.canvas)
    }
}

private struct ModelRow: View {
    let option: ModelOption
    @Environment(Transcriber.self) private var transcriber

    private var isCurrent: Bool { transcriber.currentModelId == option.id }
    private var isDownloaded: Bool { transcriber.downloadedModels[option.id] != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(option.name)
                        .font(.system(size: 13.5, weight: .medium))
                    Text(option.size)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.tertiaryText)
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
                if let error = transcriber.downloadErrors[option.id] {
                    Text(error)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.red)
                }
            }
            Spacer(minLength: 12)
            action
                .frame(minWidth: 96, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private var action: some View {
        if let progress = transcriber.downloadProgress[option.id] {
            VStack(alignment: .trailing, spacing: 5) {
                ProgressBar(value: progress > 0 ? progress : nil)
                    .frame(width: 96)
                Text(progress > 0 ? "\(Int(progress * 100))%" : "Starting…")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.tertiaryText)
                    .monospacedDigit()
            }
        } else if isCurrent {
            HStack(spacing: 5) {
                if transcriber.phase == .loading {
                    ProgressView().controlSize(.mini)
                    Text("Loading")
                } else {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.brand)
                    Text("In use")
                }
            }
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.secondaryText)
        } else if isDownloaded {
            HStack(spacing: 2) {
                Button("Use") {
                    Task { await transcriber.use(option) }
                }
                .buttonStyle(OutlineButtonStyle())
                Menu {
                    Button("Delete Download", role: .destructive) { transcriber.deleteModel(option) }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12))
                        .frame(width: 22, height: 24)
                }
                .menuStyle(.button)
                .buttonStyle(GhostButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                .help("More")
            }
        } else {
            Button {
                Task { await transcriber.download(option) }
            } label: {
                Label("Download", systemImage: "arrow.down")
            }
            .buttonStyle(OutlineButtonStyle())
        }
    }
}

struct OutlineButtonStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(configuration.isPressed ? Theme.selection : isHovered ? Theme.hover : Theme.elevated)
            )
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.border, lineWidth: 1))
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}
