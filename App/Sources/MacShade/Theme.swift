import SwiftUI

/// Colours and small building blocks of the launcher's look (dark graphite, one periwinkle accent).
enum Theme {
    static let bg = Color(hex: 0x0E1014), rail = Color(hex: 0x12151B), card = Color(hex: 0x151921), raised = Color(hex: 0x1F2530)
    static let line = Color(hex: 0x232934), lineStrong = Color(hex: 0x2A303B)
    static let text = Color(hex: 0xEDEFF4), muted = Color(hex: 0x9099A8)
    static let accent = Color(hex: 0x8AA4FF), onAccent = Color(hex: 0x0B1020)
    static let good = Color(hex: 0x4ADE9A), warn = Color(hex: 0xF5B84B), bad = Color(hex: 0xFF8A8A)
    static let palette: [Color] = [0xE8863A, 0xE0555C, 0x4FB3A6, 0x6C8CF0, 0xB07CE8, 0xD9A441].map { Color(hex: $0) }

    /// Stable colour per name, so a game keeps its tile colour.
    static func tint(_ name: String) -> Color { palette[name.unicodeScalars.reduce(0) { ($0 + Int($1.value)) % palette.count }] }
    static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
        if words.count >= 2 { return words.prefix(2).compactMap { $0.first }.map { String($0).uppercased() }.joined() }
        return String(name.prefix(2)).uppercased()
    }
}

extension Color {
    init(hex: UInt32) { self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255) }
}

/// The game's own app icon (initials on a tinted tile only when no path is known).
struct GameTile: View {
    let name: String
    var path: String? = nil
    var size: CGFloat = 40
    var body: some View {
        if let path {
            Image(nsImage: gameIcon(path)).resizable().interpolation(.high).frame(width: size, height: size)
        } else {
            let c = Theme.tint(name)
            Text(Theme.initials(name)).font(.system(size: size * 0.34, weight: .heavy)).foregroundStyle(c)
                .frame(width: size, height: size).background(c.opacity(0.14), in: RoundedRectangle(cornerRadius: size * 0.28))
        }
    }
}

struct Pill: View {
    let text: String
    var color: Color = Theme.muted
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(color).lineLimit(1).fixedSize()
            .padding(.horizontal, 10).padding(.vertical, 4).background(color.opacity(0.14), in: Capsule())
    }
}

struct SoftButton: ButtonStyle {
    var tint: Color = Theme.text
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(tint)
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(configuration.isPressed ? Theme.raised : Theme.card, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.lineStrong))
    }
}

struct BigButton: ButtonStyle {
    var stop = false
    var compact = false
    var small = false   // the row of tabs: as high as a tab
    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = small ? 9 : (compact ? 10 : 14)
        configuration.label.font(.system(size: small ? 13 : (compact ? 14 : 17), weight: small ? .bold : .heavy))
            .foregroundStyle(stop ? Color(hex: 0xFFB4B4) : Theme.onAccent)
            .padding(.horizontal, small ? 13 : (compact ? 18 : 30)).padding(.vertical, small ? 7 : (compact ? 9 : 15))
            .background(stop ? Color(hex: 0x2A1518) : Theme.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(stop ? Theme.bad : .clear, lineWidth: 1.5))
    }
}

/// Quiet outlined button next to the main one (same height as `BigButton(small:)`).
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.text)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.raised : Theme.card.opacity(0.8), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Theme.lineStrong))
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 12) { content }
            .frame(maxWidth: .infinity, alignment: .leading).padding(18)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.line))
    }
}

struct SectionTitle: View {
    let title: String, subtitle: String?
    init(_ title: String, _ subtitle: String? = nil) { self.title = title; self.subtitle = subtitle }
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(LocalizedStringKey(title)).font(.system(size: 20, weight: .heavy))
            if let subtitle { Text(LocalizedStringKey(subtitle)).font(.system(size: 14)).foregroundStyle(Theme.muted) }
        }
    }
}

/// Wrapping row of chips.
struct Flow: Layout {
    var spacing: CGFloat = 8
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize { layout(proposal.width ?? 600, subviews).size }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = layout(bounds.width, subviews)
        for (i, p) in r.points.enumerated() { subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified) }
    }
    private func layout(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0, pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y)); x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowH), pts)
    }
}
