import SwiftUI

/// Original 24-point glyphs share one source with the app icon and design sheet.
/// Common platform actions keep SF Symbols; knowledge/navigation use this family.
struct BrandGlyph: View {
    var name: String
    var body: some View {
        GeometryReader { geometry in
        ZStack {
            BrandPath(commands: BrandSymbols.glyphs[name] ?? BrandSymbols.glyphs["reader"] ?? [])
                .stroke(style: StrokeStyle(lineWidth: max(1.2, min(geometry.size.width, geometry.size.height) / 24 * 1.65), lineCap: .round, lineJoin: .round))
            if name == "mark" { BrandPath(commands: BrandSymbols.glyphs["markAccent"] ?? []).fill(Palette.copper) }
        }
        }.aspectRatio(1, contentMode: .fit).accessibilityHidden(true)
    }
}

private enum BrandSymbols {
    private struct Catalog: Decodable { let glyphs: [String: [[Double]]] }
    static let glyphs: [String: [[Double]]] = {
        guard let url = ReadingBookResources.bundle?.url(forResource: "symbols", withExtension: "json", subdirectory: "Brand"),
              let data = try? Data(contentsOf: url), let catalog = try? JSONDecoder().decode(Catalog.self, from: data) else { return [:] }
        return catalog.glyphs
    }()
}

private struct BrandPath: Shape {
    var commands: [[Double]]
    func path(in rect: CGRect) -> Path {
        var path = Path()
        for c in commands {
            guard let op = c.first else { continue }
            switch Int(op) {
            case 0 where c.count == 3: path.move(to: CGPoint(x: c[1], y: c[2]))
            case 1 where c.count == 3: path.addLine(to: CGPoint(x: c[1], y: c[2]))
            case 2 where c.count == 7: path.addCurve(to: CGPoint(x: c[5], y: c[6]), control1: CGPoint(x: c[1], y: c[2]), control2: CGPoint(x: c[3], y: c[4]))
            case 3: path.closeSubpath()
            case 4 where c.count == 5: path.addEllipse(in: CGRect(x: c[1], y: c[2], width: c[3], height: c[4]))
            default: continue
            }
        }
        // Scale a 24 pt vector into the proposed frame while keeping its stroke
        // visually consistent at normal sidebar/control icon sizes.
        return path.applying(CGAffineTransform(scaleX: rect.width / 24, y: rect.height / 24).translatedBy(x: 0, y: 0))
    }
}

enum BrandNavigation {
    static func glyph(route: String) -> String {
        switch route {
        case "reader": return "reader"
        case "workflow": return "workflow"
        case "query": return "chat"
        case "editor": return "note"
        default: return route
        }
    }
}
