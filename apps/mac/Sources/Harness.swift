import AppKit
import SwiftUI

// UI harness (Cortana's convention: launch arguments and window-only screenshots, never synthetic
// keystrokes). `GuiltySpark -harness YES` drives the real model through the same calls the views
// make, checks the state after each step, and prints `SHOT <name> <windowNumber>` then waits for
// `<out>/<name>.ack`: the runner (apps/mac/harness/run.sh) takes the screenshot, because a capture
// started by the app itself would need Screen Recording permission. Results go to
// `<out>/results.json`; the process exits 0 only when every check passed.
//
// Isolation: marks are in memory only (the user's saved marks are never read or written), no menu-bar
// item is added, and `commit()` refuses: the harness can plan a removal, never perform one.

enum Harness {
    static let enabled = UserDefaults.standard.bool(forKey: "harness")
    static let out = URL(fileURLWithPath: UserDefaults.standard.string(forKey: "harnessOut") ?? "/tmp/disk-harness")
}

@MainActor
final class HarnessRunner {
    private let model = SparkModel.shared
    private var checks: [[String: Any]] = []
    private var timings: [String: Double] = [:]
    private var failed = 0

    func run() async {
        try? FileManager.default.createDirectory(at: Harness.out, withIntermediateDirectories: true)
        await sleep(1)
        // Frontmost, so prominent buttons render as a user sees them (inactive windows dim them).
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.setFrame(NSRect(x: 80, y: 80, width: 1380, height: 880), display: true)

        // 1. Launch: hosts, status and the root folder load.
        await step("launch") {
            await self.wait("hosts loaded") { !self.model.hosts.isEmpty }
            await self.wait("root node loaded", timeout: 60) { self.model.current.node != nil }
            let root = self.model.current.status?.root
            self.check("root node is the snapshot root", self.model.current.node?.path == root, "\(String(describing: self.model.current.node?.path))")
            self.check("root has children", !(self.model.current.node?.children ?? []).isEmpty)
            self.check("no error on local", self.model.current.error == nil, self.model.current.error ?? "")
        }
        await shot("01-map-root")

        // 2. Click into the largest folder, then back out, forward, up.
        let root = model.current.node?.path ?? ""
        let target = model.current.node?.children?.first { $0.dir && $0.hasChildren }.map { root + "/" + $0.name }
        if let target {
            await step("open largest folder") {
                self.model.open(target)
                await self.wait("zoomed in") { self.model.current.node?.path == target }
                self.check("back is enabled after opening", self.model.canGoBack)
                self.check("up is enabled inside a folder", self.model.canGoUp)
            }
            await sleep(0.6) // let the zoom animation settle before the shot
            await shot("02-zoomed-in")
            await step("back") {
                self.model.goBack()
                await self.wait("back at root") { self.model.current.node?.path == root }
                self.check("forward is enabled after back", self.model.canGoForward)
            }
            await sleep(0.6)
            await shot("03-back-out")
            await step("forward") {
                self.model.goForward()
                await self.wait("forward to folder") { self.model.current.node?.path == target }
            }
            await step("up") {
                self.model.up()
                await self.wait("up to root") { self.model.current.node?.path == root }
                self.check("up at root is disabled", !self.model.canGoUp)
            }
        } else {
            check("root has a folder to open", false)
        }

        // 3. Colour by age.
        model.mode = .age
        await sleep(0.4)
        await shot("04-age")
        model.mode = .kind

        // 4. Clean up page.
        await step("clean up") {
            self.model.page = .cleanup
            await self.wait("suggestions loaded") { self.model.current.suggest != nil }
            let ids = self.model.current.suggest?.sections.map(\.id) ?? []
            self.check("four clean up sections", ids == ["safe", "growing", "stale", "cameBack"], ids.joined(separator: ","))
        }
        await sleep(0.4)
        await shot("05-cleanup")

        // 5. Mark one item, plan its removal (never commit), then clear.
        if let item = model.current.suggest?.sections.flatMap(\.items).first(where: \.markable) {
            await step("mark and plan") {
                self.model.toggleMark(item.path, name: item.name, bytes: item.bytes)
                self.check("one mark", self.model.current.marks.count == 1)
                self.check("marked bytes equal the item", self.model.markedBytes == item.bytes, "\(self.model.markedBytes) vs \(item.bytes)")
                self.model.openReview()
                await self.wait("plan loaded") { self.model.review?.plan != nil || self.model.review?.error != nil }
                let plan = self.model.review?.plan
                self.check("plan has the one target", plan?.targets.map(\.path) == [item.path], self.model.review?.error ?? "")
                self.check("plan blocks nothing", plan?.blocked.isEmpty == true, plan?.blocked.map(\.reason).joined(separator: "; ") ?? "")
                self.check("default mode is trash", self.model.review?.mode == "trash")
            }
            await sleep(0.5)
            await shot("06-review-sheet")
            model.review = nil
            model.clearMarks()
            check("marks cleared", model.current.marks.isEmpty)
        } else {
            check("clean up offers a markable item", false)
        }
        model.page = .map

        // 6. Every other machine: loads, and says whether its snapshot is complete.
        for host in model.hosts where host.id != "local" {
            await step("switch to \(host.id)") {
                self.model.switchHost(host.id)
                await self.wait("\(host.id) node loaded", timeout: 60) { self.model.host == host.id && self.model.current.node != nil }
                self.check("\(host.id) answers", self.model.current.error == nil, self.model.current.error ?? "")
                self.check("\(host.id) snapshot is complete (Full Disk Access)", self.model.current.status?.fullDiskAccess == true,
                           "fullDiskAccess=\(String(describing: self.model.current.status?.fullDiskAccess))")
            }
            await sleep(0.6)
            await shot("07-\(host.id)")
        }
        model.switchHost("local")
        await wait("back on local", timeout: 60) { self.model.host == "local" && self.model.current.node != nil }
        check("local snapshot is complete (Full Disk Access)", model.current.status?.fullDiskAccess == true,
              "fullDiskAccess=\(String(describing: model.current.status?.fullDiskAccess)); grant it to ~/.local/bin/disk-snap")

        // 7. Dark appearance, then a small window.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        await sleep(0.6)
        await shot("08-dark-map")
        model.page = .cleanup
        await sleep(0.5)
        await shot("09-dark-cleanup")
        model.page = .map
        await sleep(0.6)
        await shot("09b-dark-map-after-cleanup")

        NSApp.appearance = nil
        // The smallest frame a person can drag to: the content minimum plus the toolbar.
        window?.setFrame(NSRect(x: 80, y: 80, width: 1180, height: 762), display: true)
        await sleep(0.8)
        await shot("10-min-size")
        await sleep(2)
        await shot("11-min-size-settled")
        if let w = window {
            check("window honours the minimum size", w.frame.width >= 1180 && w.frame.height >= 710,
                  "\(Int(w.frame.width))x\(Int(w.frame.height))")
        }
        for h in [760, 820, 880] {
            window?.setFrame(NSRect(x: 80, y: 80, width: 1180, height: CGFloat(h)), display: true)
            await sleep(1.5)
            await shot("12-height-\(h)")
        }

        // 8. Cost.
        let mb = footprintMB()
        timings["footprintMB"] = mb
        check("memory footprint under 250 MB", mb < 250, String(format: "%.0f MB", mb))

        let result: [String: Any] = ["checks": checks, "timings": timings, "failed": failed]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: Harness.out.appendingPathComponent("results.json"))
        }
        print("DONE failed=\(failed)")
        fflush(stdout)
        exit(failed == 0 ? 0 : 1)
    }

    // MARK: helpers

    private var window: NSWindow? {
        NSApp.windows.filter { $0.isVisible && $0.frame.height > 300 }.max { $0.frame.height < $1.frame.height }
    }

    private func step(_ name: String, _ body: () async -> Void) async {
        let start = Date()
        await body()
        timings[name] = Date().timeIntervalSince(start)
    }

    private func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if !ok { failed += 1 }
        checks.append(["name": name, "ok": ok, "detail": detail])
        print("\(ok ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        fflush(stdout)
    }

    private func wait(_ what: String, timeout: Double = 45, _ condition: () -> Bool) async {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout {
                check("\(what) within \(Int(timeout)) s", false)
                return
            }
            await sleep(0.1)
        }
        timings["wait: \(what)"] = Date().timeIntervalSince(start)
    }

    private func shot(_ name: String) async {
        guard let number = window?.windowNumber else { return check("window for \(name)", false) }
        let ack = Harness.out.appendingPathComponent("\(name).ack")
        try? FileManager.default.removeItem(at: ack)
        print("SHOT \(name) \(number)")
        fflush(stdout)
        let start = Date()
        while !FileManager.default.fileExists(atPath: ack.path) && Date().timeIntervalSince(start) < 15 {
            await sleep(0.1)
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    private func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }
}
