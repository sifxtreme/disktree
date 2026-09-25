import SwiftUI

// Guilty Spark for the Mac (work name: disk). Native SwiftUI over the local disk-web API: the app
// holds no grants and no logic that decides what may be deleted. Snapshots are disk-snap's job
// (launchd, hourly); removal guards live in disktree-core behind disk-web. One Window and one
// MenuBarExtra, the same shape as Cortana's Mac client, so it can fold into Cortana later.

@main
struct GuiltySparkApp: App {
    @StateObject private var model = SparkModel.shared

    init() {
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
