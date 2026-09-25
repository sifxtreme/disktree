import SwiftUI

// Memory: what is holding it, and since when. disk-mem samples every 5 minutes into mem.db
// (crates/disk-web/src/mem.rs); this page reads /mem, /mem-history and /mem-owner. Per-process
// memory is phys_footprint (Activity Monitor's number), summed by owner: a Claude Code session, a
// pm2 app, a launchd job or app, or launchd's direct child. Read-only, like the rest of the app.

struct MemSystemDTO: Codable, Hashable {
    let takenAt: Int64
    let host: String
    let pressureLevel: Int?
    let severity: String?
    let memTotalMb: Int64?
    let freePct: Int?
    let swapUsedMb: Int64?
    let swapTotalMb: Int64?
    let compressorMb: Int64?
    let wiredMb: Int64?
    let load1: Double?
}

struct MemOwnerDTO: Codable, Hashable, Identifiable {
    let owner: String
    let kind: String
    let procs: Int
    let footprintMb: Double
    let compressedMb: Double
    let topPid: Int?
    let topName: String?
    var id: String { owner }
}

struct MemModelDTO: Codable, Hashable, Identifiable {
    let name: String
    let sizeMb: Double
    let vramMb: Double
    let expiresAt: String?
    var id: String { name }
}

struct MemTopDTO: Codable, Hashable {
    let system: MemSystemDTO?
    let owners: [MemOwnerDTO]
    let models: [MemModelDTO]
}

struct MemPointDTO: Codable, Hashable {
    let t: Int64
    let swapUsedMb: Int64?
    let footprintMb: Double?
    let compressedMb: Double?
}

struct MemSeriesDTO: Codable, Hashable {
    let owner: String?
    let points: [MemPointDTO]
}

/// Megabytes as `top` counts them (MiB), shown in GB past 1 GB, matching `disk-mem top`.
func mib(_ mb: Double) -> String {
    mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb)
}

@MainActor
final class MemoryStore: ObservableObject {
    static let shared = MemoryStore()

    @Published var host = ""
    @Published var top: MemTopDTO?
    @Published var swap: [MemPointDTO] = []
    @Published var error: String?
    @Published var selected: String?
    @Published var series: MemSeriesDTO?

    /// Loads one host's latest sample and a week of swap; again every 60 s while the page is open
    /// (samples arrive every 5 minutes, so faster polling would only redraw the same numbers).
    func run(host: String) async {
        if host != self.host {
            self.host = host
            top = nil; swap = []; error = nil; selected = nil; series = nil
        }
        while !Task.isCancelled {
            do {
                async let t: MemTopDTO = API.get("api/h/\(host)/mem")
                async let h: MemSeriesDTO = API.get("api/h/\(host)/mem-history", ["days": "7"])
                let (top, history) = try await (t, h)
                self.top = top
                swap = history.points
                error = nil
            } catch {
                self.error = (error as? APIError)?.message ?? error.localizedDescription
            }
            if let selected { await load(selected) }
            try? await Task.sleep(for: .seconds(60))
        }
    }

    func select(_ owner: String?) {
        selected = selected == owner ? nil : owner
        series = nil
        if let selected { Task { await load(selected) } }
    }

    private func load(_ owner: String) async {
        let s: MemSeriesDTO? = try? await API.get("api/h/\(host)/mem-owner", ["name": owner, "days": "7"])
        if selected == owner { series = s }
    }
}

struct MemoryView: View {
    @EnvironmentObject var model: SparkModel
    @StateObject private var store = MemoryStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Space.lg) {
                header
                if let top = store.top, top.system != nil {
                    SwapCard(points: store.swap)
                    OwnersCard(owners: top.owners, store: store)
                    if !top.models.isEmpty { ModelsCard(models: top.models) }
                    Text("Memory is each process's footprint (Activity Monitor's figure), summed by owner. Compressed is the part the system has squeezed or swapped out. Sampled every 5 minutes by com.asif.disk-mem.")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if store.error == nil {
                    ProgressView().controlSize(.small)
                }
            }
            .padding(.horizontal, Theme.Space.x3)
            .padding(.vertical, Theme.Space.xxl)
            .frame(maxWidth: 920)
            .frame(maxWidth: .infinity)
        }
        .task(id: model.host) { await store.run(host: model.host) }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Text("Memory on \(model.hostLabel)").font(Theme.display)
                if let s = store.top?.system {
                    StatePill(text: s.severity ?? "—", color: severityColor(s.severity))
                }
            }
            Group {
                if let e = store.error {
                    Text(e.contains("unable to open") ? "No memory samples on this machine yet (com.asif.disk-mem)." : "No answer: \(e)")
                } else if let s = store.top?.system {
                    Text(summary(s))
                } else if store.top != nil {
                    Text("No memory samples on this machine yet.")
                } else {
                    Text("Loading…")
                }
            }
            .font(Theme.callout).foregroundStyle(Theme.muted)
        }
    }

    private func summary(_ s: MemSystemDTO) -> String {
        var parts = ["swap \(mib(Double(s.swapUsedMb ?? 0))) of \(mib(Double(s.swapTotalMb ?? 0)))"]
        if let f = s.freePct { parts.append("\(f)% free") }
        if let c = s.compressorMb { parts.append("compressor \(mib(Double(c)))") }
        if let l = s.load1 { parts.append(String(format: "load %.0f", l)) }
        parts.append("sampled \(ago(s.takenAt))")
        return parts.joined(separator: " · ")
    }
}

private func severityColor(_ severity: String?) -> Color {
    switch severity {
    case "critical": Theme.bad
    case "warning": Theme.warn
    default: Theme.good
    }
}

private struct SwapCard: View {
    let points: [MemPointDTO]

    var body: some View {
        let values = points.compactMap { $0.swapUsedMb }.map { Double($0) * 1_048_576 }
        Card(title: "Swap used, 7 days") {
            if values.count > 1 {
                Sparkline(values: values, label: { mib($0 / 1_048_576) })
                    .frame(height: 64)
                Text("Includes mem-guard's history. Swap past 3 GB counts as a warning.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            } else {
                Text("Not enough samples yet.").foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct OwnersCard: View {
    let owners: [MemOwnerDTO]
    @ObservedObject var store: MemoryStore

    var body: some View {
        let shown = Array(owners.prefix(25))
        let largest = shown.map(\.footprintMb).max() ?? 1
        Card(title: "Who holds it") {
            VStack(spacing: 0) {
                ForEach(shown) { o in
                    OwnerRow(owner: o, largest: largest, selected: store.selected == o.owner)
                        .contentShape(Rectangle())
                        .onTapGesture { store.select(o.owner) }
                    if store.selected == o.owner {
                        OwnerHistory(series: store.series)
                            .padding(.vertical, Theme.Space.sm)
                    }
                    if o.id != shown.last?.id { Divider() }
                }
            }
            if owners.count > shown.count {
                Text("\(owners.count - shown.count) smaller owners not shown.")
                    .font(Theme.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct OwnerRow: View {
    let owner: MemOwnerDTO
    let largest: Double
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: selected ? "chevron.down" : "chevron.right")
                .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
                .frame(width: 10)
            VStack(alignment: .leading, spacing: 2) {
                Text(owner.owner).font(Theme.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                Text(detail).font(Theme.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: 4) {
                Text(mib(owner.footprintMb)).font(Theme.callout.monospacedDigit().weight(.medium))
                Capsule().fill(Theme.surface2)
                    .frame(width: 120, height: 4)
                    .overlay(alignment: .leading) {
                        Capsule().fill(Theme.accent.opacity(0.6))
                            .frame(width: max(3, 120 * owner.footprintMb / max(largest, 1)), height: 4)
                    }
            }
            .frame(width: 130, alignment: .trailing)
            Text(owner.compressedMb >= 1 ? "\(mib(owner.compressedMb)) compressed" : "")
                .font(Theme.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                .frame(width: 130, alignment: .trailing)
        }
        .padding(.vertical, 8)
    }

    private var detail: String {
        let kind = ["claude": "sessions and the tools they run", "pm2": "pm2 app", "job": "launchd job", "app": "app",
                    "system": "system", "other": "everything under 16 MB"][owner.kind] ?? owner.kind
        var parts = [kind, owner.procs == 1 ? "1 process" : "\(owner.procs) processes"]
        if owner.procs > 1, let name = owner.topName, !name.isEmpty { parts.append("largest \(name)") }
        return parts.joined(separator: " · ")
    }
}

private struct OwnerHistory: View {
    let series: MemSeriesDTO?

    var body: some View {
        if let series {
            let values = series.points.compactMap(\.footprintMb)
            if values.count > 1 {
                VStack(alignment: .leading, spacing: 4) {
                    Sparkline(values: values.map { $0 * 1_048_576 }, label: { mib($0 / 1_048_576) })
                        .frame(height: 56)
                    Text("Footprint over 7 days: \(values.count) samples, low \(mib(values.min() ?? 0)), high \(mib(values.max() ?? 0)).")
                        .font(Theme.caption).foregroundStyle(Theme.muted)
                }
                .padding(.leading, 22)
            } else {
                Text("One sample so far; a line needs two.").font(Theme.caption).foregroundStyle(Theme.muted)
                    .padding(.leading, 22)
            }
        } else {
            ProgressView().controlSize(.small).padding(.leading, 22)
        }
    }
}

private struct ModelsCard: View {
    let models: [MemModelDTO]

    var body: some View {
        Card(title: "Ollama models resident") {
            ForEach(models) { m in
                HStack {
                    Text(m.name).font(Theme.callout)
                    Spacer()
                    Text(mib(m.sizeMb)).font(Theme.callout.monospacedDigit())
                }
            }
            Text("Loaded on the GPU: macOS cannot page this memory out. It frees when Ollama unloads the model.")
                .font(Theme.caption).foregroundStyle(Theme.muted)
        }
    }
}
