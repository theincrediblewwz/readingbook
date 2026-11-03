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
    static func value(for style: ReaderAnnotationLineStyle) -> ReaderUnderlineAppearance {
        guard let bytes = UserDefaults.standard.data(forKey: key(for: style)),
              let value = try? JSONDecoder().decode(ReaderUnderlineAppearance.self, from: bytes), value.isValid else { return Self.value }
        return value
    }
    static func save(_ value: ReaderUnderlineAppearance, for style: ReaderAnnotationLineStyle) {
        guard value.isValid, let bytes = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(bytes, forKey: key(for: style))
    }
    private static func key(for style: ReaderAnnotationLineStyle) -> String { "reader.underlineAppearance.\(style.rawValue).v1" }
}

@MainActor enum ReaderHighlightDefaults {
    static let key = "reader.highlightAppearance.v1"
    static var value: ReaderHighlightAppearance {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(ReaderHighlightAppearance.self, from: data), value.isValid else { return .init() }
        return value
    }
    static func save(_ value: ReaderHighlightAppearance) {
        guard value.isValid, let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }
}

struct ReaderUnderlineStyleView: View {
    @State private var value: ReaderUnderlineAppearance
    @State private var lineStyle: ReaderAnnotationLineStyle
    @State private var drafts: [ReaderAnnotationLineStyle: ReaderUnderlineAppearance]
    private let originals: [ReaderAnnotationLineStyle: ReaderUnderlineAppearance]
    private let existingStyles: Set<ReaderAnnotationLineStyle>
    var onApply: ([ReaderAnnotationLineStyle: ReaderUnderlineAppearance]) async -> Bool
    var onCancel: () -> Void
    @State private var highlight: ReaderHighlightAppearance
    var onApplyHighlight: ((ReaderHighlightAppearance) async -> Bool)? = nil
    @State private var showsHighlight = false
    @State private var saving = false
    private let colors: [(Double, Double, Double)] = [(0.16,0.42,0.75),(0.1,0.57,0.48),(0.72,0.31,0.27),(0.65,0.42,0.12),(0.52,0.36,0.72),(0.25,0.28,0.31)]
    private var color: Color { Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 1) }
    private var editsExisting: Bool { existingStyles.contains(lineStyle) }
    init(appearances: [ReaderAnnotationLineStyle: ReaderUnderlineAppearance], existingStyles: Set<ReaderAnnotationLineStyle>, initialStyle: ReaderAnnotationLineStyle,
         onApply: @escaping ([ReaderAnnotationLineStyle: ReaderUnderlineAppearance]) async -> Bool, onCancel: @escaping () -> Void,
         highlight: ReaderHighlightAppearance, onApplyHighlight: ((ReaderHighlightAppearance) async -> Bool)? = nil) {
        originals = appearances; self.existingStyles = existingStyles
        _drafts = State(initialValue: appearances); _lineStyle = State(initialValue: initialStyle)
        _value = State(initialValue: appearances[initialStyle] ?? .init())
        _highlight = State(initialValue: highlight)
        self.onApply = onApply; self.onCancel = onCancel; self.onApplyHighlight = onApplyHighlight
    }
    private func select(_ style: ReaderAnnotationLineStyle) {
        drafts[lineStyle] = value
        value = drafts[style] ?? .init(); lineStyle = style; showsHighlight = false
    }
    private var changes: [ReaderAnnotationLineStyle: ReaderUnderlineAppearance] {
        var values = drafts; values[lineStyle] = value
        return values.filter { $0.key == lineStyle || $0.value != originals[$0.key] }.mapValues { value in
            var line = value; line.highlighter = false; return line
        }
    }
    var body: some View {
        VStack(spacing: 18) {
            HStack {
                Text("标记样式").font(.title3.weight(.semibold)); Spacer()
                Image(systemName: "info.circle").foregroundStyle(.secondary)
                    .help("直线、波浪线与荧光分别设置。切换不会丢失未应用的划线调整；应用时保存本次调整，对应的当前划线也会更新，其他原有标记保持原样。")
            }
            HStack(spacing: 8) {
                ForEach(ReaderAnnotationLineStyle.allCases, id: \.self) { style in
                    Button { select(style) } label: {
                        Label(style == .straight ? "直线" : "波浪线", systemImage: style == .straight ? "underline" : "water.waves")
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(Palette.accent.opacity(!showsHighlight && lineStyle == style ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(ReadingQuietButtonStyle()).accessibilityValue(!showsHighlight && lineStyle == style ? "已选中" : "未选中")
                        .help(style == .straight ? "设置直线的颜色、粗细和深浅" : "设置波浪线的颜色、粗细、深浅和波浪间距")
                }
                Button { showsHighlight = true } label: {
                    Label("荧光", systemImage: "highlighter").frame(maxWidth: .infinity, minHeight: 36)
                        .background(Palette.accent.opacity(showsHighlight ? 0.1 : 0.025), in: RoundedRectangle(cornerRadius: 10))
                }.buttonStyle(ReadingQuietButtonStyle()).accessibilityValue(showsHighlight ? "已选中" : "未选中")
                    .help("设置独立荧光标记的颜色、鲜艳程度与明暗")
            }
            if showsHighlight {
                highlightControls
            } else {
            VStack(spacing: 8) {
                Text("让值得留意的句子，轻轻留下痕迹。")
                    .font(.system(size: 19, design: .serif)).foregroundStyle(.primary)
                    .padding(.horizontal, 10)
                UnderlineStylePreview(value: value, lineStyle: lineStyle).frame(height: 12).padding(.horizontal, 10)
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
                .disabled(lineStyle == .straight).opacity(lineStyle == .straight ? 0.4 : 1)
                .help("仅影响波浪线的间距")
            HStack(spacing: 24) {
                Toggle("边缘微光", isOn: $value.glow).help("给线条加一层轻微柔光")
            }.toggleStyle(.switch).controlSize(.small)
            }
            HStack {
                Text(showsHighlight ? "独立荧光标记" : editsExisting ? "当前划线与同类新划线" : "同类新划线的默认样式").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消", action: onCancel).buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                Button("应用") { saving = true; Task { if showsHighlight { _ = await onApplyHighlight?(highlight) } else { _ = await onApply(changes) }; saving = false } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 476).background(Palette.surface).disabled(saving)
    }
    private var highlightControls: some View {
        VStack(spacing: 18) {
            Text("让值得留意的句子，轻轻留下痕迹。")
                .font(.system(size: 19, design: .serif)).foregroundStyle(Color.black.opacity(0.8))
                .padding(14).background(Color(nsColor: highlight.nativeColor), in: RoundedRectangle(cornerRadius: 9))
            ColorPicker("荧光颜色", selection: Binding(get: { Color(.sRGB, red: highlight.red, green: highlight.green, blue: highlight.blue) }, set: {
                if let rgb = NSColor($0).usingColorSpace(.sRGB) { highlight.red = rgb.redComponent; highlight.green = rgb.greenComponent; highlight.blue = rgb.blueComponent }
            }), supportsOpacity: false).help("选择荧光标记的颜色，与下划线分别保存")
            slider("深浅", value: $highlight.opacity, range: 0.05...0.8, text: "\(Int(highlight.opacity * 100))%")
            slider("鲜艳", value: $highlight.saturation, range: 0...2, text: "\(Int(highlight.saturation * 100))%")
            slider("明暗", value: $highlight.brightness, range: 0.5...1.5, text: "\(Int(highlight.brightness * 100))%")
        }.padding(.vertical, 8)
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
    let lineStyle: ReaderAnnotationLineStyle
    var body: some View {
        Canvas { context, size in
            var path = Path(); path.move(to: CGPoint(x: 0, y: size.height / 2))
            if lineStyle == .straight { path.addLine(to: CGPoint(x: size.width, y: size.height / 2)) }
            else {
                for i in 1...400 {
                    let x = size.width * Double(i) / 400
                    path.addLine(to: CGPoint(x: x, y: size.height / 2 + sin(x * 2 * .pi / (value.waveLength * 2)) * 1.5))
                }
            }
            if value.glow { context.addFilter(.shadow(color: Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: 0.4), radius: 3)) }
            context.stroke(path, with: .color(Color(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.opacity)), style: StrokeStyle(lineWidth: value.thickness * 1.5, lineCap: .round))
        }
    }
}
