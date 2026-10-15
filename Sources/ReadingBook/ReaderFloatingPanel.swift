import SwiftUI

/// Only the title handle drags. The original PDF keeps its own scroll and selection.
struct ReaderFloatingPanel<Content: View>: View {
    let title: String
    let icon: String
    var width: CGFloat = 410
    var height: CGFloat = 520
    var trailing = true
    @Binding var isPresented: Bool
    var viewport: CGSize
    var onExpansionChange: (Bool) -> Void = { _ in }
    @ViewBuilder var content: () -> Content
    @State private var collapsed = false
    @State private var hasOpened = false
    @State private var savedOrigin: CGPoint?
    @State private var dragStart: CGPoint?
    @State private var epoch = 0

    private var panelWidth: CGFloat { min(width, max(240, viewport.width - 100)) }
    private var panelHeight: CGFloat { collapsed ? 58 : min(height, max(120, viewport.height - 190)) }
    private var origin: CGPoint { clamp(savedOrigin ?? CGPoint(x: trailing ? viewport.width - panelWidth - 24 : 76, y: 100)) }
    private func clamp(_ point: CGPoint) -> CGPoint {
        CGPoint(x: min(max(24, point.x), max(24, viewport.width - panelWidth - 24)),
                y: min(max(88, point.y), max(88, viewport.height - panelHeight - 88)))
    }
    var body: some View {
        ZStack(alignment: .topLeading) {
            if isPresented {
                VStack(spacing: 0) {
                    HStack(spacing: 6) {
                        HStack(spacing: 10) { Image(systemName: "line.3.horizontal").font(.system(size: 11)).foregroundStyle(.tertiary); Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold)); Spacer(minLength: 0) }
                            .overlay {
                                FloatingPanelPointerInput(epoch: epoch, begin: { dragStart = origin }, drag: { delta, finished in
                                    let start = dragStart ?? origin
                                    savedOrigin = clamp(CGPoint(x: start.x + delta.width, y: start.y + delta.height))
                                    if finished { dragStart = nil }
                                }, cancel: { if let dragStart { savedOrigin = dragStart }; dragStart = nil })
                            }
                        Button { collapsed.toggle() } label: { Image(systemName: collapsed ? "plus" : "minus") }.buttonStyle(ReadingToolbarButtonStyle()).help(collapsed ? "展开\(title)" : "收起\(title)")
                        Button { isPresented = false } label: { Image(systemName: "xmark") }.buttonStyle(ReadingToolbarButtonStyle()).help("关闭\(title)")
                    }.padding(.leading, 16).padding(.trailing, 6).frame(height: 58)
                    if !collapsed { content().frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(width: panelWidth, height: panelHeight).readingGlass(radius: 22)
                    .clipShape(RoundedRectangle(cornerRadius: 22)).position(x: origin.x + panelWidth / 2, y: origin.y + panelHeight / 2)
            } else if hasOpened {
                Button { collapsed = false; isPresented = true } label: { Label(title, systemImage: icon) }
                    .buttonStyle(ReadingToolbarButtonStyle()).readingGlass(radius: 18)
                    .position(x: trailing ? max(100, viewport.width - 90) : 130, y: trailing ? max(100, viewport.height - 108) : 110)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .onAppear { hasOpened = isPresented; if viewport.width < 1050 && trailing { isPresented = false } }
            .onChange(of: collapsed) { _, value in onExpansionChange(!value && isPresented) }
            .onChange(of: isPresented) { _, value in if value { hasOpened = true }; onExpansionChange(value && !collapsed) }
            .onChange(of: viewport) { old, value in
                epoch += 1; dragStart = nil; savedOrigin = clamp(savedOrigin ?? origin)
                if old.width >= 1050, value.width < 1050, trailing { isPresented = false }
            }
    }
}
