import SwiftUI
import ReadingCore

struct BookCoverCropRequest: Identifiable {
    let id = UUID()
    let project: BookProject
    let owner: WorkspacePickerOwner
    let image: BookCoverCropImage
}

struct BookCoverCropView: View {
    @EnvironmentObject private var store: AppStore
    let request: BookCoverCropRequest
    let close: () -> Void
    @State private var zoom = 1.0
    @State private var pan = CGSize.zero
    @GestureState private var drag = CGSize.zero
    @State private var applying = false
    let previewWidth: CGFloat
    private var size: CGSize { CGSize(width: previewWidth, height: previewWidth / BookCoverCropGeometry.aspectRatio) }
    private var frame: CGRect {
        BookCoverCropGeometry.frame(image: CGSize(width: request.image.image.width, height: request.image.image.height), viewport: size,
            zoom: zoom, panX: pan.width, panY: pan.height) ?? .zero
    }
    private var offset: CGSize {
        CGSize(width: min(max(0, (frame.width - size.width) / 2), max(-(frame.width - size.width) / 2, frame.midX - size.width / 2 + drag.width)),
               height: min(max(0, (frame.height - size.height) / 2), max(-(frame.height - size.height) / 2, frame.midY - size.height / 2 + drag.height)))
    }
    var body: some View {
        VStack(spacing: 18) {
            ZStack {
                Image(decorative: request.image.image, scale: 1)
                    .resizable().frame(width: frame.width, height: frame.height).offset(offset)
            }.frame(width: size.width, height: size.height).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Palette.line, lineWidth: 1).allowsHitTesting(false) }
                .contentShape(Rectangle()).gesture(DragGesture(minimumDistance: 0)
                    .updating($drag) { value, state, _ in state = value.translation }
                    .onEnded { value in
                        let x = max(0, (frame.width - size.width) / 2), y = max(0, (frame.height - size.height) / 2)
                        pan = CGSize(width: x > 0 ? min(1, max(-1, pan.width + value.translation.width / x)) : 0,
                                     height: y > 0 ? min(1, max(-1, pan.height + value.translation.height / y)) : 0)
                    })
                .accessibilityLabel("拖动封面调整位置")
                .accessibilityIdentifier("cover-crop-preview")
            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass").foregroundStyle(.secondary)
                Slider(value: $zoom, in: 1...4).accessibilityLabel("封面缩放")
                Image(systemName: "plus.magnifyingglass").foregroundStyle(.secondary)
            }.frame(width: previewWidth).help("拖动图片调整位置，滑动调节缩放。")
            HStack(spacing: 12) {
                Spacer()
                Button("取消", action: close).buttonStyle(ReadingToolbarButtonStyle()).keyboardShortcut(.cancelAction)
                Button("应用") { apply() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("cover-crop-apply")
            }.controlSize(.large)
        }.padding(24).frame(width: previewWidth + 48).background(Palette.surface)
            .disabled(applying)
            .onChange(of: store.collectionOwnerKey) { _, _ in close() }
    }
    private func apply() {
        guard !applying, request.owner.matches(store) else { close(); return }
        applying = true
        let zoom = zoom, pan = pan
        Task { @MainActor in
            do {
                let bytes = try await Task.detached(priority: .userInitiated) { try request.image.jpeg(zoom: zoom, panX: pan.width, panY: pan.height) }.value
                if await store.applyBookCoverCrop(request, bytes: bytes) { close() }
            } catch { if request.owner.matches(store) { store.errorMessage = error.localizedDescription } }
            applying = false
        }
    }
}
