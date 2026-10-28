import SwiftUI

/// A single-line native field keeps its intrinsic text height inside the
/// surrounding search surface. Giving it the whole 44–52 point row height can
/// leave the native placeholder at the top while the symbol stays centered.
private struct ReadingSearchInputStyle: ViewModifier {
    var pointSize: CGFloat
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: pointSize))
            .lineLimit(1).fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension View {
    func readingSearchInput(pointSize: CGFloat = 15) -> some View {
        modifier(ReadingSearchInputStyle(pointSize: pointSize))
    }
    func readingSearchIcon(pointSize: CGFloat = 15) -> some View {
        font(.system(size: pointSize)).foregroundStyle(.secondary)
            .frame(width: 20, alignment: .center)
    }
}
