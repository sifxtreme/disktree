import SwiftUI

// Guilty Spark for the Mac (work name: disk). Native SwiftUI over the local disk-web API: the app
// holds no grants and no logic that decides what may be deleted. Snapshots are disk-snap's job
// (launchd, hourly); removal guards live in disktree-core behind disk-web. One Window and one
// MenuBarExtra, the same shape as Cortana's Mac client, so it can fold into Cortana later.

@main
struct GuiltySparkApp: App {
    @StateObject private var model = SparkModel.shared

    init() {
        // `-appearance dark|light` for screenshots; otherwise the system setting.
        switch UserDefaults.standard.string(forKey: "appearance") {
        case "dark": NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApplication.shared.appearance = NSAppearance(named: .aqua)
        default: break
        }
        SparkModel.shared.start()
        if Harness.enabled {
            Task { @MainActor in await HarnessRunner().run() }
        }
    }

    var body: some Scene {
        Window("Guilty Spark", id: "main") {
            MainWindow()
                .environmentObject(model)
                .tint(Theme.accent)
                .frame(minWidth: 1180, minHeight: 710)
        }
        .defaultSize(width: 1380, height: 880)
        // The window enforces the content minimum, so a frame request below it (a screen change, a
        // window manager, a restored size) is clamped. Without this, SwiftUI re-entered layout until
        // AppKit aborted (crash reports 2026-09-24 17:23, 17:24, 19:29; the harness reproduces it).
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Snapshot Now") { model.snapshotNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
                Button("Enclosing Folder") { model.up() }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Back") { model.goBack() }
                    .keyboardShortcut("[", modifiers: .command)
                Button("Forward") { model.goForward() }
                    .keyboardShortcut("]", modifiers: .command)
                Divider()
                Button("Map") { model.page = .map }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Clean Up") { model.page = .cleanup }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Memory") { model.page = .memory }
                    .keyboardShortcut("3", modifiers: .command)
            }
        }

        MenuBarExtra(isInserted: .constant(!Harness.enabled)) {
            MenuPanel().environmentObject(model)
        } label: {
            MenuLabel().environmentObject(model)
        }
        .menuBarExtraStyle(.window)
    }
}
