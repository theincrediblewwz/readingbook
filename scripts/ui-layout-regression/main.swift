import AppKit
import SwiftUI

private struct ReduceMotionKey: EnvironmentKey { static let defaultValue = false }
private struct ReduceTransparencyKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
  var readingReduceMotion: Bool {
    get { self[ReduceMotionKey.self] }
    set { self[ReduceMotionKey.self] = newValue }
  }
  var readingReduceTransparency: Bool {
    get { self[ReduceTransparencyKey.self] }
    set { self[ReduceTransparencyKey.self] = newValue }
  }
}
enum Palette {
  static let line = Color.gray.opacity(0.3), surface = Color.white, accent = Color.blue,
    ink = Color.primary, paper = Color.white
}

@MainActor enum MountCounts {
  static var made = 0
  static var removed = 0
  static var layouts = 0
}
struct MountCounter: NSViewRepresentable {
  func makeNSView(context: Context) -> NSView {
    MountCounts.made += 1
    return NSView(frame: .zero)
  }
  func updateNSView(_ v: NSView, context: Context) {}
  static func dismantleNSView(_ v: NSView, coordinator: ()) { MountCounts.removed += 1 }
}
@MainActor final class ProbeState: ObservableObject {
  @Published var tick = 0
  @Published var width: CGFloat = 376
  @Published var open = false
  @Published var tab = false
  @Published var collapsed = false
}

struct Companion: View {
  let model: ProbeState
  let stableToolbar: Bool
  var selectors: some View {
    Group {
      Menu {
        Button("解释与译文") {}
        Button("原文对象") {}
        Button("资料对读") {}
      } label: {
        Label("解释与译文", systemImage: "text.book.closed").font(.system(size: 15, weight: .medium))
          .frame(minHeight: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter()).help("选择伴读内容")
      Menu {
        Button("当前页") {}
        Button("当前章节") {}
      } label: {
        Label("当前页", systemImage: "book.closed").font(.system(size: 13, weight: .medium)).frame(
          minHeight: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter()).help("第 182 页 · 行 1–21")
    }
  }
  var tools: some View {
    Group {
      Menu {
        Button("放大文字") {}
        Button("缩小文字") {}
        Button("恢复默认") {}
      } label: {
        Image(systemName: "textformat.size").frame(width: 32, height: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
      Button {
      } label: {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
      }.buttonStyle(ReadingToolbarButtonStyle())
      Button {
      } label: {
        Image(systemName: "info.circle")
      }.buttonStyle(ReadingToolbarButtonStyle())
    }
  }
  @ViewBuilder var body: some View {
    VStack(spacing: 0) {
      if stableToolbar {
        ReadingAdaptiveRows(horizontalSpacing: 8, rowSpacing: 0) {
          HStack(spacing: 8) {
            selectors
            Spacer(minLength: 0)
          }
          HStack(spacing: 8) {
            Spacer(minLength: 0)
            tools
          }
        }
      } else {
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            selectors
            Spacer(minLength: 0)
            tools
          }
          VStack(spacing: 0) {
            HStack(spacing: 8) {
              selectors
              Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
              Spacer(minLength: 0)
              tools
            }
          }
        }
      }
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 18) {
          Image(systemName: "sparkles")
          Text("这一页，还可以读得更深\n生成解释，或围绕当前内容提一个问题。")
          ForEach(0..<3) { i in Text("固定内容 \(i)") }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
      }
      Divider().opacity(0.4)
      HStack(spacing: 10) {
        Button {
        } label: {
          Label("问这部分", systemImage: "bubble.left").frame(maxWidth: .infinity)
        }.buttonStyle(ReadingActionButtonStyle())
        Button {
        } label: {
          Label("生成解释", systemImage: "sparkles").frame(maxWidth: .infinity)
        }.buttonStyle(ReadingActionButtonStyle(prominent: true))
        Menu {
          Button("为这部分记笔记") {}
        } label: {
          Image(systemName: "ellipsis").frame(width: 44, height: 48)
        }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
      }.padding(16).fixedSize(horizontal: false, vertical: true)
    }.padding(.horizontal, 16).padding(.bottom, 4)
  }
}
struct Chat: View {
  @State private var draft = ""
  var scope: some View {
    Group {
      Menu {
        Button("当前页") {}
        Button("全书") {}
      } label: {
        Label("当前页", systemImage: "doc.text").font(.system(size: 13)).frame(minHeight: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
      Button {
      } label: {
        Image(systemName: "paperclip")
      }.buttonStyle(ReadingToolbarButtonStyle())
    }
  }
  var modes: some View {
    Group {
      Menu {
        Button("纯阅读") {}
        Button("功能协作") {}
      } label: {
        Label("纯阅读", systemImage: "book").font(.system(size: 13)).frame(minHeight: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
      Menu {
        Button("老师伴读") {}
        Button("原文考据") {}
      } label: {
        Label("老师伴读", systemImage: "sparkles").font(.system(size: 13)).frame(minHeight: 44)
      }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
    }
  }
  var send: some View {
    Button {
    } label: {
      Image(systemName: "arrow.up")
    }.buttonStyle(ReadingToolbarButtonStyle())
  }
  var options: some View {
    Menu {
      Button("字号") {}
      Button("权限") {}
    } label: {
      Image(systemName: "ellipsis").frame(width: 44, height: 44)
    }.menuStyle(.borderlessButton).fixedSize().background(MountCounter())
  }
  var suggestions: some View {
    HStack {
      Button("这一部分在讲什么？") {}
      Button("有哪些重要概念？") {}
      Button("这些线索如何联系？") {}
    }
  }
  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Spacer()
        Button {
        } label: {
          Label("放大对话", systemImage: "arrow.up.left.and.arrow.down.right").font(.system(size: 13))
        }.buttonStyle(ReadingToolbarButtonStyle()).fixedSize()
      }.padding(.horizontal, 12).padding(.vertical, 4)
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 20) {
            VStack(spacing: 16) {
              Image(systemName: "bubble.left.and.bubble.right")
              Text("想从这本书里弄懂什么？").font(.system(size: 18, weight: .semibold))
              ViewThatFits(in: .horizontal) {
                suggestions
                VStack(spacing: 8) {
                  Button("这一部分在讲什么？") {}
                  Button("有哪些重要概念？") {}
                  Button("这些线索如何联系？") {}
                }
              }
            }.padding(.vertical, 32).frame(maxWidth: .infinity, minHeight: 180)
          }.padding(16).frame(maxWidth: 940).frame(maxWidth: .infinity)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        TextField("围绕所选内容，问一个问题…", text: $draft, axis: .vertical).font(.system(size: 15)).lineLimit(
          1...5
        ).textFieldStyle(.plain).frame(minHeight: 44)
        ViewThatFits(in: .horizontal) {
          HStack(spacing: 8) {
            scope
            Spacer(minLength: 4)
            modes
            options
            send
          }
          VStack(spacing: 4) {
            HStack(spacing: 8) {
              scope
              Spacer(minLength: 0)
              send
            }
            HStack(spacing: 8) {
              modes
              Spacer(minLength: 0)
              options
            }
          }
        }
      }.padding(12).background(Color.white.opacity(0.65), in: RoundedRectangle(cornerRadius: 16))
        .overlay {
          RoundedRectangle(cornerRadius: 16).strokeBorder(Color.gray.opacity(0.2), lineWidth: 0.7)
        }.frame(maxWidth: 900).padding(.horizontal, 12).padding(.bottom, 12)
    }
  }
}
/// The inactive chat stays mounted exactly as in ReaderAIPanel.
struct ProbeRoot: View {
  @ObservedObject var model: ProbeState
  let glass: Bool, stableToolbar: Bool, overlayHidden: Bool
  var ai: some View {
    VStack(spacing: 0) {
      HStack {
        Button("伴读") {}
        Button("对话") {}
      }.padding(12)
      if overlayHidden {
        Companion(model: model, stableToolbar: stableToolbar).overlay {
          Chat().opacity(model.tab ? 1 : 0).disabled(!model.tab)
        }
      } else {
        ZStack {
          Companion(model: model, stableToolbar: stableToolbar).opacity(model.tab ? 0 : 1).disabled(
            model.tab)
          Chat().opacity(model.tab ? 1 : 0).disabled(!model.tab)
        }.frame(minHeight: 0, maxHeight: .infinity)
      }
    }
  }
  var panel: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Label("伴读与对话", systemImage: "sparkles").font(.system(size: 16, weight: .semibold))
          .lineLimit(1).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        Button {
        } label: {
          Image(systemName: "minus")
        }.buttonStyle(ReadingToolbarButtonStyle())
      }.padding(.horizontal, 16).frame(height: 56).layoutPriority(1)
      ai.frame(maxWidth: .infinity).frame(minHeight: 0, maxHeight: model.collapsed ? 0 : .infinity)
        .opacity(model.collapsed ? 0 : 1).clipped().allowsHitTesting(!model.collapsed).disabled(
          model.collapsed || !model.open)
    }.frame(width: model.width, height: model.collapsed ? 56 : 620)
  }
  @ViewBuilder var body: some View {
    GeometryReader { geo in
      ZStack(alignment: .topLeading) {
        Color.white.frame(maxWidth: .infinity, maxHeight: .infinity)
        if glass {
          panel.readingGlass(radius: 24, prominent: true).position(
            x: geo.size.width - model.width / 2 - 24, y: 410
          ).opacity(model.open ? 1 : 0).scaleEffect(model.open ? 1 : 0.97, anchor: .topTrailing)
        } else {
          panel.position(x: geo.size.width - model.width / 2 - 24, y: 410).opacity(
            model.open ? 1 : 0
          ).scaleEffect(model.open ? 1 : 0.97, anchor: .topTrailing)
        }
      }.animation(.snappy(duration: 0.24, extraBounce: 0.04), value: model.open).animation(
        .snappy(duration: 0.24, extraBounce: 0.04), value: model.collapsed)
    }.background(FrostWindowAppearance())
  }
}
@MainActor final class ProbeHostingView: NSHostingView<ProbeRoot> {
  var layouts = 0
  override func layout() {
    layouts += 1
    MountCounts.layouts = layouts
    if layouts.isMultiple(of: 100) {
      print(
        "layout \(layouts) tick=\(rootView.model.tick) make=\(MountCounts.made) dismantle=\(MountCounts.removed)"
      )
      fflush(stdout)
    }
    super.layout()
  }
}
@main enum Probe {
  @MainActor static func main() {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = ProbeState()
    let args = CommandLine.arguments
    let root = ProbeRoot(
      model: model, glass: !args.contains("--no-glass"),
      stableToolbar: !args.contains("--baseline"),
      overlayHidden: args.contains("--overlay"))
    let win = NSWindow(
      contentRect: NSRect(
        x: args.contains("--visible") ? 60 : -10000, y: args.contains("--visible") ? 60 : -10000,
        width: 1470, height: 843),
      styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    win.title = "ReadingBook UI layout regression"
    let host = ProbeHostingView(rootView: root)
    win.contentView = host
    win.orderFront(nil)
    print("START \(args)")
    fflush(stdout)
    Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
      MainActor.assumeIsolated {
        model.tick += 1
        if model.tick.isMultiple(of: 5) { model.open.toggle() }
        if model.tick.isMultiple(of: 3) {
          model.width = [240, 290, 320, 350, 376, 400, 450, 520, 760][(model.tick / 3) % 9]
        }
        if model.tick.isMultiple(of: 7) { model.tab.toggle() }
        if model.tick.isMultiple(of: 11) { model.collapsed.toggle() }
        if model.tick >= 100 {
          print(
            "DONE tick=\(model.tick) layouts=\(MountCounts.layouts) make=\(MountCounts.made) dismantle=\(MountCounts.removed)"
          )
          fflush(stdout)
          app.terminate(nil)
        }
      }
    }
    app.run()
  }
}
