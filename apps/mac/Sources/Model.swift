import Foundation
import SwiftUI

enum ColorMode: String, CaseIterable, Identifiable {
    case kind = "Kind", age = "Age"
    var id: String { rawValue }
}

struct Mark: Codable, Hashable {
    let name: String
    let bytes: Int64
}

/// Everything one machine shows. Marks are keyed by absolute path, so they survive a new snapshot.
struct HostState {
    var status: StatusDTO?
    var error: String?
    var node: NodeDTO?
    /// path → node for everything in the drawn view, rebuilt with each load.
    var index: [String: NodeDTO] = [:]
    var insights: [InsightDTO] = []
    var history: [PointDTO] = []
    var growth: GrowthDTO?
    var selection: String?
    var marks: [String: Mark] = [:]
    var seenSnapshot: Int64 = 0
}

enum ReviewStep { case choose, confirm, running, done }

struct ReviewState: Identifiable {
    let id = UUID()
    let host: String
    var mode: String
    var step: ReviewStep = .choose
    var plan: PlanDTO?
    var job: RemovalDTO?
    var error: String?
}

@MainActor
final class SparkModel: ObservableObject {
    static let shared = SparkModel()

    @Published var hosts: [HostDTO] = []
    @Published var host = UserDefaults.standard.string(forKey: "host") ?? "local" {
        didSet { UserDefaults.standard.set(host, forKey: "host") }
    }
    @Published var states: [String: HostState] = [:]
    @Published var mode: ColorMode = .kind
    @Published var serverUp = true
    @Published var review: ReviewState?
    @Published var toast: String?

    private var started = false
    private var lastOthers = Date.distantPast

    var current: HostState { states[host] ?? HostState() }
    var hostLabel: String { hosts.first { $0.id == host }?.label ?? host }

    func label(_ id: String) -> String { hosts.first { $0.id == id }?.label ?? id }

    // MARK: lifecycle

    func start() {
        guard !started else { return }
        started = true
        Task { await self.loop() }
    }

    private func loop() async {
        await loadHosts()
        while true {
            await refresh(host)
            if Date().timeIntervalSince(lastOthers) > 30 {
                lastOthers = Date()
                for h in hosts where h.id != host { await refresh(h.id) }
            }
            // Quickly while a snapshot runs (the count moves), slowly otherwise (hourly data).
            let busy = current.status?.scanning == true
            try? await Task.sleep(for: .seconds(busy ? 1.5 : 10))
        }
    }

    func loadHosts() async {
        do {
            let list: [String: [HostDTO]] = try await API.get("api/hosts")
            hosts = list["hosts"] ?? []
            serverUp = true
            if !hosts.contains(where: { $0.id == host }) { host = "local" }
            for h in hosts where states[h.id] == nil {
                states[h.id] = HostState(marks: loadMarks(h.id))
            }
        } catch {
            serverUp = false
        }
    }

    func refresh(_ id: String) async {
        if hosts.isEmpty { await loadHosts() }
        var s = states[id] ?? HostState(marks: loadMarks(id))
        do {
            let status: StatusDTO = try await API.get("api/h/\(id)/status")
            s.status = status
            s.error = nil
            serverUp = true
        } catch let error as APIError {
            s.error = error.message
        } catch {
            s.error = error.localizedDescription
            if id == "local" { serverUp = false }
        }
        let fresh = (s.status?.scannedAt ?? 0) != 0 && s.status?.scannedAt != s.seenSnapshot
        states[id] = s
        if fresh {
            states[id]?.seenSnapshot = s.status?.scannedAt ?? 0
            if id == host {
                await load(path: s.node?.path, select: s.selection)
                await loadExtras()
            } else {
                states[id]?.node = nil
            }
        }
    }

    func switchHost(_ id: String) {
        guard id != host else { return }
        host = id
        Task {
            await refresh(id)
            if current.node == nil, current.status?.tree != nil {
                await load(path: nil, select: nil)
                await loadExtras()
            }
        }
    }

    // MARK: loading

    func load(path: String?, select: String?) async {
        let id = host
        var query = ["depth": "3"]
        if let path { query["path"] = path } else { query["at"] = "" }
        do {
            let node: NodeDTO = try await API.get("api/h/\(id)/node", query)
            guard id == host else { return }
            var s = states[id] ?? HostState()
            s.node = node
            s.index = Self.index(node)
            let root = node.path ?? ""
            s.selection = select.flatMap { s.index[$0] != nil ? $0 : nil } ?? root
            s.error = nil
            withAnimation(Theme.spring) { states[id] = s }
        } catch let error as APIError where error.status == 404 && path != nil {
            await load(path: nil, select: nil) // gone after a new snapshot
        } catch {
            states[id]?.error = error.localizedDescription
        }
    }

    func loadExtras() async {
        let id = host
        async let insights: InsightsDTO? = try? API.get("api/h/\(id)/insights")
        async let history: HistoryDTO? = try? API.get("api/h/\(id)/history", ["days": "7"])
        async let growth: GrowthDTO? = try? API.get("api/h/\(id)/growth", ["hours": "24"])
        let (i, h, g) = await (insights, history, growth)
        states[id]?.insights = i?.items ?? []
        states[id]?.history = h?.points ?? []
        states[id]?.growth = g
    }

    static func index(_ root: NodeDTO) -> [String: NodeDTO] {
        var out: [String: NodeDTO] = [:]
        func walk(_ n: NodeDTO, _ path: String) {
            out[path] = n
            for c in n.children ?? [] { walk(c, path + "/" + c.name) }
        }
        walk(root, root.path ?? "")
        return out
    }

    // MARK: navigation

    func open(_ path: String) { Task { await load(path: path, select: nil) } }

    func reveal(_ path: String) { Task { await load(path: parentOf(path), select: path) } }

    func up() {
        guard let node = current.node, let path = node.path, path != current.status?.root else { return }
        Task { await load(path: parentOf(path), select: path) }
    }

    func select(_ path: String?) { states[host]?.selection = path }

    func snapshotNow(_ id: String? = nil) {
        let id = id ?? host
        Task {
            do {
                let status: StatusDTO = try await API.post("api/h/\(id)/scan", [:])
                states[id]?.status = status
                show(status.scanError ?? "Snapshot started")
            } catch {
                show("Snapshot did not start: \(error.localizedDescription)")
            }
        }
    }

    // MARK: marks

    func isMarked(_ path: String) -> Bool {
        current.marks.keys.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    func toggleMark(_ path: String, name: String, bytes: Int64) {
        guard path != current.status?.root, current.node != nil else { return }
        if current.marks[path] != nil { states[host]?.marks[path] = nil }
        else { states[host]?.marks[path] = Mark(name: name, bytes: bytes) }
        saveMarks(host)
    }

    func clearMarks() {
        states[host]?.marks = [:]
        saveMarks(host)
    }

    /// Marked bytes, a path inside another marked path counted once.
    var markedBytes: Int64 {
        let keys = Array(current.marks.keys)
        return keys.filter { p in !keys.contains { q in q != p && p.hasPrefix(q + "/") } }
            .reduce(0) { $0 + (current.marks[$1]?.bytes ?? 0) }
    }

    func markPaths(_ id: String) -> [String] {
        (states[id]?.marks ?? [:]).keys.sorted()
    }

    private func loadMarks(_ id: String) -> [String: Mark] {
        guard let data = UserDefaults.standard.data(forKey: "marks.\(id)") else { return [:] }
        return (try? JSONDecoder().decode([String: Mark].self, from: data)) ?? [:]
    }

    private func saveMarks(_ id: String) {
        let data = try? JSONEncoder().encode(states[id]?.marks ?? [:])
        UserDefaults.standard.set(data, forKey: "marks.\(id)")
    }

    // MARK: review and removal

    func openReview() {
        guard !current.marks.isEmpty else { return }
        review = ReviewState(host: host, mode: current.status?.trashAvailable == true ? "trash" : "permanent")
        Task { await plan() }
    }

    func plan() async {
        guard let r = review else { return }
        do {
            let plan: PlanDTO = try await API.post("api/h/\(r.host)/plan",
                                                   ["paths": markPaths(r.host), "mode": r.mode])
            review?.plan = plan
            review?.error = nil
        } catch {
            review?.error = error.localizedDescription
        }
    }

    func unmarkInReview(_ path: String) {
        guard let r = review else { return }
        states[r.host]?.marks[path] = nil
        saveMarks(r.host)
        if states[r.host]?.marks.isEmpty ?? true { review = nil } else { Task { await plan() } }
    }

    func commit() {
        guard let r = review else { return }
        var body: [String: Any] = ["paths": markPaths(r.host), "mode": r.mode]
        if r.mode == "permanent" { body["confirm"] = "delete" }
        Task {
            do {
                let _: PlanDTO = try await API.post("api/h/\(r.host)/remove", body)
            } catch {
                review?.error = error.localizedDescription
                review?.step = .choose
                return
            }
            review?.step = .running
            while review?.id == r.id {
                if let job: Optionally<RemovalDTO> = try? await API.get("api/h/\(r.host)/removal"), let value = job.value {
                    review?.job = value
                    if value.done != nil {
                        review?.step = .done
                        let gone = value.items.filter { $0.error == nil }.map(\.path)
                        for p in markPaths(r.host)
                        where gone.contains(where: { p == $0 || p.hasPrefix($0 + "/") }) {
                            states[r.host]?.marks[p] = nil
                        }
                        saveMarks(r.host)
                        await refresh(r.host)
                        return
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    // MARK: toast

    func show(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast == text { toast = nil }
        }
    }
}
