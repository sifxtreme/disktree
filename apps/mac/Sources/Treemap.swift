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
        // A 1.5 pt gutter between siblings reads as structure without a stroke on every tile.
        for (i, full) in rects.enumerated() where full.width >= 4 && full.height >= 4 {
            let r = full.insetBy(dx: 0.75, dy: 0.75)
            if i >= kids.count {
                tiles.append(Tile(rect: r, node: nil, rest: parent.rest, path: parentPath + "/…", depth: depth, nested: false))
                continue
            }
            let c = kids[i]
            let path = parentPath + "/" + c.name
            let band: CGFloat = depth == 1 ? 24 : 17
            let nested = !(c.children ?? []).isEmpty && r.width > 48 && r.height > band + 20
            tiles.append(Tile(rect: r, node: c, rest: nil, path: path, depth: depth, nested: nested))
            if nested {
                let pad: CGFloat = depth == 1 ? 4 : 3
                lay(c, path, CGRect(x: r.minX + pad, y: r.minY + band, width: r.width - 2 * pad, height: r.height - band - pad), depth + 1)
            }
        }
    }
    lay(root, root.path ?? "", rect, 1)
    return tiles
}

/// Layout keyed on what it depends on, computed during body. Laying out from onAppear/onChange missed
/// the case where the map appears before its size is known (returning from Clean up drew nothing).
final class LayoutCache {
    private var key: String = ""
    private(set) var tiles: [Tile] = []
    private(set) var previous: [Tile] = []

    func update(_ node: NodeDTO, _ size: CGSize) {
        let key = "\(node.path ?? "")|\(node.bytes)|\(Int(size.width))x\(Int(size.height))"
        guard key != self.key, size.width > 0, size.height > 0 else { return }
        previous = tiles
        tiles = layoutTiles(node, in: CGRect(origin: .zero, size: size))
        self.key = key
    }
}

struct TreemapView: View {
    @EnvironmentObject var model: SparkModel
    let node: NodeDTO

    @State private var cache = LayoutCache()
    @State private var size: CGSize = .zero
    private var tiles: [Tile] { cache.tiles }
    @State private var hover: (path: String, at: CGPoint)?
    /// The zoom transform: content point p is drawn at p * scale + offset.
    @State private var scale = CGSize(width: 1, height: 1)
    @State private var offset = CGSize.zero
    @State private var fade = 1.0
    @FocusState private var focused: Bool

    var body: some View {
        GeometryReader { geo in
            let _ = cache.update(node, geo.size)
            ZStack(alignment: .topLeading) {
                Canvas { ctx, _ in draw(&ctx) }
                    .scaleEffect(x: scale.width, y: scale.height, anchor: .topLeading)
                    .offset(offset)
                    .opacity(fade)
                if let hover, scale == CGSize(width: 1, height: 1),
                   let tile = tiles.last(where: { $0.path == hover.path }), let n = tile.node {
                    Tooltip(node: n, view: node, mode: model.mode)
                        .offset(tipOffset(hover.at, in: geo.size))
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
            .contentShape(Rectangle())
            .onAppear { size = geo.size }
            .onChange(of: geo.size) { _, s in size = s }
            .onContinuousHover { phase in
                switch phase {
                case .active(let p): hover = hit(p).map { ($0.path, p) }
                case .ended: hover = nil
                }
            }
            .onTapGesture { p in
                focused = true
                guard let t = hit(p), let n = t.node else { return }
                // A click goes into a folder; a file (or an empty folder) is selected instead.
                if n.dir && n.hasChildren {
                    model.open(t.path)
                } else {
                    model.select(t.path)
                }
            }
            .contextMenu { contextMenu }
        }
        .padding(3)
        .background(Theme.surface)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
        .focusable()
        .focusEffectDisabled()
        .focused($focused)
        .onKeyPress(phases: .down) { press in keys(press) }
        .onAppear { focused = true }
        .onChange(of: node) { old, new in transition(from: old, to: new) }
    }

    // MARK: zoom

    /// Going in: the new folder grows out of the tile it was. Going out: the parent starts zoomed on
    /// the folder we left and settles back. Anything else (another machine, a new snapshot) fades.
    private func transition(from old: NodeDTO, to new: NodeDTO) {
        // Body has already laid out the new node; the cache kept the old tiles.
        cache.update(new, size)
        let oldTiles = cache.previous
        hover = nil
        guard let from = old.path, let to = new.path, from != to, size.width > 0 else {
            settle(fadeFrom: 0.4)
            return
        }
        if to.hasPrefix(from + "/"), let r = oldTiles.first(where: { $0.path == to })?.rect ?? ancestorTile(of: to, in: oldTiles) {
            place(scale: CGSize(width: r.width / size.width, height: r.height / size.height),
                  offset: CGSize(width: r.minX, height: r.minY))
            settle(fadeFrom: 0.5)
        } else if from.hasPrefix(to + "/"), let r = tiles.first(where: { $0.path == from })?.rect ?? ancestorTile(of: from, in: tiles) {
            let s = CGSize(width: size.width / r.width, height: size.height / r.height)
            place(scale: s, offset: CGSize(width: -r.minX * s.width, height: -r.minY * s.height))
            settle(fadeFrom: 0.6)
        } else {
            settle(fadeFrom: 0.4)
        }
    }

    private func ancestorTile(of path: String, in list: [Tile]) -> CGRect? {
        list.filter { path.hasPrefix($0.path + "/") }.max { $0.path.count < $1.path.count }?.rect
    }

    private func place(scale s: CGSize, offset o: CGSize) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { scale = s; offset = o }
    }

    private func settle(fadeFrom: Double) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { fade = fadeFrom }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.9)) {
                scale = CGSize(width: 1, height: 1)
                offset = .zero
                fade = 1
            }
        }
    }

    // MARK: hit testing and input

    private func hit(_ p: CGPoint) -> Tile? {
        tiles.last { $0.node != nil && $0.rect.contains(p) }
    }

    private func tipOffset(_ p: CGPoint, in size: CGSize) -> CGSize {
        let w: CGFloat = 260, h: CGFloat = 70
        let x = min(p.x + 14, size.width - w - 6)
        let y = p.y + 18 + h > size.height ? p.y - h - 12 : p.y + 18
        return CGSize(width: max(6, x), height: y)
    }

    /// Right-click acts on the tile under the pointer, which hover already tracks.
    @ViewBuilder
    private var contextMenu: some View {
        if let path = hover?.path, let tile = tiles.last(where: { $0.path == path }), let n = tile.node {
            Text(n.name)
            if n.dir && n.hasChildren {
                Button("Open") { model.open(path) }
            }
            Button("Inspect") { model.select(path) }
            let marked = model.current.marks[path] != nil
            Button(marked ? "Unmark" : "Mark for Removal") { model.toggleMark(path, name: n.name, bytes: n.bytes) }
                .disabled(!marked && model.isMarked(path))
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                .disabled(model.host != "local")
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(path, forType: .string)
            }
        }
        if model.canGoUp {
            Divider()
            Button("Enclosing Folder") { model.up() }
        }
    }

    private func keys(_ press: KeyPress) -> KeyPress.Result {
        let state = model.current
        let target = hover?.path ?? state.selection
        let tile = target.flatMap { t in tiles.last { $0.path == t } }
        switch press.key {
        case .escape:
            model.goBack(); return .handled
        case .delete:
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
        if model.isMarked(tile.path) { return Theme.surface.mix(with: Theme.bad, by: 0.24) }
        switch model.mode {
        case .age:
            let d = n.ageDays
            let mix = d < 0 ? 0.06 : d <= 7 ? 0.62 : d <= 30 ? 0.46 : d <= 180 ? 0.30 : d <= 365 ? 0.18 : 0.08
            return Theme.surface.mix(with: Theme.accent, by: mix)
        case .kind:
            // Deeper is lighter, so structure reads before labels do.
            let mix = [0.30, 0.40, 0.33, 0.27, 0.22][min(tile.depth - 1, 4)]
            return Theme.surface.mix(with: Theme.category(n.category), by: tile.nested ? mix * 0.55 : mix)
        }
    }

    private func tint(_ n: NodeDTO) -> Color {
        model.mode == .kind ? Theme.category(n.category) : Theme.accent
    }

    private func hatch(_ ctx: inout GraphicsContext, _ shape: Path, _ rect: CGRect, _ color: Color, width: CGFloat, gap: CGFloat) {
        ctx.drawLayer { layer in
            layer.clip(to: shape)
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
            let fits = resolved.measure(in: CGSize(width: CGFloat.infinity, height: rect.height)).width <= rect.width - 8
            if center && fits {
                layer.draw(resolved, at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
            } else {
                layer.draw(resolved, at: CGPoint(x: rect.minX + 7, y: rect.midY), anchor: .leading)
            }
        }
    }

    private func draw(_ ctx: inout GraphicsContext) {
        let selection = model.current.selection
        for tile in tiles {
            let r = tile.rect
            let radius: CGFloat = tile.depth == 1 ? 6 : 4
            let shape = Path(roundedRect: r, cornerRadius: radius, style: .continuous)
            ctx.fill(shape, with: .color(fill(tile)))

            guard let n = tile.node else {
                if r.width > 80 && r.height > 18, let rest = tile.rest {
                    let what = rest.count > 0 ? "\(rest.count) more" : "smaller items"
                    label(&ctx, Text("\(what) · \(bytes(rest.bytes))").font(.system(size: 10.5)).foregroundStyle(Theme.muted),
                          in: CGRect(x: r.minX, y: r.minY, width: r.width, height: 18))
                }
                continue
            }
            let marked = model.isMarked(tile.path)
            if marked {
                hatch(&ctx, shape, r, Theme.bad.opacity(0.4), width: 2, gap: 7)
            } else if n.reclaim != nil {
                hatch(&ctx, shape, r, Theme.ink.opacity(0.12), width: 1.25, gap: 6)
            }

            if tile.nested {
                let band = CGRect(x: r.minX, y: r.minY, width: r.width, height: tile.depth == 1 ? 24 : 17)
                if tile.depth == 1 && !marked {
                    // A thin strip of the section's colour, not a filled header.
                    ctx.fill(Path(roundedRect: CGRect(x: r.minX + 7, y: r.minY + 6, width: 3, height: 12), cornerRadius: 1.5),
                             with: .color(tint(n)))
                }
                if r.width > 48 {
                    var t = Text(n.name).font(.system(size: tile.depth == 1 ? 12.5 : 11, weight: tile.depth == 1 ? .semibold : .medium))
                        .foregroundStyle(Theme.ink)
                    if r.width > 120 {
                        t = t + Text("  " + bytes(n.bytes)).font(.system(size: 11).monospacedDigit()).foregroundStyle(Theme.muted)
                    }
                    label(&ctx, t, in: band.offsetBy(dx: tile.depth == 1 ? 7 : 0, dy: 0))
                }
            } else if r.width > 58 && r.height > 22 {
                var t = Text(n.name).font(.system(size: 11, weight: .medium)).foregroundStyle(Theme.ink)
                if r.height > 40 && r.width > 64 {
                    t = t + Text("\n" + bytes(n.bytes)).font(.system(size: 10.5).monospacedDigit()).foregroundStyle(Theme.muted)
                }
                label(&ctx, t, in: r.insetBy(dx: 2, dy: 2), center: true)
            }

            if tile.path == hover?.path {
                ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.75, dy: 0.75), cornerRadius: radius, style: .continuous),
                           with: .color(Theme.ink.opacity(0.4)), lineWidth: 1.5)
            }
        }
        // The selection last, over its children.
        if let selection, let tile = tiles.last(where: { $0.path == selection }) {
            ctx.stroke(Path(roundedRect: tile.rect.insetBy(dx: 1, dy: 1), cornerRadius: 5, style: .continuous),
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
