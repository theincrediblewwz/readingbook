import SwiftUI

private struct ReaderFindActionKey: FocusedValueKey { typealias Value = () -> Void }
extension FocusedValues {
    var readerFindAction: (() -> Void)? {
        get { self[ReaderFindActionKey.self] }
        set { self[ReaderFindActionKey.self] = newValue }
    }
}
struct ReaderKeyboardCommands: Commands {
    @FocusedValue(\.readerFindAction) private var find
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("查找 PDF 文字") { find?() }.keyboardShortcut("f", modifiers: .command).disabled(find == nil)
        }
    }
}
