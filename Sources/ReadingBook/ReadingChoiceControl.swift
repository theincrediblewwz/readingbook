import SwiftUI

/// One roomy custom popover for in-app choices. Native context menus and the
/// macOS menu bar retain system behavior; no alternate Menu sizing probes.
struct ReadingChoiceControl: View {
    let title: String
    let icon: String
    let options: [ManagementActionOption]
    var owner: String
    var iconOnly = false
    var fontSize: CGFloat = 13
    var select: (String) -> Void
    @State private var presented = false
    @State private var presentedOwner = ""
    @Environment(\.isEnabled) private var enabled
    var body: some View {
        Button { presentedOwner = owner; presented = true } label: {
            HStack(spacing: 5) {
                Image(systemName: icon)
                if !iconOnly { Text(title).lineLimit(1); Image(systemName: "chevron.down").font(.system(size: 9)) }
            }.font(.system(size: fontSize, weight: .medium)).frame(minWidth: iconOnly ? 32 : nil, minHeight: 44)
        }.buttonStyle(ReadingQuietButtonStyle()).fixedSize().accessibilityLabel(title)
            .popover(isPresented: $presented) {
                ManagementActionPopover(title: title, options: options, width: 360, close: { presented = false }) { id in
                    guard enabled, presentedOwner == owner, options.contains(where: { $0.id == id && $0.enabled }) else { return }
                    presented = false; select(id)
                }
            }.onChange(of: owner) { _, _ in presented = false }
            .onChange(of: enabled) { _, value in if !value { presented = false } }
    }
}
