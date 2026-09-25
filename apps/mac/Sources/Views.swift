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
            // A plain panel, not `.inspector`: resizing the window with the system inspector crashed
            // the app intermittently (SwiftUI SplitViewChildController min-size loop, AppKit abort;
            // reproduced by the harness with every card removed, so the column itself was the cause).
            HStack(spacing: 0) {
                Detail()
                if showInspector && model.page == .map {
                    Divider()
                    Inspector().frame(width: 330)
                }
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
                Button { showInspector.toggle() } label: { Label("Inspector", systemImage: "sidebar.right") }
            }
        }
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
        // No fixed minimum here: one (560 pt) made the split view's column minimums conflict at the
        // smallest window and AppKit aborted ("didUpdateMinSize"; the harness reproduced it). The rows
        // above truncate instead, so this column's minimum never follows its text.
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
            Spacer(minLength: 0)
        }
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .clipped()
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
                        .fixedSize()
                    Text("free of \(bytes(space.total))").font(Theme.callout).foregroundStyle(Theme.muted)
                        .lineLimit(1)
                    if safe > 0 {
                        Button { model.page = .cleanup } label: {
                            Text("\(bytes(safe)) safe to clear →").font(Theme.callout.weight(.medium)).lineLimit(1)
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
        // One line that scrolls when narrow: wrapping split words ("Tool-chains").
        ScrollView(.horizontal, showsIndicators: false) {
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
        }
        .font(Theme.caption)
        .foregroundStyle(Theme.muted)
        .fixedSize()
        }
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
            Text(label).lineLimit(1)
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
                Text(displayPath(path, root: s.status?.root)).font(Theme.codeCaption).foregroundStyle(Theme.muted)
                    .help(path)
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
                    Button("Show in Finder") { showInFinder(path) }
                        .disabled(model.host != "local")
                    Button("Copy Path") { copyPath(path) }
                    Spacer()
                }
                .controlSize(.small)
                if !isRoot {
                    // Its own row: three buttons and a menu do not fit the panel's width.
                    Menu("Copy Delete Command") {
                        Button(deleteCommand(path)) { copyCommand(deleteCommand(path)); model.show("Copied: \(deleteCommand(path))") }
                        Button("rm -rf (permanent)") { copyCommand(deleteCommand(path, permanent: true)); model.show("Copied a permanent delete command") }
                    }
                    .controlSize(.small)
                    .fixedSize()
                }
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
                let share = Double(space.available) / Double(max(space.total, 1))
                let tint = share < 0.1 ? Theme.bad : share < 0.2 ? Theme.warn : Theme.accent
                GeometryReader { geo in
                    let w = geo.size.width
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.surface2)
                        Capsule().fill(tint).frame(width: w * CGFloat(used) / CGFloat(space.total))
                    }
                }
                .frame(height: 8)
                HStack {
                    Text("Free now ").foregroundStyle(Theme.muted) + Text(bytes(space.available)).bold()
                    Spacer()
                    Text("\(bytes(space.total)) total").foregroundStyle(Theme.muted)
                }
                .font(Theme.caption.monospacedDigit())
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
            if !s.extrasLoaded {
                Text(s.status?.tree == nil ? "—" : "Loading…").font(Theme.caption).foregroundStyle(Theme.muted)
            } else if points.count < 2 {
                Text(points.isEmpty ? "—" : "One snapshot so far. The trend starts with the next, within the hour.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Sparkline(values: points.map { Double($0.available ?? 0) })
                    .frame(height: 64)
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
            if !s.extrasLoaded {
                Text(s.status?.tree == nil ? "—" : "Loading…").font(Theme.caption).foregroundStyle(Theme.muted)
            } else if s.insights.isEmpty {
                Text("Nothing over 64 MB stands out.").font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                ForEach(all ? s.insights : Array(s.insights.prefix(5))) { item in
                    ListRow(title: item.name ?? baseName(item.path), detail: item.why, value: bytes(item.bytes)) {
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
            if model.crashes.count > 0, let latest = model.crashes.latest {
                HStack {
                    Text("Crashed \(model.crashes.count)× in 7 days")
                        .font(Theme.caption).foregroundStyle(Theme.warn)
                    Spacer()
                    Button("Show report") { showInFinder(latest.path) }
                        .buttonStyle(.link).font(Theme.caption)
                }
            }
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

func showInFinder(_ path: String) {
    NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
}

func copyPath(_ path: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(path, forType: .string)
}

/// Free space over time as one drawn path: the Charts framework cost more memory than this line is
/// worth. Scaled to its own range (not zero-based) so a few GB of change is visible.
struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let lo = (values.min() ?? 0), hi = (values.max() ?? 1)
            let pad = max((hi - lo) * 0.15, 1e8)
            let span = (hi + pad) - (lo - pad)
            let pts = values.enumerated().map { i, v in
                CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)),
                        y: geo.size.height * CGFloat(1 - (v - (lo - pad)) / span))
            }
            ZStack(alignment: .topTrailing) {
                Path { p in
                    guard let first = pts.first, let last = pts.last else { return }
                    p.move(to: CGPoint(x: first.x, y: geo.size.height))
                    pts.forEach { p.addLine(to: $0) }
                    p.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                    p.closeSubpath()
                }
                .fill(Theme.accent.opacity(0.12))
                Path { p in
                    guard let first = pts.first else { return }
                    p.move(to: first)
                    pts.dropFirst().forEach { p.addLine(to: $0) }
                }
                .stroke(Theme.accent, style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round))
                Text(bytes(Int64(hi))).font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

/// A path as a person reads it: `~/…` under the snapshot root. The full path stays in the tooltip
/// and in Copy Path.
func displayPath(_ path: String, root: String?) -> String {
    guard let root, path == root || path.hasPrefix(root + "/") else { return path }
    return "~" + path.dropFirst(root.count)
}

/// A path quoted for zsh/bash: single quotes, with any single quote closed, escaped and reopened.
func shellQuoted(_ path: String) -> String {
    "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

/// The command to clear `path`, for the user to paste; Guilty Spark itself never deletes. A known cache
/// gets its owner's own cleanup (it knows what is safe to drop); anything else goes to the Trash with
/// macOS's `trash`, so it can be put back.
func deleteCommand(_ path: String, permanent: Bool = false) -> String {
    let home = NSHomeDirectory()
    let owned: [(String, String)] = [
        ("/.npm/_cacache", "npm cache clean --force"),
        ("/.cache/uv", "uv cache clean"),
        ("/Library/Caches/Homebrew", "brew cleanup --prune=all"),
        ("/Library/pnpm/store", "pnpm store prune"),
        ("/.yarn/berry/cache", "yarn cache clean --all"),
        ("/Library/Developer/CoreSimulator", "xcrun simctl delete unavailable"),
    ]
    if !permanent, let hit = owned.first(where: { path == home + $0.0 || path.hasPrefix(home + $0.0 + "/") }) {
        return hit.1
    }
    return (permanent ? "rm -rf " : "trash ") + shellQuoted(path)
}

func copyCommand(_ command: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(command, forType: .string)
}
