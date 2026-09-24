import AppKit
import SwiftUI

// The same public names as cortana/clients/apple/Shared/Theme.swift (Theme.bg, .ink, .accent,
// StatePill…), so these views can move into Cortana's Mac app without edits. Values come only from
// Tokens.swift; no hex below.

enum Theme {
    typealias Space = DesignTokens.Space
    typealias Radius = DesignTokens.Radius

    static let bg = Color(DesignTokens.Colors.bg)
    static let surface = Color(DesignTokens.Colors.surface)
    static let surface2 = Color(DesignTokens.Colors.surface2)
    static let ink = Color(DesignTokens.Colors.ink)
    static let muted = Color(DesignTokens.Colors.muted)
    static let faint = Color(DesignTokens.Colors.faint)
    static let hairline = Color(DesignTokens.Colors.hairline)
    static let accent = Color(DesignTokens.Colors.accent)
    static let accentBright = Color(DesignTokens.Colors.accentBright)
    static let onAccent = Color(DesignTokens.Colors.onAccent)
    static let good = Color(DesignTokens.Colors.good)
    static let warn = Color(DesignTokens.Colors.warn)
    static let bad = Color(DesignTokens.Colors.bad)
    static let external = Color(DesignTokens.Colors.external)

    static let display = DesignTokens.TypeScale.display
    static let title = DesignTokens.TypeScale.title
    static let headline = DesignTokens.TypeScale.headline
    static let text = DesignTokens.TypeScale.body
    static let callout = DesignTokens.TypeScale.callout
    static let subhead = DesignTokens.TypeScale.subhead
    static let caption = DesignTokens.TypeScale.caption
    static let micro = DesignTokens.TypeScale.micro
    static let codeCaption = Font.system(.caption, design: .monospaced)

    static var spring: Animation {
        .spring(response: DesignTokens.Motion.springResponse, dampingFraction: DesignTokens.Motion.springDamping)
    }

    /// Kind of data → the chart ramp, the same mapping as the web client's --cat-* tokens.
    static func category(_ id: String) -> Color {
        switch id {
        case "code": Color(DesignTokens.Colors.chart1)
        case "agent": Color(DesignTokens.Colors.chart6)
        case "toolchain": Color(DesignTokens.Colors.chart4)
        case "synced": Color(DesignTokens.Colors.external)
        case "git": Color(DesignTokens.Colors.chart2)
        case "media": Color(DesignTokens.Colors.chart5)
        case "documents": Color(DesignTokens.Colors.chart3)
        case "cache": Color(DesignTokens.Colors.svcOther)
        default: faint
        }
    }

    static let categoryLabels: [(String, String)] = [
        ("code", "Code"), ("agent", "Agent scratch"), ("toolchain", "Toolchains"), ("synced", "Synced"),
        ("git", "Git"), ("media", "Media"), ("documents", "Documents"), ("cache", "Cache"),
    ]

    static func categoryLabel(_ id: String) -> String {
        categoryLabels.first { $0.0 == id }?.1 ?? "Other"
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }

    /// A token pair as one dynamic colour that follows the view's appearance.
    init(_ pair: DesignTokens.Pair) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua, .vibrantDark, .vibrantLight])
                .map { $0 == .darkAqua || $0 == .vibrantDark } ?? false
            return NSColor(Color(hex: dark ? pair.dark : pair.light))
        })
    }
}

/// A small state capsule: tinted fill, coloured label, never a solid block (DESIGN.md §2).
struct StatePill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text.uppercased())
            .font(Theme.micro).tracking(0.4)
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(color)
            .background(color.opacity(0.14), in: Capsule())
            .overlay(Capsule().strokeBorder(color.opacity(0.22), lineWidth: 0.5))
    }
}

/// Content card: surface plus a hairline, no shadow in dark (DESIGN.md §4).
struct Card<Content: View>: View {
    let title: String
    var trailing: AnyView? = nil
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            HStack {
                Text(title.uppercased()).font(Theme.micro).tracking(0.4).foregroundStyle(Theme.muted)
                Spacer()
                if let trailing { trailing }
            }
            content
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
            .strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

/// Decimal units, as Finder counts them.
func bytes(_ n: Int64?) -> String {
    guard let n else { return "—" }
    let units = ["B", "KB", "MB", "GB", "TB"]
    var v = Double(abs(n)), i = 0
    while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
    let s = v >= 100 || i == 0 ? String(format: "%.0f", v) : v >= 10 ? String(format: "%.1f", v) : String(format: "%.2f", v)
    return (n < 0 ? "−" : "") + s + " " + units[i]
}

func count(_ n: Int64) -> String {
    if n >= 1_000_000 { return String(format: n >= 10_000_000 ? "%.0fM" : "%.1fM", Double(n) / 1e6) }
    if n >= 10_000 { return "\(n / 1000)k" }
    return "\(n)"
}

func ago(_ unix: Int64) -> String {
    guard unix > 0 else { return "never" }
    let s = max(0, Date().timeIntervalSince1970 - Double(unix))
    if s < 60 { return "just now" }
    if s < 3600 { return "\(Int(s / 60)) min ago" }
    if s < 86400 { return "\(Int(s / 3600)) h ago" }
    return "\(Int(s / 86400)) d ago"
}

func age(_ days: Int64) -> String {
    if days < 0 { return "unknown" }
    if days == 0 { return "today" }
    if days < 31 { return "\(days) d ago" }
    if days < 365 { return "\(days / 30) mo ago" }
    return String(format: "%.1f yr ago", Double(days) / 365)
}

func pct(_ part: Int64, _ total: Int64) -> String {
    guard total > 0 else { return "—" }
    let r = Double(part) / Double(total)
    return String(format: r < 0.1 ? "%.1f%%" : "%.0f%%", r * 100)
}

func parentOf(_ path: String) -> String {
    guard let i = path.lastIndex(of: "/"), i != path.startIndex else { return "/" }
    return String(path[..<i])
}

func baseName(_ path: String) -> String {
    path.split(separator: "/").last.map(String.init) ?? path
}
