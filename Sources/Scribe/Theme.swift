import AppKit
import SwiftUI

extension Color {
    /// The one accent color, used sparingly: primary actions, progress and the playhead.
    static let brand = Color(red: 0.137, green: 0.514, blue: 0.886)
}

/// Neutral palette: white canvas, soft gray sidebar, warm near-black text. Light and dark variants.
enum Theme {
    static let canvas = dynamic(light: 0xFFFFFF, dark: 0x191919)
    static let sidebar = dynamic(light: 0xF7F7F5, dark: 0x202020)
    static let elevated = dynamic(light: 0xFFFFFF, dark: 0x252525)
    static let border = dynamic(light: 0xE9E9E7, dark: 0x2F2F2F)
    static let text = dynamic(light: 0x37352F, dark: 0xD4D4D4)
    static let secondaryText = dynamic(light: 0x787774, dark: 0x9B9B9B)
    static let tertiaryText = dynamic(light: 0xA5A29D, dark: 0x6F6F6F)
    static let hover = dynamic(light: 0xEFEFED, dark: 0x2C2C2C)
    static let selection = dynamic(light: 0xE8E8E6, dark: 0x333333)
    static let track = dynamic(light: 0xE3E2E0, dark: 0x3A3A3A)
    static let highlight = dynamic(light: 0xFBF3DB, dark: 0x4F4220)
    static let activeSegment = dynamic(light: 0xE7F3F8, dark: 0x1D3340)

    /// Muted, distinguishable label colors (Notion's text palette), cycled by speaker number.
    static func speakerColor(_ number: Int) -> Color {
        let palette: [Color] = [
            dynamic(light: 0x337EA9, dark: 0x5B97BD),
            dynamic(light: 0xD9730D, dark: 0xDD8B42),
            dynamic(light: 0x448361, dark: 0x5A9A78),
            dynamic(light: 0x9065B0, dark: 0x9D7AB8),
            dynamic(light: 0xC14C8A, dark: 0xC76A9C),
            dynamic(light: 0x9F6B53, dark: 0xA77D68),
            dynamic(light: 0xD44C47, dark: 0xDB6B66),
        ]
        return palette[(max(number, 1) - 1) % palette.count]
    }

    static let titleFont = Font.system(size: 34, weight: .bold)
    static let bodyFont = Font.system(size: 15.5)

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
        })
    }
}

private extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.brand.opacity(isEnabled ? 1 : 0.4))
                    .brightness(configuration.isPressed ? -0.08 : 0)
            )
            .contentShape(Rectangle())
    }
}

/// Quiet button for secondary actions: no chrome until hovered.
struct GhostButtonStyle: ButtonStyle {
    @State private var isHovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(isEnabled ? Theme.secondaryText : Theme.tertiaryText)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(configuration.isPressed ? Theme.selection : isHovered && isEnabled ? Theme.hover : .clear)
            )
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
    }
}

struct SearchField: View {
    @Binding var text: String
    var prompt = "Search"
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.tertiaryText)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($isFocused)
                .onExitCommand {
                    text = ""
                    isFocused = false
                }
            if !text.isEmpty {
                Button { text = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.tertiaryText)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(isFocused ? Theme.elevated : Theme.hover))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isFocused ? Color.brand.opacity(0.5) : .clear, lineWidth: 1)
        )
    }
}

/// Pass nil for an indeterminate bar that sweeps until real progress is known.
struct ProgressBar: View {
    let value: Double?
    @State private var sweep = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.track)
                if let value {
                    Capsule().fill(Color.brand)
                        .frame(width: max(4, geo.size.width * min(max(value, 0), 1)))
                        .animation(.easeOut(duration: 0.3), value: value)
                } else {
                    Capsule().fill(Color.brand)
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: sweep ? geo.size.width * 0.7 : 0)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { sweep = true }
                        }
                }
            }
            .clipShape(Capsule())
        }
        .frame(height: 4)
    }
}
