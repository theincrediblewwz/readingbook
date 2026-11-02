import SwiftUI
import ReadingCore

@MainActor enum ReaderUnderlineDefaults {
    static let key = "reader.underlineAppearance.v1"
    static var value: ReaderUnderlineAppearance {
        guard let bytes = UserDefaults.standard.data(forKey: key),
              let value = try? JSONDecoder().decode(ReaderUnderlineAppearance.self, from: bytes), value.isValid else { return .init() }
        return value
    }
    static func save(_ value: ReaderUnderlineAppearance) {
        guard value.isValid, let bytes = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(bytes, forKey: key)
    }
}

struct ReaderUnderlineStyleView: View {
    @State var value: ReaderUnderlineAppearance
    let editsExisting: Bool
    var onApply: (ReaderUnderlineAppearance) async -> Bool
    var onCancel: () -> Void
    @State private var saving = false
    private let colors: [(Double, Double, Double)] = [(0.16,0.42,0.75),(0.1,0.57,0.48),(0.72,0.31,0.27),(0.65,0.42,0.12),(0.52,0.36,0.72),(0.25,0.28,0.31)]
    private var color: Color { Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1) }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("下划线样式").font(.title3.weight(.semibold)); Spacer()
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help(editsExisting ? "应用到这条下划线，同时作为新划线的默认样式。原文位置不会改变。" : "作为新划线的默认样式。已有划线保持原样。")
            }
            VStack(spacing: 8) {
                Text("让值得留意的句子，轻轻留下痕迹。")
                    .font(.system(size: 19, design: .serif)).foregroundStyle(.primary)
                    .padding(.horizontal, 10).background(value.highlighter ? color.opacity(value.opacity * 0.2) : .clear)
                UnderlineStylePreview(value: value).frame(height: 12).padding(.horizontal, 10)
            }.padding(.vertical, 18).frame(maxWidth: .infinity)
                .background(Palette.paper, in: RoundedRectangle(cornerRadius: 14))
            HStack(spacing: 12) {
                Text("颜色").frame(width: 44, alignment: .leading)
                ForEach(colors.indices, id: \.self) { index in
                    let rgb = colors[index]
                    Button { value.red = rgb.0; value.green = rgb.1; value.blue = rgb.2 } label: {
                        Circle().fill(Color(.sRGB, red: rgb.0, green: rgb.1, blue: rgb.2, opacity: 1)).frame(width: 22, height: 22)
                            .padding(4).overlay { Circle().strokeBorder(Color.primary.opacity(value.red == rgb.0 && value.green == rgb.1 && value.blue == rgb.2 ? 0.5 : 0), lineWidth: 1) }
                    }.buttonStyle(ReadingQuietButtonStyle()).help("选择预设颜色 \(index + 1)")
                }
                ColorPicker("调色盘", selection: Binding(get: { color }, set: { color in
                    guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    value.red = rgb.redComponent; value.green = rgb.greenComponent; value.blue = rgb.blueComponent
                }), supportsOpacity: false).labelsHidden().help("打开调色盘，选择其他颜色")
            }
            slider("粗细", value: $value.thickness, range: 0.35...4, text: String(format: "%.1f", value.thickness))
            slider("深浅", value: $value.opacity, range: 0.15...1, text: "\(Int(value.opacity * 100))%")
            slider("波浪间距", value: $value.waveLength, range: 2...18, text: String(format: "%.0f", value.waveLength))
            HStack(spacing: 24) {
                Toggle("荧光笔底色", isOn: $value.highlighter).help("在字的下层增加同色浅底，不盖住文字")
                Toggle("边缘微光", isOn: $value.glow).help("给线条加一层轻微柔光")
            }.toggleStyle(.switch).controlSize(.small)
            HStack {
                Text(editsExisting ? "当前划线与新划线" : "新划线默认样式").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button("应用") { saving = true; Task { _ = await onApply(value); saving = false } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 476).background(Palette.surface).disabled(saving)
    }
    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, text: String) -> some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 64, alignment: .leading)
            Slider(value: value, in: range).help("调整" + title)
            Text(text).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary).frame(width: 40, alignment: .trailing)
        }
    }
}

private struct UnderlineStylePreview: View {
    let value: ReaderUnderlineAppearance
    var body: some View {
        Canvas { context, size in
            var path = Path(); path.move(to: CGPoint(x: 0, y: size.height / 2))
            for i in 1...400 {
                let x = size.width * Double(i) / 400
                path.addLine(to: CGPoint(x: x, y: size.height / 2 + sin(x * 2 * .pi / (value.waveLength * 2)) * 1.5))
            }
            if value.glow { context.addFilter(.shadow(color: Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 0.4), radius: 3)) }
            context.stroke(path, with: .color(Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.opacity)), style: StrokeStyle(lineWidth: value.thickness * 1.5, lineCap: .round))
        }
    }
}
