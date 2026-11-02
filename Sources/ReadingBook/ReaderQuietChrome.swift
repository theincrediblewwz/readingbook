import SwiftUI

/// Two centered shadows trace the glyph and softly separate it from both white
/// and detailed covers, without adding a plate behind the text or dots.
struct CoverGlyphLegibility: ViewModifier {
    func body(content: Content) -> some View {
        content.shadow(color: .black.opacity(0.9), radius: 0.8)
            .shadow(color: .black.opacity(0.7), radius: 3)
    }
}

struct CoverGlyphButtonStyle: ButtonStyle {
    @Environment(\.readingReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        CoverGlyphButton(configuration: configuration, reduceMotion: reduceMotion)
    }
    private struct CoverGlyphButton: View {
        let configuration: Configuration
        let reduceMotion: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .background(.black.opacity(configuration.isPressed ? 0.24 : hovered ? 0.12 : 0), in: Circle())
                .scaleEffect(configuration.isPressed ? 0.94 : 1)
                .onHover { hovered = $0 }
                .animation(ReadingMotion.animation(reduce: reduceMotion), value: hovered)
                .animation(ReadingMotion.animation(reduce: reduceMotion), value: configuration.isPressed)
        }
    }
}

/// The outside slot stays fixed, so revealing the label never resizes the
/// document or moves the adjacent reading controls.
struct ReaderCompanionLauncher: View {
    @Environment(\.readingReduceMotion) private var reduceMotion
    let active: Bool
    let action: () -> Void
    @State private var hovered = false
    @FocusState private var focused: Bool
    private var expanded: Bool { hovered || focused }

    var body: some View {
        Button(action: action) {
            HStack(spacing: expanded ? 8 : 0) {
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 18, weight: .medium)).frame(width: 24)
                Text("伴读与对话").font(.system(size: 14, weight: .medium))
                    .fixedSize().frame(width: expanded ? 84 : 0, alignment: .leading)
                    .clipped().opacity(expanded ? 1 : 0)
            }
            .frame(width: expanded ? 148 : 44, height: 44)
            .contentShape(Capsule())
            .readingGlass(radius: 22, interactive: true)
            .overlay { Capsule().strokeBorder(Palette.accent.opacity(active ? 0.22 : 0), lineWidth: 1).allowsHitTesting(false) }
        }
        .buttonStyle(ReadingQuietButtonStyle(radius: 22))
        .focused($focused)
        .onHover { if hovered != $0 { hovered = $0 } }
        .animation(ReadingMotion.animation(reduce: reduceMotion), value: expanded)
        .frame(width: 164, height: 44)
        .accessibilityLabel("伴读与对话")
        .accessibilityValue(active ? "已打开" : "已收起")
        .accessibilityIdentifier("reader-companion-launcher")
        .help(active ? "收起伴读与对话，保留当前内容" : "打开伴读与对话")
    }
}
