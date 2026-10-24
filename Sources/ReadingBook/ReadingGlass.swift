import SwiftUI

/// A small, shared spacing scale keeps controls calm and easy to acquire without
/// turning a reading workspace into a wall of oversized buttons.
enum ReadingLayout {
    static let controlHeight: CGFloat = 44
    static let groupSpacing: CGFloat = 8
    static let panelPadding: CGFloat = 16
    static let panelHeaderHeight: CGFloat = 56
    static let panelTitleSize: CGFloat = 16
    static let bodySize: CGFloat = 15
    static let secondarySize: CGFloat = 13
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
    var prominent = false
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme

    func body(content: Content) -> some View {
        // Clip only the content. Clipping after this modifier would also erase
        // the outside shadow that separates floating cards from the page.
        surface(content.clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous)))
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(scheme == .dark ? 0.27 : 0.9), Palette.line.opacity(prominent ? 0.95 : 0.65)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: prominent ? 1 : 0.7)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(scheme == .dark ? (prominent ? 0.38 : 0.27) : (prominent ? 0.15 : 0.085)), radius: prominent ? 28 : 20, x: 0, y: prominent ? 14 : 8)
            .shadow(color: .black.opacity(scheme == .dark ? 0.14 : (prominent ? 0.075 : 0.04)), radius: 4, x: 0, y: 2)
    }
    @ViewBuilder private func surface<Surface: View>(_ content: Surface) -> some View {
        if reduceTransparency {
            content.background(Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else if #available(macOS 26.0, *) {
            content
                .background(Palette.surface.opacity(prominent ? (scheme == .dark ? 0.88 : 0.84) : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .glassEffect(.regular.interactive(interactive), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(Palette.surface.opacity(prominent ? 0.72 : 0), in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
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
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.accent.opacity(configuration.isPressed ? 0.18 : selected ? 0.14 : hovered ? 0.075 : 0))
                    .padding(4)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(Palette.accent.opacity(selected ? 0.15 : 0), lineWidth: 0.7)
                    .padding(4).allowsHitTesting(false)
            }
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
            .frame(minHeight: 44).frame(maxWidth: .infinity)
            .foregroundStyle(prominent ? Color.white : Palette.ink)
            .background(prominent ? Palette.accent : Palette.paper.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(prominent ? Color.white.opacity(0.22) : Palette.accent.opacity(0.14), lineWidth: 0.8) }
            .shadow(color: Palette.accent.opacity(prominent ? 0.16 : 0), radius: 10, y: 4)
            .opacity(enabled ? 1 : 0.45).scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(ReadingMotion.animation(reduce: reduceMotion), value: configuration.isPressed)
    }
}

extension View {
    func readingGlass(radius: CGFloat = 20, interactive: Bool = false, prominent: Bool = false) -> some View {
        modifier(ReadingGlassSurface(radius: radius, interactive: interactive, prominent: prominent))
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
