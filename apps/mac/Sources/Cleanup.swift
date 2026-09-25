import SwiftUI

// Clean up: what to delete, and why. Four lists from the server's /suggest, each keeping its reason
// attached to its size: safe to clear (regenerates), growing fast (7 days of snapshots), big and
// untouched (6 months), came back (deleted before, large again). Marking here is the same mark as
// on the map; nothing is removed until Review.

struct CleanupView: View {
    @EnvironmentObject var model: SparkModel

    var body: some View {
        let s = model.current
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                if let sections = s.suggest?.sections {
                    ForEach(sections) { section in
                        SectionCard(section: section)
                    }
                    Text("Sizes are from the snapshot taken \(ago(s.status?.scannedAt ?? 0)). Nothing is removed until you review what is marked.")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                } else if s.status?.tree == nil {
                    Text("Clean up needs a snapshot first.").foregroundStyle(Theme.muted)
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
    }

    private var header: some View {
        let s = model.current
        let sections = s.suggest?.sections ?? []
        let safe = sections.first { $0.id == "safe" }?.bytes ?? 0
        let stale = sections.first { $0.id == "stale" }?.bytes ?? 0
        return VStack(alignment: .leading, spacing: 6) {
            Text("Clean up \(model.hostLabel)").font(Theme.display)
            Group {
                if safe + stale == 0 {
                    Text("Nothing large stands out.")
                } else {
                    Text("\(bytes(safe)) regenerates on its own if deleted. ")
                        + Text("\(bytes(stale)) has not been written in 6 months.")
                }
            }
            .font(Theme.callout).foregroundStyle(Theme.muted)
            if let space = s.status?.space {
                FreeBar(space: space, marked: model.markedBytes)
                    .padding(.top, 6)
            }
        }
    }
}

struct FreeBar: View {
    let space: SpaceDTO
    let marked: Int64

    var body: some View {
        let used = space.total - space.available
        VStack(alignment: .leading, spacing: 5) {
            GeometryReader { geo in
                let w = geo.size.width
                let share = Double(space.available) / Double(max(space.total, 1))
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.surface2)
                    Capsule().fill(share < 0.1 ? Theme.bad : share < 0.2 ? Theme.warn : Theme.accent)
                        .frame(width: w * CGFloat(used) / CGFloat(space.total))
                    if marked > 0 {
                        Capsule().fill(Theme.good.opacity(0.6))
                            .frame(width: w * CGFloat(min(marked, used)) / CGFloat(space.total))
                            .offset(x: w * CGFloat(max(0, used - marked)) / CGFloat(space.total))
                    }
                }
            }
            .frame(height: 10)
            HStack {
                Text("\(bytes(space.available)) free now").foregroundStyle(Theme.muted)
                if marked > 0 {
                    Text("·").foregroundStyle(Theme.faint)
                    Text("\(bytes(space.available + marked)) after what is marked").foregroundStyle(Theme.good)
                }
                Spacer()
                Text("\(bytes(space.total)) disk").foregroundStyle(Theme.muted)
            }
            .font(Theme.caption.monospacedDigit())
        }
    }
}

struct SectionCard: View {
    @EnvironmentObject var model: SparkModel
    let section: SuggestSection
    @State private var showAll = false

    private var symbol: String {
        switch section.id {
        case "safe": "arrow.triangle.2.circlepath"
        case "growing": "chart.line.uptrend.xyaxis"
        case "stale": "moon.zzz"
        default: "arrow.uturn.backward"
        }
    }

    var body: some View {
        let items = showAll ? section.items : Array(section.items.prefix(6))
        let largest = section.items.map(\.bytes).max() ?? 1
        let markable = section.items.filter(\.markable)
        let allMarked = !markable.isEmpty && markable.allSatisfy { model.current.marks[$0.path] != nil || model.isMarked($0.path) }
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: symbol).foregroundStyle(Theme.accent).font(.system(size: 15, weight: .medium))
                Text(section.title).font(Theme.title)
                Text(section.items.isEmpty ? "" : bytes(section.bytes)).font(Theme.title.monospacedDigit()).foregroundStyle(Theme.muted)
                Spacer()
                if !markable.isEmpty {
                    Button(allMarked ? "All marked" : "Mark all \(markable.count)") { model.markAll(markable) }
                        .disabled(allMarked)
                        .controlSize(.small)
                }
            }
            Text(section.detail).font(Theme.subhead).foregroundStyle(Theme.muted)
            if section.items.isEmpty {
                Text(emptyText).font(Theme.subhead).foregroundStyle(Theme.faint).padding(.vertical, 4)
            } else {
                VStack(spacing: 2) {
                    ForEach(items) { item in
                        SuggestRow(item: item, largest: largest)
                    }
                }
                if section.items.count > 6 {
                    Button(showAll ? "Show fewer" : "Show all \(section.items.count)") {
                        withAnimation(Theme.spring) { showAll.toggle() }
                    }
                    .buttonStyle(.link).font(Theme.caption)
                }
            }
        }
        .padding(Theme.Space.xl)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.lg, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 0.5))
    }

    private var emptyText: String {
        switch section.id {
        case "growing": "Nothing grew by 200 MB or more. This fills in as hourly snapshots build up a week of history."
        case "cameBack": "Nothing you removed here has grown back."
        default: "Nothing here."
        }
    }
}

struct SuggestRow: View {
    @EnvironmentObject var model: SparkModel
    let item: SuggestItem
    let largest: Int64
    @State private var hovering = false

    var body: some View {
        let marked = model.current.marks[item.path] != nil
        let covered = !marked && model.isMarked(item.path)
        let root = model.current.status?.root ?? ""
        let shown = item.path.hasPrefix(root + "/") ? "~/" + item.path.dropFirst(root.count + 1) : item.path
        HStack(spacing: 12) {
            Circle().fill(Theme.category(item.category)).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Theme.callout.weight(.medium)).lineLimit(1)
                Text(parentOf(String(shown))).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.middle)
            }
            .frame(minWidth: 160, alignment: .leading)
            Text(item.why).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(bytes(item.bytes)).font(Theme.callout.monospacedDigit().weight(.medium))
                GeometryReader { geo in
                    Capsule().fill(Theme.surface2)
                        .overlay(alignment: .leading) {
                            Capsule().fill(marked || covered ? Theme.bad.opacity(0.6) : Theme.accent.opacity(0.55))
                                .frame(width: max(3, geo.size.width * CGFloat(item.bytes) / CGFloat(max(largest, 1))))
                        }
                }
                .frame(width: 90, height: 4)
            }
            .frame(width: 100, alignment: .trailing)
            Button {
                model.toggleMark(item.path, name: item.name, bytes: item.bytes)
            } label: {
                Image(systemName: marked ? "checkmark.circle.fill" : covered ? "checkmark.circle" : "plus.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(marked || covered ? Theme.bad : Theme.muted)
            }
            .buttonStyle(.plain)
            .disabled(!item.markable || covered)
            .opacity(item.markable ? 1 : 0.3)
            .help(item.markable ? (marked ? "Unmark" : "Mark for removal") : "Open it and choose what goes")
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(hovering ? Theme.surface2.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { model.reveal(item.path) }
        .contextMenu {
            Button("Show in Map") { model.reveal(item.path) }
            Button("Show in Finder") { NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "") }
                .disabled(model.host != "local")
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(item.path, forType: .string)
            }
        }
    }
}
