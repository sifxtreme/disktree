import Foundation
import SwiftUI

enum Page: String, CaseIterable, Identifiable {
    case map = "Map", cleanup = "Clean up"
    var id: String { rawValue }
}

enum ColorMode: String, CaseIterable, Identifiable {
    case kind = "Kind", age = "Age"
    var id: String { rawValue }
}

/// Everything one machine shows.
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
    var seenSnapshot: Int64 = 0
    var suggest: SuggestDTO?
    /// Insights, history, growth and suggestions arrived for the shown snapshot. Until then the
    /// cards say "Loading", never "nothing stands out": empty is not the same as not yet known.
    var extrasLoaded = false
    /// Folders visited, for Back and Forward (⌘[ ⌘]).
    var back: [String] = []
    var forward: [String] = []
}

@MainActor
final class SparkModel: ObservableObject {
    static let shared = SparkModel()

    @Published var hosts: [HostDTO] = []
    @Published var host = Harness.enabled ? "local" : UserDefaults.standard.string(forKey: "host") ?? "local" {
        didSet { if !Harness.enabled { UserDefaults.standard.set(host, forKey: "host") } }
    }
    @Published var states: [String: HostState] = [:]
    @Published var mode: ColorMode = .kind
    // `-page "Clean up"` and `-openPath <dir>` at launch: screenshots and tests without keystrokes.
    @Published var page: Page = Page(rawValue: UserDefaults.standard.string(forKey: "page") ?? "") ?? .map
    @Published var serverUp = true
    @Published var toast: String?

    private var started = false
    private var startPath = UserDefaults.standard.string(forKey: "openPath")
    private var lastOthers = Date.distantPast

    var current: HostState { states[host] ?? HostState() }
    var hostLabel: String { label(host) }

    func label(_ id: String) -> String { hosts.first { $0.id == id }?.label ?? (id == "local" ? "This Mac" : id) }

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
            // Quickly while a snapshot runs or the server is down (so it recovers within seconds).
            let busy = current.status?.scanning == true || !serverUp || hosts.isEmpty
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
                states[h.id] = HostState()
            }
        } catch {
            if Harness.enabled { print("LOG loadHosts failed: \(error)"); fflush(stdout) }
            // Only a refused or missing connection means down; a timeout is a busy machine.
            if let e = error as? URLError, e.code == .timedOut { return }
            serverUp = false
        }
    }

    func refresh(_ id: String) async {
        if hosts.isEmpty { await loadHosts() }
        if states[id] == nil { states[id] = HostState() }
        // Fetch first, then change only the fields this owns. Copying the whole state before the
        // await and writing it back after lost anything done meanwhile (Forward history, the node).
        var status: StatusDTO?
        var failure: String?
        do {
            status = try await API.get("api/h/\(id)/status")
            serverUp = true
        } catch let error as APIError {
            failure = error.message
        } catch let error as URLError where error.code == .timedOut {
            // Slow is not down: keep the last numbers rather than claim the server is gone.
            if Harness.enabled { print("LOG refresh \(id) timed out"); fflush(stdout) }
            if states[id]?.status == nil { failure = "slow to answer" } else { return }
        } catch {
            if Harness.enabled { print("LOG refresh \(id) failed: \(error)"); fflush(stdout) }
            failure = error.localizedDescription
            if id == "local" { serverUp = false }
        }
        if let status { states[id]?.status = status }
        states[id]?.error = failure
        let at = states[id]?.status?.scannedAt ?? 0
        guard at != 0, at != states[id]?.seenSnapshot else { return }
        states[id]?.seenSnapshot = at
        if id == host {
            // `-openPath` applies to the first load, not after it: opening it separately raced the
            // first snapshot load, which reset the view to the root.
            let start = startPath
            startPath = nil
            await load(path: states[id]?.node?.path ?? start, select: states[id]?.selection)
            await loadExtras()
        } else {
            states[id]?.node = nil
        }
    }

    func switchHost(_ id: String) {
        guard id != host else { return }
        // Keep only what is on screen: the machine left behind keeps its status (for the sidebar)
        // and reloads the rest when it is shown again.
        if var old = states[host] {
            old.node = nil; old.index = [:]; old.insights = []; old.history = []; old.growth = nil; old.suggest = nil
            old.seenSnapshot = 0
            old.extrasLoaded = false
            states[host] = old
        }
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
        async let suggest: SuggestDTO? = try? API.get("api/h/\(id)/suggest")
        let (i, h, g, c) = await (insights, history, growth, suggest)
        states[id]?.insights = i?.items ?? []
        states[id]?.history = h?.points ?? []
        states[id]?.growth = g
        states[id]?.suggest = c
        states[id]?.extrasLoaded = true
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

    /// Go to a folder, remembering where we were for Back.
    func open(_ path: String, select: String? = nil) {
        if let here = current.node?.path, here != path {
            states[host]?.back.append(here)
            states[host]?.forward = []
        }
        Task { await load(path: path, select: select) }
    }

    func reveal(_ path: String) {
        page = .map
        open(parentOf(path), select: path)
    }

    func up() {
        guard let node = current.node, let path = node.path, path != current.status?.root else { return }
        open(parentOf(path), select: path)
    }

    var canGoBack: Bool { !current.back.isEmpty }
    var canGoForward: Bool { !current.forward.isEmpty }
    var canGoUp: Bool { current.node?.path != nil && current.node?.path != current.status?.root }

    func goBack() {
        guard let to = states[host]?.back.popLast() else { return up() }
        if let here = current.node?.path { states[host]?.forward.append(here) }
        let from = current.node?.path
        Task { await load(path: to, select: from.flatMap { $0.hasPrefix(to + "/") ? $0 : nil }) }
    }

    func goForward() {
        guard let to = states[host]?.forward.popLast() else { return }
        if let here = current.node?.path { states[host]?.back.append(here) }
        Task { await load(path: to, select: nil) }
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

    // MARK: toast

    func show(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(2.4))
            if toast == text { toast = nil }
        }
    }
}
