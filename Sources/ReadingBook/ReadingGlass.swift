import SwiftUI

/// A small, shared spacing scale keeps controls calm and easy to acquire without
/// turning a reading workspace into a wall of oversized buttons.
enum ReadingLayout {
    static let controlHeight: CGFloat = 44
    static let groupSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 16
    static let nodeBrowserWidth: CGFloat = 370
    static let navigationRowHeight: CGFloat = 48
}

enum ReadingMotion {
    static func animation(reduce: Bool) -> Animation? {
        reduce ? nil : .snappy(duration: 0.24, extraBounce: 0.04)
    }
}

/// Floating chrome has one material surface; child controls keep generous hit
/// areas without adding another layer of glass over every icon.
struct ReadingGlassSurface: ViewModifier {
    var radius: CGFloat = 22
    var interactive = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.16 : 0.64), Palette.line.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.6)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? 0.23 : 0.06), radius: 24, x: 0, y: 10)
            .shadow(color: Palette.accent.opacity(0.045), radius: 4, x: 0, y: 2)
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
            .font(.system(size: 15, weight: .medium))
            .padding(.horizontal, 10).frame(minWidth: ReadingLayout.controlHeight, minHeight: ReadingLayout.controlHeight)
            .background(Palette.accent.opacity(selected ? 0.14 : configuration.isPressed ? 0.15 : hovered ? 0.075 : 0), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .foregroundStyle(selected ? Palette.accent : .primary)
            .opacity(enabled ? 1 : 0.42)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: configuration.isPressed)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: hovered)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: selected)
            .onHover { hovered = $0 }
    }
}

/// The paired actions in companion and editor surfaces share the reference
/// design's generous targets, blue primary and quiet outlined secondary.
struct ReadingActionButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 15, weight: .medium)).padding(.horizontal, 12)
            .frame(minHeight: 48).frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.white : Palette.ink)
            .background(prominent ? Palette.accent : Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(prominent ? Color.white.opacity(0.22) : Palette.accent.opacity(0.14), lineWidth: 0.8) }
            .shadow(color: Palette.accent.opacity(prominent ? 0.16 : 0), radius: 10, y: 4)
            .opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    func readingGlass(radius: CGFloat = 20, interactive: Bool = false) -> some View {
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
