import SwiftUI

// The mosaic. Painted in one Canvas, not composed of views: thousands of rectangles belong in one
// draw pass (disktree AGENTS.md invariant 6). Layout is squarified (Bruls, Huizing, van Wijk) and
// recomputed only when the node or the size changes.

struct Tile {
    let rect: CGRect
    let node: NodeDTO?      // nil for the folded "N more" tile
    let rest: RestDTO?
    let path: String
    let depth: Int
    let nested: Bool
}

func squarify(_ values: [Double], in rect: CGRect) -> [CGRect] {
    let total = values.reduce(0, +)
    guard total > 0, rect.width > 0, rect.height > 0 else { return values.map { _ in .zero } }
    let scale = rect.width * rect.height / total
    var out = [CGRect](repeating: .zero, count: values.count)
    var free = rect
    var row: [(Int, Double)] = []

    func worst(_ r: [(Int, Double)], _ side: Double) -> Double {
        let s = r.reduce(0) { $0 + $1.1 }
        let mx = r.map(\.1).max() ?? 0, mn = r.map(\.1).min() ?? 1
        return max(side * side * mx / (s * s), s * s / (side * side * mn))
    }
    func flush() {
        let s = row.reduce(0) { $0 + $1.1 }
        if free.width >= free.height {
            let w = s / free.height
            var y = free.minY
            for (i, a) in row { let h = a / w; out[i] = CGRect(x: free.minX, y: y, width: w, height: h); y += h }
            free = CGRect(x: free.minX + w, y: free.minY, width: free.width - w, height: free.height)
        } else {
            let h = s / free.width
            var x = free.minX
            for (i, a) in row { let w = a / h; out[i] = CGRect(x: x, y: free.minY, width: w, height: h); x += w }
            free = CGRect(x: free.minX, y: free.minY + h, width: free.width, height: free.height - h)
        }
        row = []
    }
    for (i, v) in values.enumerated() {
        let next = (i, v * scale)
        let side = min(free.width, free.height)
        if row.isEmpty || worst(row + [next], side) <= worst(row, side) { row.append(next) }
        else { flush(); row.append(next) }
    }
    if !row.isEmpty { flush() }
    return out
}

func layoutTiles(_ root: NodeDTO, in rect: CGRect) -> [Tile] {
    var tiles: [Tile] = []
    func lay(_ parent: NodeDTO, _ parentPath: String, _ rect: CGRect, _ depth: Int) {
        let kids = (parent.children ?? []).filter { $0.bytes > 0 }
        var values = kids.map { Double($0.bytes) }
        if let rest = parent.rest, rest.bytes > 0 { values.append(Double(rest.bytes)) }
        let rects = squarify(values, in: rect)
        for (i, r) in rects.enumerated() where r.width >= 2 && r.height >= 2 {
            if i >= kids.count {
                tiles.append(Tile(rect: r, node: nil, rest: parent.rest, path: parentPath + "/…", depth: depth, nested: false))
                continue
            }
            let c = kids[i]
            let path = parentPath + "/" + c.name
            let band: CGFloat = depth == 1 ? 21 : 16
            let nested = !(c.children ?? []).isEmpty && r.width > 44 && r.height > band + 16
            tiles.append(Tile(rect: r, node: c, rest: nil, path: path, depth: depth, nested: nested))
            if nested {
                lay(c, path, CGRect(x: r.minX + 2, y: r.minY + band, width: r.width - 4, height: r.height - band - 2), depth + 1)
            }
        }
    }
    lay(root, root.path ?? "", rect, 1)
    return tiles
}

struct TreemapView: View {
    @EnvironmentObject var model: SparkModel
    let node: NodeDTO

    @State private var tiles: [Tile] = []
    @State private var hover: (path: String, at: CGPoint)?
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(&ctx) }
                if let hover, let tile = tiles.last(where: { $0.path == hover.path }), let n = tile.node {
                    Tooltip(node: n, view: node, mode: model.mode)
                        .offset(tipOffset(hover.at, in: size))
                        .allowsHitTesting(false)
                }
            }
            .contentShape(Rectangle())
            .onAppear { relayout(size) }
            .onChange(of: size) { _, s in relayout(s) }
            .onChange(of: node) { _, _ in relayout(size) }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = hit(p).map { ($0.path, p) }
                case .ended: hover = nil
                }
            }
            .onTapGesture(count: 2) { p in
                if let t = hit(p), let n = t.node, n.dir, n.hasChildren { model.open(t.path) }
            }
            .onTapGesture(count: 1) { p in
                focused = true
                if let t = hit(p) { model.select(t.path) }
            }
        }
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in keys(press) }
        .onAppear { focused = true }
    }

    // MARK: layout and hit testing

    private func relayout(_ size: CGSize) {
        tiles = layoutTiles(node, in: CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))
    }

    private func hit(_ p: CGPoint) -> Tile? {
        tiles.last { $0.node != nil && $0.rect.contains(p) }
    }

    private func tipOffset(_ p: CGPoint, in size: CGSize) -> CGSize {
        let w: CGFloat = 260, h: CGFloat = 70
        let x = min(p.x + 14, size.width - w - 6)
        let y = p.y + 18 + h > size.height ? p.y - h - 12 : p.y + 18
        return CGSize(width: max(6, x), height: y)
    }

    private func keys(_ press: KeyPress) -> KeyPress.Result {
        let state = model.current
        let target = hover?.path ?? state.selection
        let tile = target.flatMap { t in tiles.last { $0.path == t } }
        switch press.key {
        case .delete, .escape:
            model.up(); return .handled
        case .return:
            if let tile, let n = tile.node, n.dir, n.hasChildren { model.open(tile.path) }
            return .handled
        case .space:
            if let tile, let n = tile.node { model.toggleMark(tile.path, name: n.name, bytes: n.bytes) }
            return .handled
        default:
            switch press.characters {
            case "x":
                if let tile, let n = tile.node { model.toggleMark(tile.path, name: n.name, bytes: n.bytes) }
                return .handled
            case "c": model.openReview(); return .handled
            case "r": model.snapshotNow(); return .handled
            default: return .ignored
            }
        }
    }

    // MARK: painting

    private func fill(_ tile: Tile) -> Color {
        guard let n = tile.node else { return Theme.surface2 }
        if model.isMarked(tile.path) { return Theme.surface.mix(with: Theme.bad, by: 0.26) }
        switch model.mode {
        case .age:
            let d = n.ageDays
            let mix = d < 0 ? 0.06 : d <= 7 ? 0.72 : d <= 30 ? 0.52 : d <= 180 ? 0.34 : d <= 365 ? 0.20 : 0.09
            return Theme.surface.mix(with: Theme.accent, by: mix)
        case .kind:
            let mix = [0.44, 0.34, 0.27, 0.22, 0.18][min(tile.depth - 1, 4)]
            return Theme.surface.mix(with: Theme.category(n.category), by: mix)
        }
    }

    private func hatch(_ ctx: inout GraphicsContext, _ rect: CGRect, _ color: Color, width: CGFloat, gap: CGFloat) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            var path = Path()
            var x = rect.minX - rect.height
            while x < rect.maxX {
                path.move(to: CGPoint(x: x, y: rect.maxY))
                path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
                x += gap
            }
            layer.stroke(path, with: .color(color), lineWidth: width)
        }
    }

    private func label(_ ctx: inout GraphicsContext, _ text: Text, in rect: CGRect, center: Bool = false) {
        ctx.drawLayer { layer in
            layer.clip(to: Path(rect))
            let resolved = layer.resolve(text)
            // A name wider than its tile keeps its start visible rather than losing both ends.
            let fits = resolved.measure(in: CGSize(width: CGFloat.infinity, height: rect.height)).width <= rect.width - 4
            if center && fits {
                layer.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            } else {
                layer.draw(resolved, at: CGPoint(x: rect.minX + 6, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let selection = model.current.selection
        for tile in tiles {
            let r = tile.rect
            let shape = Path(roundedRect: r, cornerRadius: 3)
            ctx.fill(shape, with: .color(fill(tile)))
            ctx.stroke(shape, with: .color(Theme.ink.opacity(0.1)), lineWidth: 0.5)

            guard let n = tile.node else {
                if r.width > 70 && r.height > 16, let rest = tile.rest {
                    let what = rest.count > 0 ? "\(rest.count) more" : "smaller items"
                    label(&ctx, Text("\(what) · \(bytes(rest.bytes))").font(.system(size: 10.5)).foregroundStyle(Theme.muted),
                          in: CGRect(x: r.minX, y: r.minY, width: r.width, height: 16))
                }
                continue
            }
            let marked = model.isMarked(tile.path)
            if marked {
                hatch(&ctx, r, Theme.bad.opacity(0.45), width: 2, gap: 7)
            } else if n.reclaim != nil {
                hatch(&ctx, r, Theme.ink.opacity(0.16), width: 1.5, gap: 7)
            }

            if tile.nested {
                let band = CGRect(x: r.minX, y: r.minY, width: r.width, height: tile.depth == 1 ? 20 : 15)
                if tile.depth == 1 && !marked {
                    let cat = model.mode == .kind ? Theme.category(n.category) : Theme.accent
                    ctx.fill(Path(band), with: .color(Theme.surface.mix(with: cat, by: 0.2)))
                    ctx.fill(Path(CGRect(x: band.minX, y: band.maxY - 1, width: band.width, height: 2)),
                             with: .color(Theme.surface.mix(with: cat, by: 0.7)))
                }
                if r.width > 40 {
                    var t = Text(n.name).font(.system(size: tile.depth == 1 ? 12 : 10.5, weight: tile.depth == 1 ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                    if r.width > 110 {
                        t = t + Text("  " + bytes(n.bytes)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    label(&ctx, t, in: band)
                }
            } else if r.width > 46 && r.height > 18 {
                var t = Text(n.name).font(.system(size: 10.5)).foregroundStyle(Theme.ink)
                if r.height > 34 && r.width > 60 {
                    t = t + Text("\n" + bytes(n.bytes)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                label(&ctx, t, in: r.insetBy(dx: 3, dy: 2), center: true)
            }

            if tile.path == hover?.path {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: 3),
                           with: .color(Theme.ink.opacity(0.45)), lineWidth: 1.5)
            }
        }
        // The selection last, over its children.
        if let selection, let tile = tiles.last(where: { $0.path == selection }) {
            ctx.stroke(Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 3),
                       with: .color(Theme.accent), lineWidth: 2)
        }
    }
}

struct Tooltip: View {
    let node: NodeDTO
    let view: NodeDTO
    let mode: ColorMode

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(node.name).font(Theme.subhead.weight(.semibold)).lineLimit(1)
            Text("\(bytes(node.bytes)) · \(pct(node.bytes, view.bytes)) of this view").font(Theme.caption).monospacedDigit()
            Text([Theme.categoryLabel(node.category), node.reclaim, mode == .age ? "written " + age(node.ageDays) : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(Theme.caption).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 11).padding(.vertical, 8)
        .frame(maxWidth: 260, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.14), radius: 16, y: 6)
    }
}
