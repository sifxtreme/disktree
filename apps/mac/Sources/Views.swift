import Charts
import SwiftUI

// MARK: - window

struct MainWindow: View {
    @EnvironmentObject var model: SparkModel
    @State private var showInspector = true

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            Detail()
                .inspector(isPresented: Binding(get: { showInspector && model.page == .map }, set: { showInspector = $0 })) {
                    Inspector()
                        .inspectorColumnWidth(min: 280, ideal: 330, max: 440)
                }
        }
        .navigationTitle(model.hostLabel)
        .navigationSubtitle(subtitle)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button { model.goBack() } label: { Label("Back", systemImage: "chevron.left") }
                    .disabled(!model.canGoBack && !model.canGoUp)
                    .help("Back (⌘[ or Esc)")
                Button { model.goForward() } label: { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!model.canGoForward)
                    .help("Forward (⌘])")
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $model.page) {
                    ForEach(Page.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
            ToolbarItem {
                Picker("Colour by", selection: $model.mode) {
                    ForEach(ColorMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Colour tiles by kind of data, or by last write")
                .disabled(model.page != .map)
            }
            ToolbarItem {
                Button { model.snapshotNow() } label: { Label("Snapshot now", systemImage: "arrow.clockwise") }
                    .disabled(model.current.status == nil || model.current.status?.scanning == true)
                    .help(model.current.status?.scanning == true ? "A snapshot is running" : "Take a snapshot now (r)")
            }
            ToolbarItem {
                Button { model.openReview() } label: {
                    Text(model.current.marks.isEmpty ? "Review" : "Review \(model.current.marks.count) · \(bytes(model.markedBytes))")
                }
                .modifier(ReviewStyle(active: !model.current.marks.isEmpty))
                .disabled(model.current.marks.isEmpty)
                .help("Review what is marked (c)")
            }
            ToolbarItem {
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
        .sheet(item: $model.review) { _ in ReviewSheet().environmentObject(model) }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast).font(Theme.subhead)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.5))
                    .padding(.bottom, 22)
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: DesignTokens.Motion.quick), value: model.toast)
    }

    private var subtitle: String {
        guard let space = model.current.status?.space else { return "" }
        return "\(bytes(space.available)) free of \(bytes(space.total))"
    }
}

/// Prominent glass only when there is something to review: a disabled prominent button on glass
/// reads as a live, unreadable blue pill (DESIGN.md §5: one or two prominent buttons, accent only for state).
struct ReviewStyle: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.buttonStyle(.glassProminent).tint(Theme.accent)
        } else {
            content.buttonStyle(.glass)
        }
    }
}

// MARK: - sidebar

struct Sidebar: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        List(selection: Binding(get: { model.host }, set: { if let id = $0 { model.switchHost(id) } })) {
            Section("Machines") {
                ForEach(model.hosts) { host in
                    HostRow(id: host.id, label: host.label).tag(host.id)
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) { StatusBox().padding(10) }
    }
}

struct HostRow: View {
    @EnvironmentObject var model: SparkModel
    let id: String
    let label: String

    var body: some View {
        let s = model.states[id]
        let share = s?.status?.space.map { Double($0.available) / Double(max($0.total, 1)) }
        let tint: Color = s?.error != nil ? Theme.bad : (share ?? 1) < 0.1 ? Theme.bad : (share ?? 1) < 0.2 ? Theme.warn : Theme.good
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8)
                .overlay(Circle().stroke(tint.opacity(0.22), lineWidth: 3))
            Text(label).lineLimit(1)
            Spacer()
            if s?.error != nil {
                StatePill(text: "down", color: Theme.bad)
            } else if let space = s?.status?.space {
                Text(bytes(space.available)).font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// Honest state: what the last snapshot was, or what is wrong.
struct StatusBox: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let (tint, text) = line
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(tint).frame(width: 8, height: 8).padding(.top, 4)
            Text(text).font(Theme.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Theme.bg, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private var line: (Color, String) {
        let s = model.current
        if !model.serverUp { return (Theme.bad, "The local disk server is not answering (com.asif.disk-web).") }
        if let e = s.error { return (Theme.bad, "Unreachable: \(e)") }
        guard let st = s.status else { return (Theme.faint, "Connecting…") }
        if st.scanning {
            let p = st.progress
            return (Theme.warn, "Snapshotting · \(count(p?.files ?? 0)) files, \(bytes(p?.bytes ?? 0))")
        }
        if let e = st.scanError { return (Theme.bad, e) }
        if st.noSnapshot == true { return (Theme.warn, "No snapshot yet") }
        // Hourly: older than 90 minutes means the snapper is not running.
        let stale = Date().timeIntervalSince1970 - Double(st.scannedAt) > 5400
        var text = "Snapshot \(ago(st.scannedAt))" + (stale ? " (overdue; hourly)" : " · hourly")
        if let secs = st.scanSeconds { text += " · took \(Int(secs.rounded())) s" }
        if let files = st.tree?.files { text += " · \(count(files)) files" }
        if let u = st.unreadable, u > 0 { text += " · \(u) unreadable" }
        return (stale || st.fullDiskAccess == false ? Theme.warn : Theme.good, text)
    }
}

// MARK: - detail

struct Detail: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        Group {
            if model.page == .cleanup {
                CleanupView()
            } else {
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    Verdict()
                    Trail()
                    Group {
                        if let node = model.current.node {
                            TreemapView(node: node)
                        } else {
                            EmptyMap()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Legend()
                }
                .padding(.horizontal, Theme.Space.xl)
                .padding(.top, Theme.Space.lg)
                .padding(.bottom, Theme.Space.lg)
            }
        }
        .background(Theme.bg)
    }
}

struct Trail: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        HStack(spacing: 4) {
            if model.canGoUp {
                Button { model.up() } label: {
                    Image(systemName: "arrow.up.left").font(.system(size: 11, weight: .semibold))
                        .frame(width: 22, height: 22)
                        .background(Theme.surface2, in: Circle())
                }
                .buttonStyle(.plain)
                .help("Enclosing folder (⌫)")
            }
            if let node = s.node, let trail = node.trail, let root = s.status?.root {
                ForEach(Array(trail.enumerated()), id: \.offset) { i, step in
                    if i > 0 { Text("›").foregroundStyle(Theme.faint) }
                    let path = i == 0 ? root : root + "/" + trail[1...i].map(\.name).joined(separator: "/")
                    let last = i == trail.count - 1
                    Button {
                        model.open(path)
                    } label: {
                        Text(i == 0 ? (root.hasPrefix("/Users/") && root.split(separator: "/").count == 2 ? "~" : baseName(root)) : step.name)
                            .font(last ? Theme.headline : Theme.subhead)
                            .foregroundStyle(last ? Theme.ink : Theme.muted)
                            .lineLimit(1)
                    }
                    .buttonStyle(.plain)
                    .help(path)
                }
            } else {
                Text(model.hostLabel).font(Theme.title)
            }
            Spacer()
        }
    }
}

struct Verdict: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if s.error != nil {
                Text("\(model.hostLabel) is not answering.").font(Theme.title)
            } else if let st = s.status, let space = st.space {
                let safe = s.suggest?.sections.first { $0.id == "safe" }?.bytes ?? 0
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(bytes(space.available)).font(.system(size: 30, weight: .bold)).monospacedDigit()
                    Text("free of \(bytes(space.total))").font(Theme.callout).foregroundStyle(Theme.muted)
                    if safe > 0 {
                        Button { model.page = .cleanup } label: {
                            Text("\(bytes(safe)) safe to clear →").font(Theme.callout.weight(.medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.accent)
                    }
                    Spacer()
                    if st.fullDiskAccess == false {
                        PartialBadge(excluded: st.excluded ?? [])
                    }
                }
            }
        }
    }
}

/// One quiet line for a partial snapshot; the detail is a click away (onion).
struct PartialBadge: View {
    let excluded: [String]
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "lock.shield")
                Text("Partial · \(excluded.count) folders skipped")
            }
            .font(Theme.caption.weight(.medium))
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Theme.warn.opacity(0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.3), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Partial snapshot").font(Theme.headline)
                Text("disk-snap has no Full Disk Access, so it skipped these rather than raise a dialog every hour:")
                    .font(Theme.subhead).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                Text(excluded.map(baseName).joined(separator: ", ")).font(Theme.subhead)
                Text("Grant it to ~/.local/bin/disk-snap in Privacy & Security › Full Disk Access.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
                Button("Open Full Disk Access Settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_AllFiles")!)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            .frame(width: 340)
        }
    }
}

struct Legend: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        HStack(spacing: 12) {
            if model.mode == .age {
                ForEach([("this week", 0.72), ("this month", 0.52), ("6 months", 0.34), ("a year", 0.20), ("older", 0.09)], id: \.0) { label, mix in
                    swatch(Theme.surface.mix(with: Theme.accent, by: mix), label)
                }
            } else {
                ForEach(Theme.categoryLabels, id: \.0) { id, label in
                    swatch(Theme.surface.mix(with: Theme.category(id), by: 0.55), label)
                }
            }
            swatch(Theme.surface2, "reclaimable", hatched: true)
            swatch(Theme.surface.mix(with: Theme.bad, by: 0.3), "marked")
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.muted)
    }

    private func swatch(_ color: Color, _ label: String, hatched: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 10, height: 10)
                .overlay {
                    if hatched {
                        Canvas { ctx, size in
                            var p = Path()
                            for x in stride(from: -size.height, to: size.width, by: 4) {
                                p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                            }
                            ctx.stroke(p, with: .color(Theme.ink.opacity(0.3)), lineWidth: 1)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
            Text(label)
        }
    }
}

struct EmptyMap: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        VStack(spacing: Theme.Space.sm) {
            if !model.serverUp {
                Image(systemName: "eye.slash").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                Text("The disk server is not answering").font(Theme.headline)
                Text("launchd job com.asif.disk-web on 127.0.0.1:7321").font(Theme.callout).foregroundStyle(Theme.muted)
            } else if let e = s.error, s.status == nil {
                Image(systemName: "wifi.exclamationmark").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                Text("\(model.hostLabel) is not answering").font(Theme.headline)
                Text(e).font(Theme.codeCaption).foregroundStyle(Theme.muted)
            } else if let st = s.status, st.noSnapshot == true, !st.scanning {
                Image(systemName: "camera.metering.center.weighted").font(.system(size: 28, weight: .light)).foregroundStyle(Theme.accent)
                Text("No snapshot yet").font(Theme.headline)
                Text(st.scanError ?? "The hourly snapper has not written one.").font(Theme.callout).foregroundStyle(Theme.muted)
                Button("Snapshot now") { model.snapshotNow() }.buttonStyle(.borderedProminent)
            } else if let st = s.status, st.scanning, st.tree == nil {
                ProgressView().controlSize(.small)
                Text("Taking the first snapshot").font(Theme.headline)
                Text("\(count(st.progress?.files ?? 0)) files · \(bytes(st.progress?.bytes ?? 0)) so far")
                    .font(Theme.callout.monospacedDigit()).foregroundStyle(Theme.muted)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }
}

// MARK: - inspector

struct Inspector: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                SelectionCard()
                DiskCard()
                HistoryCard()
                LookCard()
                if !model.current.marks.isEmpty { MarkedCard() }
            }
            .padding(12)
        }
        .background(Theme.bg)
    }
}

struct SelectionCard: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        let path = s.selection
        let n = path.flatMap { s.index[$0] }
        let isRoot = path == s.node?.path
        Card(title: n == nil ? "Selection" : isRoot ? "This folder" : n!.dir ? "Folder" : "File") {
            if let n, let path {
                Text(n.name).font(Theme.headline).textSelection(.enabled)
                Text(path).font(Theme.codeCaption).foregroundStyle(Theme.muted).textSelection(.enabled)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(bytes(n.bytes)).font(.system(size: 28, weight: .bold)).monospacedDigit()
                    Text("\(pct(n.bytes, s.status?.tree?.bytes ?? 0)) of snapshot").font(Theme.subhead).foregroundStyle(Theme.muted)
                }
                HStack(spacing: 6) {
                    StatePill(text: Theme.categoryLabel(n.category), color: Theme.accent)
                    if let r = n.reclaim { StatePill(text: r, color: Theme.good) }
                    if n.readError { StatePill(text: "not measured", color: Theme.warn) }
                    if n.link { StatePill(text: "symlink", color: Theme.muted) }
                }
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                    if n.dir { GridRow { Text("Files").foregroundStyle(Theme.muted); Text(n.files.formatted()) } }
                    GridRow { Text("Last write").foregroundStyle(Theme.muted); Text(age(n.ageDays)) }
                }
                .font(Theme.subhead.monospacedDigit())
                HStack {
                    if n.dir && n.hasChildren && !isRoot {
                        Button("Open") { model.open(path) }
                    }
                    if !isRoot {
                        let marked = s.marks[path] != nil
                        let covered = !marked && model.isMarked(path)
                        Button(marked ? "Unmark" : covered ? "Goes with parent" : "Mark") {
                            model.toggleMark(path, name: n.name, bytes: n.bytes)
                        }
                        .disabled(covered)
                        .tint(marked ? Theme.bad : nil)
                    }
                    Button("Show in Finder") { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
                        .disabled(model.host != "local")
                    Spacer()
                }
                .controlSize(.small)
            } else {
                Text(s.node == nil ? "—" : "Nothing selected.").foregroundStyle(Theme.muted)
            }
        }
    }
}

struct DiskCard: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let st = model.current.status
        Card(title: "Disk") {
            if let space = st?.space {
                let used = space.total - space.available
                let marked = model.markedBytes
                let share = Double(space.available) / Double(max(space.total, 1))
                let tint = share < 0.1 ? Theme.bad : share < 0.2 ? Theme.warn : Theme.accent
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule().fill(tint).frame(width: w * CGFloat(used) / CGFloat(space.total))
                        if marked > 0 {
                            Capsule().fill(Theme.good.opacity(0.55))
                                .frame(width: w * CGFloat(min(marked, used)) / CGFloat(space.total))
                                .offset(x: w * CGFloat(max(0, used - marked)) / CGFloat(space.total))
                        }
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Free now ").foregroundStyle(Theme.muted) + Text(bytes(space.available)).bold()
                    Spacer()
                    Text("\(bytes(space.total)) total").foregroundStyle(Theme.muted)
                }
                .font(Theme.caption.monospacedDigit())
                if marked > 0 {
                    HStack {
                        Text("After marks ").foregroundStyle(Theme.muted) + Text(bytes(space.available + marked)).bold()
                        Spacer()
                        Text("projected").foregroundStyle(Theme.muted)
                    }
                    .font(Theme.caption.monospacedDigit())
                }
                Text("Trash: \(st?.trash ?? "—")").font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Text(model.current.error == nil ? "—" : "No answer.").foregroundStyle(Theme.muted)
            }
        }
    }
}

struct HistoryCard: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        let points = s.history.filter { $0.available != nil }
        Card(title: "Free space · 7 days") {
            if points.count < 2 {
                Text(points.isEmpty ? "—" : "One snapshot so far. The trend starts with the next, within the hour.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Chart(points, id: \.t) { p in
                    AreaMark(x: .value("Time", Date(timeIntervalSince1970: Double(p.t))),
                             y: .value("Free", Double(p.available ?? 0) / 1e9))
                        .foregroundStyle(Theme.accent.opacity(0.12))
                    LineMark(x: .value("Time", Date(timeIntervalSince1970: Double(p.t))),
                             y: .value("Free", Double(p.available ?? 0) / 1e9))
                        .foregroundStyle(Theme.accent)
                        .lineStyle(StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis(.hidden)
                .chartYAxis {
                    AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { v in
                        AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g)) GB") } }
                            .font(Theme.caption)
                    }
                }
                .frame(height: 70)
                let delta = (points.last?.available ?? 0) - (points.first?.available ?? 0)
                HStack {
                    Text(delta < 0 ? "Down " : "Up ").foregroundStyle(Theme.muted) + Text(bytes(abs(delta))).bold()
                    Spacer()
                    Text("\(points.count) snapshots since \(ago(points.first!.t))").foregroundStyle(Theme.muted)
                }
                .font(Theme.caption.monospacedDigit())
            }
            if let g = s.growth, let base = g.baseAt {
                Text("CHANGED SINCE \(ago(base).uppercased())").font(Theme.micro).tracking(0.4).foregroundStyle(Theme.muted)
                    .padding(.top, 6)
                if g.items.isEmpty {
                    Text("Nothing moved by 10 MB or more.").font(Theme.caption).foregroundStyle(Theme.muted)
                } else {
                    ForEach(g.items.prefix(6)) { item in
                        let root = s.status?.root ?? ""
                        let rel = item.path == root ? "~" : item.path.hasPrefix(root + "/") ? String(item.path.dropFirst(root.count + 1)) : item.path
                        ListRow(title: baseName(item.path), detail: rel,
                                value: (item.delta > 0 ? "+" : "−") + bytes(abs(item.delta)),
                                valueColor: item.delta > 0 ? Theme.warn : Theme.good) { model.reveal(item.path) }
                    }
                }
            }
        }
    }
}

struct LookCard: View {
    @EnvironmentObject var model: SparkModel
    @State private var all = false

    var body: some View {
        let s = model.current
        Card(title: "Worth a look") {
            if s.insights.isEmpty {
                Text(s.status?.tree == nil ? "—" : "Nothing over 64 MB stands out.").font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                ForEach(all ? s.insights : Array(s.insights.prefix(5))) { item in
                    ListRow(title: item.name ?? baseName(item.path), detail: item.why, value: bytes(item.bytes),
                            accessory: item.markable ? (s.marks[item.path] != nil ? "xmark" : "plus") : nil,
                            accessoryColor: s.marks[item.path] != nil ? Theme.bad : Theme.muted,
                            onAccessory: { model.toggleMark(item.path, name: item.name ?? baseName(item.path), bytes: item.bytes) }) {
                        model.reveal(item.path)
                    }
                }
                if s.insights.count > 5 {
                    Button(all ? "Show fewer" : "Show all \(s.insights.count)") { all.toggle() }
                        .buttonStyle(.link).font(Theme.caption)
                }
            }
        }
    }
}

struct MarkedCard: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        Card(title: "Marked · \(bytes(model.markedBytes))",
             trailing: AnyView(Button("Clear") { model.clearMarks() }.buttonStyle(.link).font(Theme.caption))) {
            ForEach(s.marks.keys.sorted(), id: \.self) { path in
                let m = s.marks[path]!
                ListRow(title: m.name, detail: parentOf(path), value: bytes(m.bytes), accessory: "xmark", accessoryColor: Theme.bad,
                        onAccessory: { model.toggleMark(path, name: m.name, bytes: m.bytes) }) {
                    model.reveal(path)
                }
            }
            Button { model.openReview() } label: { Text("Review…").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
        }
    }
}

struct ListRow: View {
    let title: String
    let detail: String
    let value: String
    var valueColor: Color = Theme.ink
    var accessory: String? = nil
    var accessoryColor: Color = Theme.muted
    var onAccessory: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(Theme.subhead.weight(.medium)).lineLimit(1)
                if !detail.isEmpty {
                    Text(detail).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 4)
            Text(value).font(Theme.subhead.monospacedDigit()).foregroundStyle(valueColor)
            if let accessory {
                Button(action: { onAccessory?() }) {
                    Image(systemName: accessory).font(.system(size: 11, weight: .semibold)).foregroundStyle(accessoryColor)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(hovering ? Theme.surface2 : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(perform: action)
        .padding(.horizontal, -8)
    }
}

// MARK: - review sheet

struct ReviewSheet: View {
    @EnvironmentObject var model: SparkModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let r = model.review
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove from \(model.label(r?.host ?? ""))").font(Theme.title)
            if let e = r?.error { banner(e, Theme.bad) }
            if let r, let plan = r.plan {
                switch r.step {
                case .choose, .confirm: choose(r, plan)
                case .running, .done: progress(r, plan)
                }
            } else if r?.error == nil {
                ProgressView().controlSize(.small)
            }
        }
        .padding(24)
        .frame(width: 560)
        .interactiveDismissDisabled(r?.step == .running)
    }

    @ViewBuilder
    private func choose(_ r: ReviewState, _ plan: PlanDTO) -> some View {
        Text("\(plan.targets.count) item\(plan.targets.count == 1 ? "" : "s") · \(bytes(plan.bytes)). Nothing has been touched yet.")
            .font(Theme.subhead).foregroundStyle(Theme.muted)
        ScrollView {
            VStack(spacing: 0) {
                ForEach(plan.targets) { t in
                    ListRow(title: baseName(t.path), detail: parentOf(t.path), value: bytes(t.bytes),
                            accessory: r.step == .choose ? "xmark" : nil, onAccessory: { model.unmarkInReview(t.path) }) {}
                }
            }
            .padding(.horizontal, 8)
        }
        .frame(maxHeight: 240)
        if !plan.covered.isEmpty {
            Text("\(plan.covered.count) marked path\(plan.covered.count == 1 ? " goes" : "s go") with a folder above; counted once.")
                .font(Theme.caption).foregroundStyle(Theme.muted)
        }
        if !plan.blocked.isEmpty {
            banner("\(plan.blocked.count) will not be touched:\n" + plan.blocked.map { "\($0.path): \($0.reason)" }.joined(separator: "\n"), Theme.warn)
        }
        let st = model.states[r.host]?.status
        if r.step == .choose {
            Picker("", selection: Binding(get: { model.review?.mode ?? "trash" }, set: { m in
                model.review?.mode = m
                Task { await model.plan() }
            })) {
                VStack(alignment: .leading) {
                    Text("Move to Trash")
                    Text(st?.trashAvailable == true ? "\(st?.trash ?? ""): recoverable until the Trash is emptied." : "No trash on this machine.")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                }
                .tag("trash")
                .disabled(st?.trashAvailable != true)
                VStack(alignment: .leading) {
                    Text("Delete permanently")
                    Text("rm -rf. Cannot be undone. Asks once more.").font(Theme.caption).foregroundStyle(Theme.muted)
                }
                .tag("permanent")
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            HStack {
                Spacer()
                Button("Cancel") { model.review = nil }.keyboardShortcut(.cancelAction)
                if r.mode == "trash" {
                    Button("Move to Trash · \(bytes(plan.bytes))") { model.commit() }
                        .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                        .disabled(plan.targets.isEmpty)
                } else {
                    Button("Delete permanently…") { model.review?.step = .confirm }
                        .tint(Theme.bad)
                        .disabled(plan.targets.isEmpty)
                }
            }
        } else {
            banner("This deletes \(plan.targets.count) item\(plan.targets.count == 1 ? "" : "s") and \(bytes(plan.bytes)) on \(model.label(r.host)), now. There is no undo.", Theme.bad)
            HStack {
                Spacer()
                Button("Back") { model.review?.step = .choose }.keyboardShortcut(.cancelAction)
                Button("Delete permanently") { model.commit() }
                    .buttonStyle(.borderedProminent).tint(Theme.bad)
            }
        }
    }

    @ViewBuilder
    private func progress(_ r: ReviewState, _ plan: PlanDTO) -> some View {
        let job = r.job
        if let done = job?.done, let job {
            let failed = job.items.filter { $0.error != nil }
            let what = r.mode == "trash" ? "Moved to Trash" : "Deleted"
            let tail = r.mode == "trash"
                ? "The disk frees it when the Trash is emptied."
                : "The disk reports \(bytes(done.gained)) more free\(Double(done.gained) < Double(done.bytes) * 0.8 ? " (snapshots or hardlinks may still hold the rest)" : "")."
            banner("\(what): \(done.removed) of \(job.total), \(bytes(done.bytes)) as measured by the snapshot. \(tail)", failed.isEmpty ? Theme.good : Theme.warn)
            ForEach(failed) { f in banner("\(f.path): \(f.error ?? "")", Theme.bad) }
            Text("A fresh snapshot is running so the map matches the disk.").font(Theme.caption).foregroundStyle(Theme.muted)
            HStack { Spacer(); Button("Done") { model.review = nil }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction) }
        } else {
            HStack(spacing: 10) {
                ProgressView(value: Double(job?.items.count ?? 0), total: Double(max(job?.total ?? Int64(plan.targets.count), 1)))
                Text("\(job?.items.count ?? 0) of \(job?.total ?? Int64(plan.targets.count))").font(Theme.subhead.monospacedDigit())
            }
        }
    }

    private func banner(_ text: String, _ color: Color) -> some View {
        Text(text).font(Theme.subhead)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous).strokeBorder(color.opacity(0.4), lineWidth: 0.5))
    }
}

// MARK: - menu bar

struct MenuLabel: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let local = model.states["local"]?.status?.space
        let worst = model.states.values.compactMap { $0.status?.space }.map { Double($0.available) / Double(max($0.total, 1)) }.min() ?? 1
        HStack(spacing: 4) {
            Image(systemName: worst < 0.1 ? "exclamationmark.circle" : "smallcircle.filled.circle")
            if let local { Text(bytes(local.available)).monospacedDigit() }
        }
    }
}

struct MenuPanel: View {
    @EnvironmentObject var model: SparkModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("FREE SPACE").font(Theme.micro).tracking(0.4).foregroundStyle(Theme.muted)
            if !model.serverUp {
                Text("The disk server is not answering.").foregroundStyle(Theme.muted)
            }
            ForEach(model.hosts) { host in
                let s = model.states[host.id]
                VStack(alignment: .leading, spacing: 5) {
                    HStack {
                        HostRow(id: host.id, label: host.label)
                    }
                    if let space = s?.status?.space {
                        ProgressView(value: Double(space.total - space.available), total: Double(max(space.total, 1)))
                            .tint(Double(space.available) / Double(max(space.total, 1)) < 0.1 ? Theme.bad : Theme.accent)
                    }
                    HStack {
                        Text(s?.error ?? (s?.status.map { $0.noSnapshot == true ? "no snapshot yet" : "snapshot \(ago($0.scannedAt))" + ($0.fullDiskAccess == false ? " · partial" : "") } ?? "—"))
                            .font(Theme.caption).foregroundStyle(Theme.muted)
                        Spacer()
                        Button("Snapshot now") { model.snapshotNow(host.id) }
                            .buttonStyle(.link).font(Theme.caption)
                            .disabled(s?.error != nil || s?.status?.scanning == true)
                    }
                }
            }
            Divider()
            HStack {
                Button("Open Guilty Spark") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(.borderedProminent)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
