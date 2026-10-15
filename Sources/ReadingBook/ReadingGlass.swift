import SwiftUI

enum ReadingMotion {
    static func animation(reduce: Bool) -> Animation? {
        reduce ? nil : .snappy(duration: 0.24, extraBounce: 0.04)
    }
}

/// Floating chrome has one material surface; child controls keep generous hit
/// areas without adding another layer of glass over every icon.
struct ReadingGlassSurface: ViewModifier {
    var radius: CGFloat = 18
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.19 : 0.78), Palette.line.opacity(0.28)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.22 : 0.10), radius: 18, x: 0, y: 7)
            .shadow(color: Palette.accent.opacity(0.035), radius: 3, x: 0, y: 1)
    }
    @ViewBuilder private func surface(_ content: Content) -> some View {
        if reduceTransparency {
            content.background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}

struct ReadingToolbarButtonStyle: ButtonStyle {
    var selected = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @State private var hovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .medium))
            .padding(.horizontal, 9).frame(minWidth: 36, minHeight: 36)
            .background(Palette.accent.opacity(selected ? 0.14 : configuration.isPressed ? 0.15 : hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .foregroundStyle(selected ? Palette.accent : .primary)
            .opacity(enabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.96 : 1)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: configuration.isPressed)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: hovered)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: selected)
            .onHover { hovered = $0 }
    }
}

extension View {
    func readingGlass(radius: CGFloat = 18, interactive: Bool = false) -> some View {
        modifier(ReadingGlassSurface(radius: radius, interactive: interactive))
    }
    @ViewBuilder func readingGlassGroup() -> some View {
        if #available(macOS 26.0, *) { GlassEffectContainer(spacing: 16) { self } }
        else { self }
    }
    @ViewBuilder func readingGlassIdentity(_ id: String, in namespace: Namespace.ID) -> some View {
        if #available(macOS 26.0, *) { self.glassEffectID(id, in: namespace) }
        else { self }
    }
}
