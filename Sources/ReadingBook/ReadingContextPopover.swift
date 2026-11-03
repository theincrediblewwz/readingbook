import AppKit
import SwiftUI

struct ReadingContextAction: Identifiable {
    let title: String
    let icon: String
    var destructive = false
    var action: @MainActor () -> Void
    var id: String { title }
}

/// The same generous, Chinese reading controls are used on the original page
/// and on a paper slip. No PDFKit system actions are inserted into this list.
@MainActor final class ReadingContextPopover {
    private var popover: NSPopover?
    func close() { popover?.close(); popover = nil }
    func show(_ actions: [ReadingContextAction], at point: CGPoint, in view: NSView) {
        close()
        guard view.window != nil, !actions.isEmpty else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        // Context actions should be ready at selection release. The standard
        // popover reveal otherwise adds roughly half a second after layout.
        popover.animates = false
        let size = CGSize(width: 280, height: CGFloat(actions.count) * 48 + CGFloat(actions.count - 1) * 4 + 20)
        let controller = NSHostingController(rootView:
            VStack(spacing: 4) {
                ForEach(actions) { item in
                    Button { [weak self] in self?.close(); item.action() } label: {
                        HStack(spacing: 13) {
                            Image(systemName: item.icon).font(.system(size: 17)).frame(width: 23)
                                .foregroundStyle(item.destructive ? Palette.copper : Palette.accent)
                            Text(item.title).font(.system(size: 15)).frame(maxWidth: .infinity, alignment: .leading)
                        }.padding(.horizontal, 14).frame(minHeight: 48).contentShape(RoundedRectangle(cornerRadius: 12))
                    }.buttonStyle(ReadingQuietButtonStyle()).help(item.title)
                }
            }.padding(10).frame(width: size.width, height: size.height).background(Palette.surface)
                .modifier(ReadingPreferencesEnvironment()))
        // Resolve the hosting view before AppKit positions the arrow. Its
        // default first size can otherwise be replaced after show(), growing
        // the menu away from the actual mouse position.
        controller.view.frame = CGRect(origin: .zero, size: size)
        popover.contentViewController = controller
        popover.contentSize = size
        self.popover = popover
        popover.show(relativeTo: CGRect(origin: point, size: .init(width: 1, height: 1)), of: view, preferredEdge: .maxY)
    }
}

/// Native clicks avoid an overlay swallowing the paper gesture. Hover remains
/// with SwiftUI for the fan lift; the same editor action is exposed to AX.
struct ReadingPaperContextAnchor: NSViewRepresentable {
    let actions: [ReadingContextAction]
    var primary: (() -> Void)? = nil
    var clickCount = 1
    var primaryAtFrame: ((CGRect) -> Void)? = nil
    var actionsAtFrame: ((CGRect) -> [ReadingContextAction])? = nil
    func makeNSView(context: Context) -> Anchor { Anchor() }
    func updateNSView(_ view: Anchor, context: Context) {
        view.actions = actions; view.primary = primary; view.clickCount = clickCount
        view.primaryAtFrame = primaryAtFrame; view.actionsAtFrame = actionsAtFrame
    }
    static func dismantleNSView(_ view: Anchor, coordinator: ()) { view.presenter.close() }
    final class Anchor: NSView {
        var actions: [ReadingContextAction] = []
        var primary: (() -> Void)?
        var clickCount = 1
        var primaryAtFrame: ((CGRect) -> Void)?
        var actionsAtFrame: ((CGRect) -> [ReadingContextAction])?
        let presenter = ReadingContextPopover()
        var screenFrame: CGRect { window.map { $0.convertToScreen(convert(bounds, to: nil)) } ?? .zero }
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard NSApp.currentEvent?.type == .rightMouseDown || (NSApp.currentEvent?.type == .leftMouseDown && (primary != nil || primaryAtFrame != nil)),
                  bounds.contains(convert(point, from: superview)) else { return nil }
            return self
        }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == clickCount { if let primaryAtFrame { primaryAtFrame(screenFrame) } else { primary?() } }
        }
        override func rightMouseDown(with event: NSEvent) {
            presenter.show(actionsAtFrame?(screenFrame) ?? actions, at: convert(event.locationInWindow, from: nil), in: self)
        }
        override func menu(for event: NSEvent) -> NSMenu? { nil }
    }
}
